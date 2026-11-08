import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/mapping/user.mapping.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/gen/music_room/v1/dto/user.pb.dart';
import 'package:app/gen/music_room/v1/services/user_service.pb.dart';

void main() {
  test('absent fields map to "" (unchanged) and the birth date to YYYY-MM-DD', () {
    final request =
        ProfileUpdate(firstName: 'Ada', birthDate: DateTime(1990, 3, 7, 15, 30)).toRequest('u-1');

    expect(request.userPublicId, 'u-1');
    expect(request.firstName, 'Ada');
    expect(request.birthDate, '1990-03-07');
    expect(request.hasLastName(), isFalse); // absent: "leave unchanged"
    expect(request.hasCountryCode(), isFalse);
    expect(request.hasUserId(), isFalse); // stamped by the server interceptor
  });

  test('with clearsBlanks, every null field is sent empty: "clear it"', () {
    final request =
        ProfileUpdate.fromForm(firstName: 'Ada', bio: '  ', clearBlanks: true).toRequest('u-1');

    expect(request.firstName, 'Ada');
    for (final (name, has, value) in [
      ('bio', request.hasBio(), request.bio),
      ('lastName', request.hasLastName(), request.lastName),
      ('birthDate', request.hasBirthDate(), request.birthDate),
      ('city', request.hasCity(), request.city),
      ('countryCode', request.hasCountryCode(), request.countryCode),
      ('phoneNumber', request.hasPhoneNumber(), request.phoneNumber),
    ]) {
      expect(has, isTrue, reason: name);
      expect(value, '', reason: name);
    }
  });

  test('a sent-empty field survives the wire; an absent one does not', () {
    final cleared = UpdateUserProfileRequest.fromBuffer(
      const ProfileUpdate(clearsBlanks: true).toRequest('u-1').writeToBuffer(),
    );
    final untouched = UpdateUserProfileRequest.fromBuffer(
      const ProfileUpdate().toRequest('u-1').writeToBuffer(),
    );

    expect(cleared.hasBio(), isTrue);
    expect(untouched.hasBio(), isFalse);
  });

  test('only the scopes in the update are sent; the rest stay ""', () {
    final request = const ProfileUpdate(visibility: {
      ProfileField.phone: ProfileVisibility.friends,
      ProfileField.location: ProfileVisibility.private,
    }).toRequest('u-1');

    expect(request.phoneVisibility, 'friends');
    expect(request.locationVisibility, 'private');
    expect(request.bioVisibility, '');
    expect(request.preferencesVisibility, '');
  });

  test('a UserDTO maps empty strings to null and the storage key to a URL', () {
    final profile = UserDTO(
      publicId: 'u-1',
      displayName: 'neo',
      avatarStorageKey: 'avatars/abc.png',
      firstName: 'Thomas',
      birthDate: '1990-03-07',
      countryCode: 'FR',
      bioVisibility: 'private',
      phoneVisibility: 'public',
    ).toDomain(mediaUrl: (key) => 'http://media.test/$key');

    expect(profile.avatarUrl, 'http://media.test/avatars/abc.png');
    expect(profile.firstName, 'Thomas');
    expect(profile.lastName, isNull);
    expect(profile.birthDate, DateTime(1990, 3, 7));
    expect(profile.countryCode, 'FR');
    expect(profile.visibilityOf(ProfileField.bio), ProfileVisibility.private);
    expect(profile.visibilityOf(ProfileField.phone), ProfileVisibility.public);
  });

  test('no avatar, and empty or unknown scopes fall back to the server defaults', () {
    final profile = UserDTO(publicId: 'u-1', displayName: 'neo', firstNameVisibility: 'enemies')
        .toDomain(mediaUrl: (key) => fail('no key to resolve'));

    expect(profile.avatarUrl, isNull);
    expect(profile.birthDate, isNull);
    expect(profile.visibility.keys, unorderedEquals(ProfileField.values));
    expect(profile.visibilityOf(ProfileField.firstName), ProfileVisibility.friends);
    expect(profile.visibilityOf(ProfileField.birthDate), ProfileVisibility.private);
    expect(profile.visibilityOf(ProfileField.preferences), ProfileVisibility.public);
  });
}
