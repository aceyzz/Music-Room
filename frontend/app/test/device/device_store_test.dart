import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/device/device_info.dart';
import 'package:app/core/errors/app_error.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/storage/secure_token_storage.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';
import 'fake_device_api.dart';

void main() {
  late FakeAuthApi api;
  late FakeDeviceApi devices;
  late SessionStore session;

  Future<DeviceStore> start() async {
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
    final store = DeviceStore(
      devices,
      session,
      () => DeviceInfo.identifier(SecureTokenStorage()),
      DeviceInfo.fallback(),
    );
    addTearDown(store.stop);
    return store..start();
  }

  Future<void> login([String email = 'neo@example.test']) =>
      session.login(email: email, password: 'password1234');

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi();
    devices = FakeDeviceApi();
  });

  test('registers once per session, with an unverified email too', () async {
    final store = await start();
    expect(devices.registrations, isEmpty); // signed out

    await login();
    await pumpEventQueue();
    expect(devices.registrations, hasLength(1));
    expect(devices.registrations.single.user, 'u-1');
    expect(store.devicePublicId.value, 'device-1');
    expect(store.deviceId.value, 1);

    // Same token, new state (email verified): already bound.
    await session.verifyEmail('123456');
    await pumpEventQueue();
    expect(devices.registrations, hasLength(1));

    await session.logout();
    expect(store.devicePublicId.value, isNull);
    expect(store.deviceId.value, isNull);
  });

  test('a new session registers again, with the same install id', () async {
    await start();

    await login('neo@example.test');
    await pumpEventQueue();
    await session.logout();
    await login('trinity@example.test');
    await pumpEventQueue();

    expect(devices.registrations, hasLength(2));
    final ids = devices.registrations.map((r) => r.identifier).toSet();
    expect(ids, hasLength(1), reason: 'the install id survives logout');
  });

  test('a failed registration leaves the device unknown and the session alone', () async {
    devices.failure = const NetworkError('offline');
    final store = await start();

    await login();
    await pumpEventQueue();

    expect(store.devicePublicId.value, isNull);
    expect(session.state.value, isA<SignedIn>());
  });
}
