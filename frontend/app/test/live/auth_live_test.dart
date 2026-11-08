// Runs the auth flows the sign-in, sign-up and reset pages use against a real
// backend: SessionStore -> SessionRepository -> AuthGrpcSource / UserGrpcSource
// -> AuthInterceptor -> the server. Only secure storage is faked (no keychain
// under `flutter test`).
//
// Opt-in, skipped by a plain `flutter test`:
//
//   flutter test test/live --dart-define=LIVE_GRPC_HOST=localhost
//
// The emailed codes are read from the backend's log mailer (APP_MAILER=log,
// the default), by running LIVE_MAIL_CMD and searching its output. The default
// suits a host with the docker CLI and the compose container names.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/auth_error_messages.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/gen/music_room/v1/services/user_service.pbgrpc.dart';

import '../mocks/mock_flutter_secure_storage.dart';

const _host = String.fromEnvironment('LIVE_GRPC_HOST');
const _port = int.fromEnvironment('LIVE_GRPC_PORT', defaultValue: 50051);
const _httpPort = int.fromEnvironment('LIVE_HTTP_PORT', defaultValue: 8081);

/// Name of a provider the backend was started with credentials for (even
/// placeholder ones): its OAuthLogin then reaches the provider's real token
/// endpoint. Empty skips that test.
const _configuredProvider = String.fromEnvironment('LIVE_OAUTH_CONFIGURED_PROVIDER');

const _mailCmd = String.fromEnvironment(
  'LIVE_MAIL_CMD',
  defaultValue: 'docker logs --tail 400 music-room-backend 2>&1',
);

const _verifySubject = 'Music Room - code de verification';
const _resetSubject = 'Music Room - reinitialisation du mot de passe';

