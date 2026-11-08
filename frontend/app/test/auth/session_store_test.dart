import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';

import '../mocks/mock_flutter_secure_storage.dart';
import 'fake_auth_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAuthApi api;
  late SessionCredentials credentials;
  late TokenStorageService storage;
  late FakeUserApi users;

  SessionStore newStore({String devToken = '', OAuthBrowserFlow? oauth}) => SessionStore(
        SessionRepository(
          api: api,
          storage: storage,
          credentials: credentials,
          devSessionToken: devToken,
        ),
        credentials,
        users: users,
        oauth: oauth,
      );

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi();
    credentials = SessionCredentials();
    storage = TokenStorageService();
    users = FakeUserApi(api.calls);
  });

  test('starts signed out with nothing stored', () async {
    final store = newStore();
    await store.start();

    expect(store.state.value, const SignedOut());
    expect(credentials.token, isNull);
  });

  test('login signs in, persists the session and arms the interceptor', () async {
    final store = newStore();
    await store.start();

    await store.login(email: ' neo@example.test ', password: 'password1234');

    final state = store.state.value as SignedIn;
    expect(state.user.email, 'neo@example.test'); // trimmed
    expect(credentials.token, 'token-neo@example.test');
    expect((await storage.readSession())?.token, 'token-neo@example.test');
  });

  test('a restart restores the stored session', () async {
    await (newStore()..start()).login(email: 'neo@example.test', password: 'password1234');

    final restarted = newStore();
    await restarted.start();

    expect(restarted.state.value, isA<SignedIn>());
    expect(credentials.token, 'token-neo@example.test');
  });

  test('an absolutely expired stored session is dropped at startup', () async {
    await (newStore()..start()).login(email: 'neo@example.test', password: 'password1234');
    final stored = await storage.readSession();
    expect(stored, isNotNull);

    expect(await storage.readSession(now: DateTime.now().add(const Duration(days: 31))), isNull);
    expect(await storage.getToken(), isNull);
  });

  test('register creates the account then logs in', () async {
    final store = newStore();
    await store.start();

    await store.register(email: 'neo@example.test', password: 'password1234', displayName: 'neo');

    expect(api.calls, ['register', 'login']);
    expect((store.state.value as SignedIn).user.emailVerified, isFalse);
  });

  test('register saves the profile before announcing the session', () async {
    final store = newStore();
    await store.start();
    const profile = ProfileUpdate(firstName: 'Thomas', countryCode: 'FR');
    final seenAtUpdate = <SessionState>[];
    store.state.addListener(() => seenAtUpdate.add(store.state.value));

    final saved = await store.register(
      email: 'neo@example.test',
      password: 'password1234',
      displayName: 'neo',
      profile: profile,
    );

    expect(saved, isTrue);
    expect(api.calls, ['register', 'login', 'updateProfile']);
    expect(users.updates.single, ('u-1', profile));
    // One change, after the profile: the router must not leave the page early.
    expect(seenAtUpdate, hasLength(1));
    expect(store.state.value, isA<SignedIn>());
  });

  test('register skips the profile call when nothing optional was filled in', () async {
    final store = newStore();
    await store.start();

    final saved = await store.register(
      email: 'neo@example.test',
      password: 'password1234',
      displayName: 'neo',
      profile: ProfileUpdate.fromForm(firstName: '  ', bio: ''),
    );

    expect(saved, isTrue);
    expect(api.calls, ['register', 'login']);
  });

  test('a failed profile save still signs in, and says so', () async {
    final store = newStore();
    await store.start();
    users.failure = const UnknownError('permission not synced yet');

    final saved = await store.register(
      email: 'neo@example.test',
      password: 'password1234',
      displayName: 'neo',
      profile: const ProfileUpdate(bio: 'hello'),
    );

    expect(saved, isFalse);
    expect(store.state.value, isA<SignedIn>());
    expect(credentials.token, 'token-neo@example.test');
  });

  test('oauth login signs in and persists the session', () async {
    final store = newStore();
    await store.start();

    await store.oauthLogin(
      provider: OAuthProvider.intra42,
      code: 'abc',
      redirectUri: 'musicroom://oauth',
    );

    expect((store.state.value as SignedIn).user.email, 'intra42@example.test');
    expect((await storage.readSession())?.token, 'token-intra42@example.test');
  });

  group('signInWithProvider', () {
    OAuthBrowserFlow flow(BrowserAuthenticate authenticate) => OAuthBrowserFlow(
          const OAuthConfig(
            clientIds: {OAuthProvider.intra42: '42-id'},
            redirectUri: 'https://api.example.test/oauth/callback',
            callbackScheme: 'musicroom',
            platformSupported: true,
          ),
          authenticate: authenticate,
        );

    test('runs the login window, then exchanges its code on the server', () async {
      final store = newStore(
        oauth: flow(({required url, required callbackUrlScheme, options}) async =>
            'musicroom://oauth?code=c0de&state=${Uri.parse(url).queryParameters['state']}'),
      );
      await store.start();

      expect(store.oauthProviders, {OAuthProvider.intra42});
      await store.signInWithProvider(OAuthProvider.intra42);

      expect(api.lastOAuth, (
        provider: OAuthProvider.intra42,
        code: 'c0de',
        redirectUri: 'https://api.example.test/oauth/callback',
      ));
      expect(store.state.value, isA<SignedIn>());
      expect(credentials.token, 'token-intra42@example.test');
    });

    test('a closed login window leaves the user signed out, server untouched', () async {
      final store = newStore(
        oauth: flow(({required url, required callbackUrlScheme, options}) =>
            throw PlatformException(code: 'CANCELED')),
      );
      await store.start();

      await expectLater(
        store.signInWithProvider(OAuthProvider.intra42),
        throwsA(isA<OAuthCancelledError>()),
      );
      expect(api.calls, isEmpty);
      expect(store.state.value, const SignedOut());
    });

    test('without a flow there are no providers and signing in fails cleanly', () async {
      final store = newStore();
      await store.start();

      expect(store.oauthProviders, isEmpty);
      await expectLater(
        store.signInWithProvider(OAuthProvider.google),
        throwsA(isA<OAuthFailedError>()),
      );
    });
  });

  test('resetting the password signs in with the new one', () async {
    final store = newStore();
    await store.start();

    await store.requestPasswordReset(' neo@example.test ');
    await store.resetPassword(
      email: 'neo@example.test',
      code: ' 123456 ',
      newPassword: 'new-password',
    );

    expect(api.calls, ['requestPasswordReset', 'resetPassword', 'login']);
    expect(store.state.value, isA<SignedIn>());
  });

  test('a wrong reset code leaves the user signed out', () async {
    final store = newStore();
    await store.start();
    api.failures['resetPassword'] = const InvalidInputError('invalid code');

    await expectLater(
      store.resetPassword(email: 'neo@example.test', code: '000000', newPassword: 'x' * 8),
      throwsA(isA<InvalidInputError>()),
    );
    expect(api.calls, ['resetPassword']);
    expect(store.state.value, const SignedOut());
  });

  test('a failed login leaves the state alone and rethrows', () async {
    final store = newStore();
    await store.start();
    api.failures['login'] = const UnauthorizedError('invalid credentials');

    await expectLater(
      store.login(email: 'neo@example.test', password: 'nope'),
      throwsA(isA<UnauthorizedError>()),
    );
    expect(store.state.value, const SignedOut());
    expect(credentials.token, isNull);
  });

  test('logout clears everything even when the server call fails', () async {
    final store = newStore();
    await store.start();
    await store.login(email: 'neo@example.test', password: 'password1234');
    api.failures['logout'] = const NetworkError('offline');

    await store.logout();

    expect(store.state.value, const SignedOut());
    expect(credentials.token, isNull);
    expect(await storage.getToken(), isNull);
  });

  test('a server rejection signs out and says the session expired', () async {
    final store = newStore();
    await store.start();
    await store.login(email: 'neo@example.test', password: 'password1234');

    credentials.reject('token-neo@example.test');
    await pumpEventQueue();

    expect(store.state.value, const SignedOut(expired: true));
    expect(await storage.getToken(), isNull);
  });

  test('verifying the email updates and persists the session', () async {
    final store = newStore();
    await store.start();
    await store.login(email: 'neo@example.test', password: 'password1234');

    await store.verifyEmail(' 123456 ');

    expect((store.state.value as SignedIn).user.emailVerified, isTrue);
    expect((await storage.readSession())?.user.emailVerified, isTrue);
  });

  test('"already verified" from the server counts as verified', () async {
    final store = newStore();
    await store.start();
    await store.login(email: 'neo@example.test', password: 'password1234');
    api.failures['requestEmailVerification'] = const PreconditionFailedError('already verified');

    await store.resendVerificationCode();

    expect((store.state.value as SignedIn).user.emailVerified, isTrue);
  });

  test('a wrong code leaves the email unverified', () async {
    final store = newStore();
    await store.start();
    await store.login(email: 'neo@example.test', password: 'password1234');
    api.failures['verifyEmail'] = const InvalidInputError('invalid code');

    await expectLater(store.verifyEmail('000000'), throwsA(isA<InvalidInputError>()));
    expect((store.state.value as SignedIn).user.emailVerified, isFalse);
  });

  test('the dev token signs in when nothing is stored', () async {
    final store = newStore(devToken: 'dev-token');
    await store.start();

    expect(store.state.value, isA<SignedIn>());
    expect(credentials.token, 'dev-token');
  });
}
