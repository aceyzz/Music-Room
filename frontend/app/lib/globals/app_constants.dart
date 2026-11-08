import 'package:app/core/network/backend_address.dart';

/// Application-wide environment configuration constants.
///
/// Values are resolved at compile time using environment variables specified via
/// `--dart-define` or `--dart-define-from-file`.
///
/// example: flutter run --dart-define-from-file=.env
class AppConstants {
  /// Whether backend network calls should enforce SSL/TLS secure credentials.
  ///
  /// Defaults to `false` if `BACKEND_SECURE_CREDENTIALS` is omitted.
  static const bool backendSecureCredentials =
      bool.fromEnvironment('BACKEND_SECURE_CREDENTIALS', defaultValue: false);

  /// Target port number for the backend service.
  ///
  /// Defaults to `50051` if `BACKEND_PORT` is omitted.
  static const int backendPort =
      int.fromEnvironment('BACKEND_PORT', defaultValue: 50051);

  /// Target host address for the backend service.
  ///
  /// Defaults to `'localhost'` if `BACKEND_HOST` is omitted.
  static const String backendHost =
      String.fromEnvironment('BACKEND_HOST', defaultValue: 'localhost');

  /// Port of the backend's HTTP server (REST gateway, `/media/`, OAuth
  /// bounce page), on [backendHost]. Not [backendPort]: that one is gRPC.
  ///
  /// Defaults to `8081`, docker-compose's APP_HTTP_ADDR. `make backend` runs
  /// the server on the host with Go's default `:8080`; set
  /// `BACKEND_HTTP_PORT=8080` then.
  static const int backendHttpPort =
      int.fromEnvironment('BACKEND_HTTP_PORT', defaultValue: 8081);

  /// Where the backend serves stored images: `images.storage_key` is a path
  /// under it (backend/cmd/main.go, the `/media/` handler).
  /// On [BackendAddress.current]: the address the user saved, if any.
  static String mediaUrl(String storageKey) =>
      '${backendSecureCredentials ? 'https' : 'http'}://${BackendAddress.current.host}:'
      '${BackendAddress.current.httpPort}/media/$storageKey';

  /// The app version this build reports (x-app-version, RegisterDevice), so
  /// the backend's activity logs (V.6) say which version made each call.
  ///
  /// A dart-define rather than package_info_plus: one fewer plugin in the
  /// Linux demo phone's build. Keep the default in step with `version:` in
  /// pubspec.yaml, or pass `APP_VERSION=...` in `.env`.
  static const String appVersion =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0+1');

  /// Debug-only session token, used when no session is stored.
  ///
  /// Lets you work on screens behind login without logging in on every run:
  /// log in once with grpcurl, then pass `DEV_SESSION_TOKEN=<token>` in `.env`.
  /// Ignored in release builds (features/auth/data/session_repository.dart).
  static const String devSessionToken =
      String.fromEnvironment('DEV_SESSION_TOKEN', defaultValue: '');

  // ---------------------------------------------------------------------------
  // OAuth (features/auth/data/oauth_browser_flow.dart, docs/auth-client.md)
  // ---------------------------------------------------------------------------
  // Client IDs are public: they go in the provider's login URL. The secrets
  // stay on the backend (APP_OAUTH_*_CLIENT_SECRET). An empty ID leaves that
  // provider's button disabled.

  static const String oauthGoogleClientId =
      String.fromEnvironment('OAUTH_GOOGLE_CLIENT_ID', defaultValue: '');
  static const String oauthFacebookClientId =
      String.fromEnvironment('OAUTH_FACEBOOK_CLIENT_ID', defaultValue: '');
  static const String oauthIntra42ClientId =
      String.fromEnvironment('OAUTH_INTRA42_CLIENT_ID', defaultValue: '');

  /// Where providers send the browser back: the backend's bounce page, which
  /// forwards the code to [oauthCallbackScheme]. Must be registered, exactly,
  /// with every provider, and is also sent to OAuthLogin, which passes it on
  /// to the provider's token endpoint (they must match).
  static const String oauthRedirectUri = String.fromEnvironment(
    'OAUTH_REDIRECT_URI',
    defaultValue: 'http://localhost:8081/oauth/callback',
  );

  /// The app's own URL scheme, the one the bounce page redirects to
  /// (backend APP_OAUTH_APP_CALLBACK=musicroom://oauth). Not configurable:
  /// android/app/src/main/AndroidManifest.xml declares it too.
  static const String oauthCallbackScheme = 'musicroom';
}
