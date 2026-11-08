import 'dart:async';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';

const withPicture = UserProfile(
  publicId: 'u-1',
  displayName: 'neo',
  avatarUrl: 'http://media.test/avatars/1.png',
  visibility: {},
);

/// A [FakeUserApi] whose getProfile answers only when the test says so.
class SlowUserApi extends FakeUserApi {
  final pending = <Completer<UserProfile>>[];

  @override
  Future<UserProfile> getProfile(String userPublicId) {
    calls.add('getProfile');
    final answer = Completer<UserProfile>();
    pending.add(answer);
    return answer.future;
  }
}

void main() {
  late FakeAuthApi api;
  late SessionStore session;

  Future<CurrentUserStore> start(FakeUserApi users) async {
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: api,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    return CurrentUserStore(users, session)..start();
  }

  Future<void> login() => session.login(email: 'neo@example.test', password: 'password1234');

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi()..emailVerified = true;
  });

  test('loads the profile on a verified login and clears it on logout', () async {
    final users = FakeUserApi()..profile = withPicture;
    final store = await start(users);
    expect(users.calls, isEmpty); // signed out

    await login();
    await pumpEventQueue();
    expect(store.profile.value, withPicture);

    await session.logout();
    expect(store.profile.value, isNull);
  });

  test('does not load while the email is unverified', () async {
    api.emailVerified = false;
    final users = FakeUserApi();
    final store = await start(users);

    await login();
    await pumpEventQueue();

    expect(users.calls, isEmpty);
    expect(store.profile.value, isNull);
  });

  test('update replaces the profile, but only for the signed-in user', () async {
    final users = FakeUserApi();
    final store = await start(users);
    await login();
    await pumpEventQueue();

    store.update(withPicture);
    expect(store.profile.value, withPicture);

    store.update(const UserProfile(publicId: 'u-2', displayName: 'trinity', visibility: {}));
    expect(store.profile.value, withPicture);
  });

  test('a failed load leaves it empty', () async {
    final users = FakeUserApi()..failure = const NetworkError('offline');
    final store = await start(users);

    await login();
    await pumpEventQueue();

    expect(users.calls, ['getProfile']);
    expect(store.profile.value, isNull);
  });

  test('a load that finishes after logout is dropped', () async {
    final users = SlowUserApi();
    final store = await start(users);
    await login();

    await session.logout();
    users.pending.single.complete(withPicture);
    await pumpEventQueue();

    expect(store.profile.value, isNull);
  });

  test('a load that finishes after stop does not touch the disposed notifier', () async {
    final users = SlowUserApi();
    final store = await start(users);
    await login();

    store.stop();
    users.pending.single.complete(withPicture);
    await pumpEventQueue(); // would throw "used after being disposed"
  });
}
