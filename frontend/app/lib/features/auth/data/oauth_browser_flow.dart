import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/globals/app_constants.dart';

/// The user closed the login window or declined on the provider's page.
/// Not a failure worth a message: they chose not to continue.
class OAuthCancelledError extends DomainError {
  const OAuthCancelledError(super.message, {super.originalError, super.stackTrace});
}

/// The browser step did not produce a usable code: the provider reported an
/// error, the `state` did not match, or the platform call failed.
class OAuthFailedError extends DomainError {
  const OAuthFailedError(super.message, {super.originalError, super.stackTrace});
}

/// What the browser step hands to `OAuthLogin`.
@immutable
class OAuthAuthorization {
  final String code;

  /// The redirect URI the code was issued for. The server sends it to the
  /// provider's token endpoint, which refuses a code if it differs.
  final String redirectUri;

  const OAuthAuthorization({required this.code, required this.redirectUri});
}

/// Which providers this build can use, and where the browser comes back to.
@immutable
class OAuthConfig {
  /// Empty means "not registered yet": that provider stays disabled.
  final Map<OAuthProvider, String> clientIds;
  final String redirectUri;
  final String callbackScheme;

  /// flutter_web_auth_2 catches a custom-scheme redirect on iOS, Android and
  /// macOS, and runs the login in a window of the app's own on Linux (the
  /// eval phone). Windows would work like Linux but has never been tried, and
  /// web needs an auth.html page plus a web half for AuthService: not wired.
  final bool platformSupported;

  /// The login window is the app's own webview (Linux), which reports every
  /// address it is sent to, redirects included. It then stops at
  /// [redirectUri] itself, before loading it, instead of waiting for the
  /// bounce page to send it on to [callbackScheme]. On the phone that is not
  /// a detail: `localhost` in its container is not the backend, so the
  /// bounce page could not load, yet the same redirect URI serves both.
  ///
  /// Google refuses most embedded webviews ("disallowed_useragent") but
  /// serves its sign-in page to this one: WebKitGTK passes for a browser.
  final bool catchesRedirect;

  const OAuthConfig({
    required this.clientIds,
    required this.redirectUri,
    required this.callbackScheme,
    required this.platformSupported,
    this.catchesRedirect = false,
  });

  /// The values compiled in from `.env` (lib/globals/app_constants.dart).
  factory OAuthConfig.fromEnvironment() => OAuthConfig(
        clientIds: const {
          OAuthProvider.google: AppConstants.oauthGoogleClientId,
          OAuthProvider.facebook: AppConstants.oauthFacebookClientId,
          OAuthProvider.intra42: AppConstants.oauthIntra42ClientId,
        },
        redirectUri: AppConstants.oauthRedirectUri,
        callbackScheme: AppConstants.oauthCallbackScheme,
        platformSupported: !kIsWeb &&
            const {
              TargetPlatform.iOS,
              TargetPlatform.android,
              TargetPlatform.macOS,
              TargetPlatform.linux,
            }.contains(defaultTargetPlatform),
        catchesRedirect: !kIsWeb && defaultTargetPlatform == TargetPlatform.linux,
      );

  bool isAvailable(OAuthProvider provider) =>
      platformSupported && (clientIds[provider] ?? '').trim().isNotEmpty;

  Set<OAuthProvider> get availableProviders =>
      {for (final p in OAuthProvider.values) if (isAvailable(p)) p};
}

/// Opens [url] in a login window and resolves with the full URL the browser
/// was redirected to once it reaches [callbackUrlScheme] (and, in the app's
/// own window, the host and path in [options]). The default is
/// flutter_web_auth_2; tests pass a fake.
typedef BrowserAuthenticate = Future<String> Function({
  required String url,
  required String callbackUrlScheme,
  FlutterWebAuth2Options? options,
});

Future<String> _flutterWebAuth2({
  required String url,
  required String callbackUrlScheme,
  FlutterWebAuth2Options? options,
}) =>
    FlutterWebAuth2.authenticate(
      url: url,
      callbackUrlScheme: callbackUrlScheme,
      options: options ?? const FlutterWebAuth2Options(),
    );

/// Steps 1 to 3 of the authorization-code flow: send the user to the
/// provider's login page, wait for the redirect, and pull the code out of it.
/// Steps 4 to 6 (code -> session) are the server's, via OAuthLogin.
///
/// The redirect goes through the backend's bounce page
/// (backend/internal/auth/oauth/callback.go): providers only accept http(s)
/// redirect URIs for a client with a secret, and the app can only receive its
/// own scheme. Where the login window is the app's own, it catches the
/// redirect URI itself and the bounce page is not needed
/// ([OAuthConfig.catchesRedirect]).
class OAuthBrowserFlow {
  final OAuthConfig config;
  final BrowserAuthenticate _authenticate;
  final String Function() _newState;

  OAuthBrowserFlow(
    this.config, {
    BrowserAuthenticate authenticate = _flutterWebAuth2,
    String Function()? newState,
  })  : _authenticate = authenticate,
        _newState = newState ?? _randomState;

  /// A one-time value the provider echoes back. Checking it proves the
  /// redirect answers the login this app started, not one an attacker
  /// started with their own account (login CSRF).
  static String _randomState() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(32, (_) => random.nextInt(256))).replaceAll('=', '');
  }

  Uri authorizeUrl(OAuthProvider provider, String state) {
    return Uri.parse(provider.authorizeEndpoint).replace(queryParameters: {
      'client_id': config.clientIds[provider] ?? '',
      'redirect_uri': config.redirectUri,
      'response_type': 'code',
      'scope': provider.scope,
      'state': state,
      ...provider.extraParams,
    });
  }

  Future<OAuthAuthorization> authorize(OAuthProvider provider) async {
    if (!config.isAvailable(provider)) {
      throw OAuthFailedError('${provider.label} sign-in is not configured in this build');
    }
    final state = _newState();

    final String result;
    try {
      final url = authorizeUrl(provider, state).toString();
      if (config.catchesRedirect) {
        // Its host and path are compared whatever the scheme (http here).
        final redirect = Uri.parse(config.redirectUri);
        result = await _authenticate(
          url: url,
          callbackUrlScheme: redirect.scheme,
          options: FlutterWebAuth2Options(httpsHost: redirect.host, httpsPath: redirect.path),
        );
      } else {
        result = await _authenticate(url: url, callbackUrlScheme: config.callbackScheme);
      }
    } on PlatformException catch (error, stackTrace) {
      // flutter_web_auth_2 reports a closed window as CANCELED on every platform.
      if (error.code == 'CANCELED') {
        throw OAuthCancelledError('login window closed', originalError: error);
      }
      throw OAuthFailedError(
        'login window failed: ${error.code}',
        originalError: error,
        stackTrace: stackTrace,
      );
    }

    final params = Uri.parse(result).queryParameters;
    if (params['state'] != state) {
      throw const OAuthFailedError('state mismatch: not the login this app started');
    }
    switch (params['error']) {
      case null:
        break;
      // What every provider sends when the user clicks "Cancel" or "Deny".
      case 'access_denied':
        throw const OAuthCancelledError('declined on the provider page');
      case final error:
        throw OAuthFailedError('provider error: $error ${params['error_description'] ?? ''}');
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const OAuthFailedError('the redirect carried no code');
    }
    return OAuthAuthorization(code: code, redirectUri: config.redirectUri);
  }
}
