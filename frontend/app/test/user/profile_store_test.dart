import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/features/user/data/avatar_image.dart';
import 'package:app/features/user/presentation/stores/profile_store.dart';

import '../auth/fake_auth_api.dart';

final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);

void main() {
  late FakeUserApi users;
  late ProfileStore store;

  setUp(() {
    users = FakeUserApi()
      ..profile = const UserProfile(
        publicId: 'u-1',
        displayName: 'neo',
        bio: 'Follows the white rabbit',
        city: 'Zion',
        visibility: {},
      );
    store = ProfileStore(users, 'u-1');
  });

  test('start loads the profile', () async {
    await store.start();

    expect(store.state.value.isLoading, isFalse);
    expect(store.profile?.bio, 'Follows the white rabbit');
  });

  test('a failed load is reported through the state, and reload recovers', () async {
    users.failure = const NetworkError('offline');
    await store.start();

    expect(store.state.value.error, isA<NetworkError>());
    expect(store.profile, isNull);

    users.failure = null;
    await store.reload();
    expect(store.state.value.hasError, isFalse);
    expect(store.profile, isNotNull);
  });

  test('save sends the whole form: emptied fields are cleared, others written', () async {
    await store.start();

    await store.save(ProfileUpdate.fromForm(
      firstName: 'Thomas',
      bio: '   ', // emptied by the user
      city: 'Zion',
      visibility: {ProfileField.bio: ProfileVisibility.private},
      clearBlanks: true,
    ));

    final (publicId, sent) = users.updates.single;
    expect(publicId, 'u-1');
    expect(sent.bio, isNull);
    expect(sent.clearsBlanks, isTrue);
    expect(store.profile?.firstName, 'Thomas');
    expect(store.profile?.bio, isNull);
    expect(store.profile?.city, 'Zion');
    expect(store.profile?.visibilityOf(ProfileField.bio), ProfileVisibility.private);
  });

  test('a partial update leaves the fields it does not name', () async {
    await store.start();

    await store.save(const ProfileUpdate(firstName: 'Thomas'));

    expect(store.profile?.bio, 'Follows the white rabbit');
    expect(store.profile?.city, 'Zion');
  });

  test('a failed save throws and leaves the profile as it was', () async {
    await store.start();
    final before = store.profile;
    users.failure = const InvalidInputError('country_code');

    await expectLater(
      store.save(const ProfileUpdate(countryCode: 'XX')),
      throwsA(isA<InvalidInputError>()),
    );
    expect(store.profile, before);
  });

  test('changeAvatar uploads with the sniffed type; removeAvatar clears it', () async {
    await store.start();

    await store.changeAvatar(jpeg);
    expect(users.avatars.single.$2, 'image/jpeg');
    expect(store.profile?.avatarUrl, isNotNull);

    await store.removeAvatar();
    expect(store.profile?.avatarUrl, isNull);
  });

  test('an unsupported image is refused without calling the server', () async {
    await store.start();

    await expectLater(
      store.changeAvatar(Uint8List.fromList([0x47, 0x49, 0x46, 0x38])), // GIF
      throwsA(isA<AvatarRejectedError>()),
    );
    expect(users.calls, ['getProfile']);
  });

  test('a request finishing after stop does not touch the disposed state', () async {
    final pending = store.start();
    store.stop();
    await pending; // would throw "used after being disposed"
  });
}
