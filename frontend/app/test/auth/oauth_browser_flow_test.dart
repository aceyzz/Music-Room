import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';

const _redirect = 'http://localhost:8081/oauth/callback';

OAuthConfig config({
  Map<OAuthProvider, String> ids = const {
    OAuthProvider.google: 'google-id',
    OAuthProvider.facebook: '',
    OAuthProvider.intra42: 'u-s4t2ud-42id',
  },
  bool platformSupported = true,
  bool catchesRedirect = false,
}) =>
    OAuthConfig(
      clientIds: ids,
      redirectUri: _redirect,
      callbackScheme: 'musicroom',
      platformSupported: platformSupported,
      catchesRedirect: catchesRedirect,
    );

/// A login window that records what it was opened with and "redirects" to
/// whatever [reply] builds from the URL.
class FakeBrowser {
  final String Function(Uri opened) reply;
  Uri? opened;
  String? scheme;
  FlutterWebAuth2Options? options;

  FakeBrowser(this.reply);

  Future<String> call({
    required String url,
    required String callbackUrlScheme,
    FlutterWebAuth2Options? options,
  }) async {
    opened = Uri.parse(url);
    scheme = callbackUrlScheme;
    this.options = options;
    return reply(opened!);
  }

  /// What the backend bounce page sends when the provider approved.
  static String approve(Uri opened, {String code = 'the-code'}) =>
      'musicroom://oauth?code=$code&state=${opened.queryParameters['state']}';
}

void main() {
  group('OAuthConfig', () {
    test('a provider is available only with a client ID on a supported platform', () {
      expect(config().availableProviders, {OAuthProvider.google, OAuthProvider.intra42});
      expect(config(platformSupported: false).availableProviders, isEmpty);
      expect(config(ids: const {OAuthProvider.google: '  '}).isAvailable(OAuthProvider.google),
          isFalse);
    });

    test('the default build has no client IDs, so every button stays off', () {
      // Placeholders until the provider apps are registered (.env).
      expect(OAuthConfig.fromEnvironment().availableProviders, isEmpty);
    });
  });

  group('authorizeUrl', () {
    final flow = OAuthBrowserFlow(config());

    test('Google asks for the OpenID email scopes the server reads', () {
      final url = flow.authorizeUrl(OAuthProvider.google, 'st');
      expect(url.origin + url.path, 'https://accounts.google.com/o/oauth2/v2/auth');
      expect(url.queryParameters, {
        'client_id': 'google-id',
        'redirect_uri': _redirect,
        'response_type': 'code',
        'scope': 'openid email profile',
        'state': 'st',
        'prompt': 'select_account',
      });
    });

    test('42 asks for the public scope', () {
      final url = flow.authorizeUrl(OAuthProvider.intra42, 'st');
      expect(url.origin + url.path, 'https://api.intra.42.fr/oauth/authorize');
      expect(url.queryParameters['scope'], 'public');
      expect(url.queryParameters['client_id'], 'u-s4t2ud-42id');
    });

    test('Facebook asks for the email', () {
      final url = flow.authorizeUrl(OAuthProvider.facebook, 'st');
      expect(url.origin + url.path, 'https://www.facebook.com/v21.0/dialog/oauth');
      expect(url.queryParameters['scope'], 'email');
    });
  });

  group('authorize', () {
    test('returns the code and the redirect URI it was issued for', () async {
      final browser = FakeBrowser(FakeBrowser.approve);
      final flow = OAuthBrowserFlow(config(), authenticate: browser.call);

      final auth = await flow.authorize(OAuthProvider.google);

      expect(auth.code, 'the-code');
      expect(auth.redirectUri, _redirect);
      expect(browser.scheme, 'musicroom');
      expect(browser.opened!.host, 'accounts.google.com');
    });

    test('every login gets a fresh, unguessable state', () async {
      final states = <String>[];
      final browser = FakeBrowser((opened) {
        states.add(opened.queryParameters['state']!);
        return FakeBrowser.approve(opened);
      });
      final flow = OAuthBrowserFlow(config(), authenticate: browser.call);

      await flow.authorize(OAuthProvider.google);
      await flow.authorize(OAuthProvider.google);

      expect(states[0], isNot(states[1]));
      expect(states[0].length, greaterThanOrEqualTo(40)); // 32 random bytes, base64url
    });

    test('a redirect with someone else\'s state is refused', () async {
      final browser = FakeBrowser((_) => 'musicroom://oauth?code=stolen&state=attacker');
      final flow = OAuthBrowserFlow(config(), authenticate: browser.call);

      await expectLater(flow.authorize(OAuthProvider.google), throwsA(isA<OAuthFailedError>()));
    });

    test('closing the window is a cancellation, not a failure', () async {
      final flow = OAuthBrowserFlow(
        config(),
        authenticate: ({required url, required callbackUrlScheme, options}) =>
            throw PlatformException(code: 'CANCELED'),
      );

      await expectLater(flow.authorize(OAuthProvider.google), throwsA(isA<OAuthCancelledError>()));
    });

    test('declining on the provider page is a cancellation too', () async {
      final browser = FakeBrowser((opened) =>
          'musicroom://oauth?error=access_denied&state=${opened.queryParameters['state']}');
      final flow = OAuthBrowserFlow(config(), authenticate: browser.call);

      await expectLater(flow.authorize(OAuthProvider.google), throwsA(isA<OAuthCancelledError>()));
    });

    test('any other provider error, or no code, is a failure', () async {
      for (final query in ['error=server_error', '']) {
        final browser = FakeBrowser(
            (opened) => 'musicroom://oauth?$query&state=${opened.queryParameters['state']}');
        final flow = OAuthBrowserFlow(config(), authenticate: browser.call);

        await expectLater(
          flow.authorize(OAuthProvider.google),
          throwsA(isA<OAuthFailedError>()),
          reason: query,
        );
      }
    });

    test('a platform failure is a failure', () async {
      final flow = OAuthBrowserFlow(
        config(),
        authenticate: ({required url, required callbackUrlScheme, options}) =>
            throw PlatformException(code: 'error'),
      );

      await expectLater(flow.authorize(OAuthProvider.google), throwsA(isA<OAuthFailedError>()));
    });

    test('the app\'s own window (Linux) stops at the redirect URI itself', () async {
      final browser = FakeBrowser((opened) =>
          '$_redirect?code=42-code&state=${opened.queryParameters['state']}');
      final flow =
          OAuthBrowserFlow(config(catchesRedirect: true), authenticate: browser.call);

      final auth = await flow.authorize(OAuthProvider.intra42);

      expect(browser.scheme, 'http');
      expect(browser.options?.httpsHost, 'localhost');
      expect(browser.options?.httpsPath, '/oauth/callback');
      expect(auth.code, '42-code');
      expect(auth.redirectUri, _redirect);
    });

    test('there too, a redirect with someone else\'s state is refused', () async {
      final browser = FakeBrowser((_) => '$_redirect?code=stolen&state=attacker');
      final flow =
          OAuthBrowserFlow(config(catchesRedirect: true), authenticate: browser.call);

      await expectLater(flow.authorize(OAuthProvider.intra42), throwsA(isA<OAuthFailedError>()));
    });

    test('an unconfigured provider never opens a window', () async {
      final browser = FakeBrowser(FakeBrowser.approve);
      final flow = OAuthBrowserFlow(config(), authenticate: browser.call);

      await expectLater(flow.authorize(OAuthProvider.facebook), throwsA(isA<OAuthFailedError>()));
      expect(browser.opened, isNull);
    });
  });
}
