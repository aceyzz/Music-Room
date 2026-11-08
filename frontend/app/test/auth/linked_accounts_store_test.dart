import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/presentation/stores/linked_accounts_store.dart';

import 'fake_linked_accounts_api.dart';

void main() {
  late FakeLinkedAccountsApi api;

  setUp(() => api = FakeLinkedAccountsApi());

  OAuthBrowserFlow flow(BrowserAuthenticate authenticate) => OAuthBrowserFlow(
    const OAuthConfig(
      clientIds: {OAuthProvider.google: 'google-id'},
      redirectUri: 'https://api.example.test/oauth/callback',
      callbackScheme: 'musicroom',
      platformSupported: true,
    ),
    authenticate: authenticate,
  );

  /// A login window that comes back with [code] and the state it was sent.
  BrowserAuthenticate returns(String code) =>
      ({required url, required callbackUrlScheme, options}) async =>
          'musicroom://oauth?code=$code&state=${Uri.parse(url).queryParameters['state']}';

  BrowserAuthenticate closed() =>
      ({required url, required callbackUrlScheme, options}) =>
          throw PlatformException(code: 'CANCELED');

  test('start loads what is linked, and only configured providers are linkable', () async {
    api.linked[OAuthProvider.intra42] = LinkedAccount(
      provider: OAuthProvider.intra42,
      linkedAt: DateTime.utc(2026),
    );
    final store = LinkedAccountsStore(api, flow(returns('x')));
    addTearDown(store.stop);

    await store.start();

    expect(store.accounts?.of(OAuthProvider.intra42), isNotNull);
    expect(store.accounts?.of(OAuthProvider.google), isNull);
    expect(store.linkableProviders, {OAuthProvider.google});
  });

  test('link runs the login window, sends its code, then refetches', () async {
    final store = LinkedAccountsStore(api, flow(returns('c0de')));
    addTearDown(store.stop);
    await store.start();

    await store.link(OAuthProvider.google);

    expect(api.lastLink, (
      provider: OAuthProvider.google,
      code: 'c0de',
      redirectUri: 'https://api.example.test/oauth/callback',
    ));
    expect(api.calls, ['listOAuthAccounts', 'linkOAuthAccount', 'listOAuthAccounts']);
    expect(store.accounts?.of(OAuthProvider.google)?.email, 'google@example.test');
  });

  test('a closed login window throws OAuthCancelledError and calls nothing', () async {
    final store = LinkedAccountsStore(api, flow(closed()));
    addTearDown(store.stop);
    await store.start();

    await expectLater(store.link(OAuthProvider.google), throwsA(isA<OAuthCancelledError>()));
    expect(api.calls, ['listOAuthAccounts']);
  });

  test('an identity owned by another account surfaces as ConflictError', () async {
    api.failures['linkOAuthAccount'] = const ConflictError('identity already linked');
    final store = LinkedAccountsStore(api, flow(returns('c0de')));
    addTearDown(store.stop);
    await store.start();

    await expectLater(store.link(OAuthProvider.google), throwsA(isA<ConflictError>()));
    expect(store.accounts?.accounts, isEmpty);
  });

  test('the last way to sign in cannot be unlinked', () async {
    api
      ..hasPassword = false
      ..linked[OAuthProvider.google] = LinkedAccount(
        provider: OAuthProvider.google,
        linkedAt: DateTime.utc(2026),
      );
    final store = LinkedAccountsStore(api, flow(returns('x')));
    addTearDown(store.stop);
    await store.start();

    expect(store.accounts?.canUnlink, isFalse);
    await expectLater(store.unlink(OAuthProvider.google), throwsA(isA<PreconditionFailedError>()));
    expect(store.accounts?.of(OAuthProvider.google), isNotNull);
  });

  test('unlink removes the row once a password is set', () async {
    api.linked[OAuthProvider.google] = LinkedAccount(
      provider: OAuthProvider.google,
      linkedAt: DateTime.utc(2026),
    );
    final store = LinkedAccountsStore(api, flow(returns('x')));
    addTearDown(store.stop);
    await store.start();

    expect(store.accounts?.canUnlink, isTrue);
    await store.unlink(OAuthProvider.google);

    expect(store.accounts?.accounts, isEmpty);
  });

  test('a failed load is reported through state, keeping nothing stale', () async {
    api.failures['listOAuthAccounts'] = const NetworkError('down');
    final store = LinkedAccountsStore(api, flow(returns('x')));
    addTearDown(store.stop);

    await store.start();

    expect(store.state.value.error, isA<NetworkError>());
    expect(store.accounts, isNull);
  });

  test('a link that finishes after the page closed does not throw', () async {
    final store = LinkedAccountsStore(api, flow(returns('c0de')));
    await store.start();
    final pending = store.link(OAuthProvider.google);
    store.stop();

    await pending;
    expect(api.linked, contains(OAuthProvider.google));
  });
}
