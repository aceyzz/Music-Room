// Runs what the profile page does against a real backend: ProfileStore ->
// UserGrpcSource -> AuthInterceptor -> UserService, then fetches the avatar
// from the URL the app builds, so the `/media/` handler and image-service
// are covered too.
//
// Opt-in, like auth_live_test.dart:
//
//   flutter test test/live --dart-define=LIVE_GRPC_HOST=localhost
//
// The avatar URL comes from AppConstants, so BACKEND_HOST / BACKEND_HTTP_PORT
// must reach the backend from where the test runs (their defaults do on the
// host).
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/stores/profile_store.dart';

import '../mocks/mock_flutter_secure_storage.dart';

const _host = String.fromEnvironment('LIVE_GRPC_HOST');
const _port = int.fromEnvironment('LIVE_GRPC_PORT', defaultValue: 50051);

/// A 1x1 PNG: the smallest thing image-service will decode and resize.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientChannel channel;
  late ProfileStore profile;

  setUpAll(() async {
    if (_host.isEmpty) {
      return;
    }
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    channel = ClientChannel(
      _host,
      port: _port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final credentials = SessionCredentials();
    final interceptors = [AuthInterceptor(credentials)];
    final users = UserGrpcSource(channel, interceptors);
    final session = SessionStore(
      SessionRepository(
        api: AuthGrpcSource(channel, interceptors),
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
      users: users,
    );
    await session.start();

    // A fresh account per run. The email stays unverified: the server does
    // not require it for profile writes (the app's router does).
    final stamp = DateTime.now().millisecondsSinceEpoch;
    await session.register(
      email: 'live-profile-$stamp@example.test',
      password: 'live-password',
      displayName: 'liveprofile$stamp',
    );
    final user = (session.state.value as SignedIn).user;
    profile = ProfileStore(users, user.publicId);
  });

  tearDownAll(() async {
    if (_host.isNotEmpty) {
      await channel.shutdown();
    }
  });

  group('live profile', skip: _host.isEmpty ? 'set --dart-define=LIVE_GRPC_HOST' : null, () {
    test('a new account loads with no details and the default scopes', () async {
      await profile.start();

      final p = profile.state.value.data!;
      expect(profile.state.value.error, isNull);
      expect(p.displayName, startsWith('liveprofile'));
      expect(p.avatarUrl, isNull);
      expect(p.bio, isNull);
      for (final field in ProfileField.values) {
        expect(p.visibilityOf(field), field.defaultVisibility, reason: field.name);
      }
    });

    test('details and scopes are saved and come back', () async {
      await profile.save(ProfileUpdate(
        firstName: 'Ada',
        bio: 'Live bio',
        birthDate: DateTime(1990, 3, 7),
        city: 'Paris',
        countryCode: 'FR',
        visibility: const {ProfileField.bio: ProfileVisibility.private},
      ));

      await profile.reload();
      final p = profile.state.value.data!;
      expect(p.firstName, 'Ada');
      expect(p.bio, 'Live bio');
      expect(p.birthDate, DateTime(1990, 3, 7));
      expect(p.countryCode, 'FR');
      expect(p.visibilityOf(ProfileField.bio), ProfileVisibility.private);
      expect(p.visibilityOf(ProfileField.phone), ProfileVisibility.private); // untouched
    });

    test('a partial update leaves the fields it does not send', () async {
      await profile.save(const ProfileUpdate(phoneNumber: '+33612345678'));

      await profile.reload();
      final p = profile.state.value.data!;
      expect(p.phoneNumber, '+33612345678');
      expect(p.bio, 'Live bio');
      expect(p.city, 'Paris');
    });

    test('a field emptied in the form is cleared on the server', () async {
      // What the profile page sends: the whole form, bio and birth date blank.
      await profile.save(ProfileUpdate.fromForm(
        firstName: 'Ada',
        city: 'Paris',
        countryCode: 'FR',
        phoneNumber: '+33612345678',
        bio: '',
        clearBlanks: true,
      ));

      await profile.reload();
      final p = profile.state.value.data!;
      expect(p.bio, isNull);
      expect(p.birthDate, isNull);
      expect(p.lastName, isNull);
      expect(p.firstName, 'Ada');
      expect(p.city, 'Paris');
    });

    test('an uploaded avatar is served at the URL the app builds, then removed', () async {
      await profile.changeAvatar(_png);
      await _expectServedPng(profile.state.value.data!.avatarUrl);

      await profile.removeAvatar();
      expect(profile.state.value.data!.avatarUrl, isNull);
    });

    test('an avatar over 4 MB goes through', () async {
      // Above both limits that used to sit under the advertised 5 MiB: gRPC's
      // default 4 MiB message size, and image-service's 2 MB request body
      // (about 1.5 MB of image once base64-encoded).
      final big = _noisePng(1200, 1200);
      expect(big.length, inInclusiveRange(4 << 20, 5 << 20));

      await profile.changeAvatar(big);
      await _expectServedPng(profile.state.value.data!.avatarUrl);
      await profile.removeAvatar();
    });
  });
}

/// Fetches [url] for real and checks it is a PNG.
Future<void> _expectServedPng(String? url) async {
  expect(url, isNotNull);
  // TestWidgetsFlutterBinding swaps HttpClient for one that answers 400 to
  // everything; this request has to reach the server.
  await HttpOverrides.runWithHttpOverrides(() async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(url!))).close();
      await response.drain<void>();
      expect(response.statusCode, 200, reason: url);
      expect(response.headers.contentType?.mimeType, 'image/png');
    } finally {
      client.close();
    }
  }, _RealHttp());
}

class _RealHttp extends HttpOverrides {}

/// A valid RGB PNG of random pixels. Noise does not compress, so the file is
/// about width * height * 3 bytes: a size can be picked without an image
/// library.
Uint8List _noisePng(int width, int height) {
  final random = Random(42);
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0); // filter: none
    raw.add(List.generate(width * 3, (_) => random.nextInt(256)));
  }

  final png = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final typed = [...ascii.encode(type), ...data];
    png
      ..add(_uint32(data.length))
      ..add(typed)
      ..add(_uint32(_crc32(typed)));
  }

  chunk('IHDR', [..._uint32(width), ..._uint32(height), 8, 2, 0, 0, 0]); // 8-bit RGB
  chunk('IDAT', zlib.encode(raw.takeBytes()));
  chunk('IEND', const []);
  return png.takeBytes();
}

List<int> _uint32(int v) => [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
