import 'dart:math' show Random;
import 'dart:async' show StreamController;
import 'dart:convert' show jsonEncode, utf8;
import 'storage.dart';
import 'client.dart';
import 'type.dart';
import 'code_verifier.dart';
import 'exception.dart';
import 'base64.dart';
import 'native.dart' as native;

class SessionStateChangeEvent {
  final SessionStateChangeReason reason;
  final Authgear instance;

  SessionStateChangeEvent({required this.instance, required this.reason});
}

final _rng = Random.secure();

Future<String> _getXDeviceInfo() async {
  final deviceInfo = await native.getDeviceInfo();
  final deviceInfoJSON = jsonEncode(deviceInfo);
  final deviceInfoJSONBytes = utf8.encode(deviceInfoJSON);
  final xDeviceInfo = base64UrlEncode(deviceInfoJSONBytes);
  return xDeviceInfo;
}

// It seems that dart's convention of iOS' delegate is individual property of write-only function
// See https://api.dart.dev/stable/2.16.2/dart-io/HttpClient/authenticate.html
class Authgear {
  final String clientID;
  final String endpoint;
  final String name;
  final bool shareSessionWithSystemBrowser;
  final TokenStorage tokenStorage;
  final APIClient _client;

  SessionState _sessionStateRaw = SessionState.unknown;
  SessionState get sessionState => _sessionStateRaw;
  final StreamController _sessionStateStreamController =
      StreamController.broadcast();

  String? _accessToken;
  String? get accessToken => _accessToken;
  String? _refreshToken;
  DateTime? _expireAt;

  String? _idToken;
  String? get idTokenHint => _idToken;

  Authgear({
    required this.clientID,
    required this.endpoint,
    this.name = "default",
    this.shareSessionWithSystemBrowser = false,
    TokenStorage? tokenStorage,
  })  : tokenStorage = tokenStorage ?? TransientTokenStorage(),
        _client = APIClient(endpoint: endpoint);

  Future<void> configure() async {
    _refreshToken = await tokenStorage.getRefreshToken(name);
    final sessionState = _refreshToken == null
        ? SessionState.noSession
        : SessionState.authenticated;
    _setSessionState(sessionState, SessionStateChangeReason.foundToken);
  }

  void _setSessionState(SessionState s, SessionStateChangeReason r) {
    _sessionStateRaw = s;
    _sessionStateStreamController
        .add(SessionStateChangeEvent(instance: this, reason: r));
  }

  Future<AuthenticateResult> authenticate({
    required String redirectURI,
    String? state,
    List<PromptOption>? prompt,
    String? loginHint,
    List<String>? uiLocales,
    AuthenticationPage? page,
  }) async {
    final codeVerifier = CodeVerifier(_rng);
    final oidcRequest = OIDCAuthenticationRequest(
      clientID: clientID,
      redirectURI: redirectURI,
      responseType: "code",
      scope: [
        "openid",
        "offline_access",
        "https://authgear.com/scopes/full-access",
      ],
      codeChallenge: codeVerifier.codeChallenge,
      state: state,
      prompt: prompt,
      loginHint: loginHint,
      uiLocales: uiLocales,
      page: page,
      suppressIDPSessionCookie: !shareSessionWithSystemBrowser,
    );
    final config = await _client.fetchOIDCConfiguration();
    final authenticationURL = Uri.parse(config.authorizationEndpoint)
        .replace(queryParameters: oidcRequest.toQueryParameters());
    final resultURL = await native.authenticate(
      url: authenticationURL.toString(),
      redirectURI: redirectURI,
      preferEphemeral: !shareSessionWithSystemBrowser,
    );
    final xDeviceInfo = await _getXDeviceInfo();
    return await _finishAuthentication(
        url: Uri.parse(resultURL),
        redirectURI: redirectURI,
        codeVerifier: codeVerifier,
        xDeviceInfo: xDeviceInfo);
  }

  Future<AuthenticateResult> _finishAuthentication({
    required Uri url,
    required String redirectURI,
    required CodeVerifier codeVerifier,
    required String xDeviceInfo,
  }) async {
    final queryParameters = url.queryParameters;
    final error = queryParameters["error"];
    final state = queryParameters["state"];
    if (error != null) {
      final errorDescription = queryParameters["error_description"];
      final errorURI = queryParameters["error_uri"];
      throw OAuthException(
        error: error,
        errorDescription: errorDescription,
        errorURI: errorURI,
        state: state,
      );
    }

    final code = queryParameters["code"];
    if (code == null) {
      throw OAuthException(
        error: "invalid_request",
        errorDescription: "code is missing",
      );
    }

    final tokenRequest = OIDCTokenRequest(
      grantType: "authorization_code",
      clientID: clientID,
      code: code,
      redirectURI: redirectURI,
      codeVerifier: codeVerifier.value,
      xDeviceInfo: xDeviceInfo,
    );
    final tokenResponse = await _client.sendTokenRequest(tokenRequest);
    // TODO: call userinfo
    // TODO: persist refresh token
    // TODO: disable biometric
    throw Exception("TODO");
  }
}