/// The newest 6-digit code mailed to [email] under [subject]. Polls briefly:
/// the log line can land just after the RPC returns.
Future<String> _mailedCode(String email, String subject, {String? notThis}) async {
  final pattern = RegExp(
    'to=${RegExp.escape(email)} subject="${RegExp.escape(subject)}"[\\s\\S]*?(\\d{6})',
  );
  for (var i = 0; i < 20; i++) {
    // Latin-1 decodes any byte: docker's raw log stream carries binary frame
    // headers that a UTF-8 decoder rejects, and the codes are ASCII anyway.
    final result = await Process.run('sh', ['-c', _mailCmd], stdoutEncoding: latin1);
    final codes = pattern.allMatches('${result.stdout}').map((m) => m.group(1)!).toList();
    if (codes.isNotEmpty && codes.last != notThis) {
      return codes.last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError('No "$subject" code for $email in: $_mailCmd');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientChannel channel;
  late SessionCredentials credentials;
  late List<ClientInterceptor> interceptors;
  late SessionStore store;

  // One account per run, so reruns never collide with "email taken".
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final email = 'live-$stamp@example.test';
  final displayName = 'live$stamp';
  const password = 'first-password';
  const newPassword = 'second-password';

  SessionStore newStore() => SessionStore(
        SessionRepository(
          api: AuthGrpcSource(channel, interceptors),
          storage: TokenStorageService(),
          credentials: credentials,
          devSessionToken: '',
        ),
        credentials,
        users: UserGrpcSource(channel, interceptors),
      );

  setUpAll(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    channel = ClientChannel(
      _host,
      port: _port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    credentials = SessionCredentials();
    interceptors = [AuthInterceptor(credentials)];
    store = newStore();
    await store.start();
  });

  tearDownAll(() => channel.shutdown());

  SignedIn signedIn() => store.state.value as SignedIn;

  // The tests below are one story, in order: each starts where the last ended.
  group('live auth', skip: _host.isEmpty ? 'set --dart-define=LIVE_GRPC_HOST' : null, () {
    test('sign-up with every optional field saves the profile', () async {
      final saved = await store.register(
        email: email,
        password: password,
        displayName: displayName,
        profile: ProfileUpdate(
          firstName: 'Ada',
          lastName: 'Lovelace',
          birthDate: DateTime(1990, 3, 7),
          city: 'Paris',
          countryCode: 'FR',
          phoneNumber: '+33 6 12 34 56 78',
          bio: 'Live test account',
        ),
      );

      expect(saved, isTrue, reason: 'UpdateUserProfile should succeed for a new account');
      expect(signedIn().user.email, email);
      expect(signedIn().user.emailVerified, isFalse);

      // Read it back the way any page would: as the user, through the interceptor.
      final users = UserServiceClient(channel, interceptors: interceptors);
      final me = (await users.getUser(GetUserRequest(
        publicId: signedIn().user.publicId,
        viewerPublicId: signedIn().user.publicId,
      )))
          .user;
      expect(me.displayName, displayName);
      expect(me.firstName, 'Ada');
      expect(me.lastName, 'Lovelace');
      expect(me.birthDate, '1990-03-07');
      expect(me.city, 'Paris');
      expect(me.countryCode, 'FR');
      expect(me.phoneNumber, '+33 6 12 34 56 78');
      expect(me.bio, 'Live test account');
    });

    test('a wrong verification code is refused', () async {
      await expectLater(store.verifyEmail('000000'), throwsA(isA<InvalidInputError>()));
      expect(signedIn().user.emailVerified, isFalse);
    });

    test('the mailed code verifies the email', () async {
      await store.verifyEmail(await _mailedCode(email, _verifySubject));
      expect(signedIn().user.emailVerified, isTrue);
    });

    test('signing up again with the same email is a conflict', () async {
      final other = newStore();
      await expectLater(
        other.register(email: email, password: password, displayName: '${displayName}x'),
        throwsA(isA<ConflictError>().having(
          (e) => authErrorMessage(e, AuthAction.register),
          'message',
          'That email or display name is already taken.',
        )),
      );
    });

    test('logout, then a wrong password, then the right one', () async {
      await store.logout();
      expect(store.state.value, const SignedOut());
      expect(credentials.token, isNull);

      await expectLater(
        store.login(email: email, password: 'not-the-password'),
        throwsA(isA<UnauthorizedError>().having(
          (e) => authErrorMessage(e, AuthAction.login),
          'message',
          'Wrong email or password.',
        )),
      );
      expect(store.state.value, const SignedOut());

      await store.login(email: email, password: password);
      expect(signedIn().user.emailVerified, isTrue, reason: 'verification survives a re-login');
    });

    test('password reset: a wrong code is refused, the mailed one signs in', () async {
      await store.logout();
      await store.requestPasswordReset(email);
      final code = await _mailedCode(email, _resetSubject);

      final wrong = code == '000000' ? '111111' : '000000';
      await expectLater(
        store.resetPassword(email: email, code: wrong, newPassword: newPassword),
        throwsA(isA<InvalidInputError>()),
      );
      expect(store.state.value, const SignedOut());

      await store.resetPassword(email: email, code: code, newPassword: newPassword);
      expect(signedIn().user.email, email);
    });

    test('after the reset only the new password works', () async {
      await store.logout();
      await expectLater(
        store.login(email: email, password: password),
        throwsA(isA<UnauthorizedError>()),
      );
      await store.login(email: email, password: newPassword);
      expect(store.state.value, isA<SignedIn>());
    });

    test('asking a reset for an unknown email looks the same as a known one', () async {
      await store.requestPasswordReset('nobody-$stamp@example.test');
    });

    test('the OAuth bounce page forwards the code to the app scheme', () async {
      // The test binding swaps HttpClient for a stub that answers 400 to
      // everything; this one request has to reach the real server.
      final stubbed = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = stubbed);
      final client = HttpClient();
      addTearDown(client.close);
      final request = await client.getUrl(
        Uri.parse('http://$_host:$_httpPort/oauth/callback?code=c%2F1&state=s&scope=email'),
      );
      request.followRedirects = false;
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.found);
      final location = Uri.parse(response.headers.value(HttpHeaders.locationHeader)!);
      expect('${location.scheme}://${location.host}', 'musicroom://oauth');
      expect(location.queryParameters, {'code': 'c/1', 'state': 's'});
      expect(response.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
    });

    test(
      'OAuth with a configured provider reaches its token endpoint, which refuses a fake code',
      skip: _configuredProvider.isEmpty
          ? 'set --dart-define=LIVE_OAUTH_CONFIGURED_PROVIDER=<name> (backend with credentials)'
          : null,
      () async {
        final provider = OAuthProvider.values.byName(_configuredProvider);
        await expectLater(
          store.oauthLogin(
            provider: provider,
            code: 'not-a-real-code',
            redirectUri: 'http://$_host:$_httpPort/oauth/callback',
          ),
          throwsA(isA<UnauthorizedError>().having(
            (e) => authErrorMessage(e, AuthAction.oauth),
            'message',
            'Sign-in with that provider failed. Try again.',
          )),
        );
      },
    );

    test('OAuth with a provider the server has no credentials for is refused', () async {
      // Holds while the backend runs without APP_OAUTH_* credentials (the
      // default): the provider is then not registered at all.
      await expectLater(
        store.oauthLogin(
          provider: OAuthProvider.google,
          code: 'fake-code',
          redirectUri: 'musicroom://oauth',
        ),
        throwsA(isA<InvalidInputError>().having(
          (e) => authErrorMessage(e, AuthAction.oauth),
          'message',
          'That provider is not available right now.',
        )),
      );
    });
  });
}
