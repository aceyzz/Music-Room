import 'package:fixnum/fixnum.dart';

import 'package:app/core/models/user/friend_request.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/relationship.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/models/user/user_summary.dart';
import 'package:app/gen/music_room/v1/dto/user.pb.dart';
import 'package:app/gen/music_room/v1/services/user_service.pb.dart';
import 'package:app/globals/app_constants.dart';

// gRPC only for now: UserService is called natively, so there is no
// V1UserDTO (OpenAPI) mapper yet. Add one with the web source.

extension UserDTOMapping on UserDTO {
  /// [mediaUrl] turns the avatar's storage key into a URL; the default points
  /// at the configured backend, tests pass their own.
  UserProfile toDomain({String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) {
    String? text(String s) => s.isEmpty ? null : s;
    ProfileVisibility scope(ProfileField field, String wire) =>
        ProfileVisibility.fromWire(wire) ?? field.defaultVisibility;

    return UserProfile(
      publicId: publicId,
      displayName: displayName,
      avatarUrl: avatarStorageKey.isEmpty ? null : mediaUrl(avatarStorageKey),
      firstName: text(firstName),
      lastName: text(lastName),
      bio: text(bio),
      birthDate: DateTime.tryParse(birthDate),
      city: text(city),
      countryCode: text(countryCode),
      phoneNumber: text(phoneNumber),
      musicPreferences: [for (final p in musicPreferences) p.toDomain()],
      visibility: {
        ProfileField.firstName: scope(ProfileField.firstName, firstNameVisibility),
        ProfileField.lastName: scope(ProfileField.lastName, lastNameVisibility),
        ProfileField.bio: scope(ProfileField.bio, bioVisibility),
        ProfileField.birthDate: scope(ProfileField.birthDate, birthDateVisibility),
        ProfileField.location: scope(ProfileField.location, locationVisibility),
        ProfileField.phone: scope(ProfileField.phone, phoneVisibility),
        ProfileField.preferences: scope(ProfileField.preferences, preferencesVisibility),
      },
    );
  }
}

extension MusicPreferenceDTOMapping on MusicPreferenceDTO {
  MusicPreference toDomain() =>
      MusicPreference(genreId: deezerGenreId.toInt(), genreName: genreName, weight: weight);
}

extension MusicPreferenceMapping on MusicPreference {
  MusicPreferenceDTO toDto() =>
      MusicPreferenceDTO(deezerGenreId: Int64(genreId), genreName: genreName, weight: weight);
}

extension FriendDTOMapping on FriendDTO {
  FriendSummary toSummary({String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) =>
      FriendSummary(
        publicId: publicId,
        displayName: displayName,
        avatarUrl: avatarStorageKey.isEmpty ? null : mediaUrl(avatarStorageKey),
      );
}

extension UserSummaryDTOMapping on UserSummaryDTO {
  UserSummary toSummary({String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) =>
      UserSummary(
        publicId: publicId,
        displayName: displayName,
        avatarUrl: avatarStorageKey.isEmpty ? null : mediaUrl(avatarStorageKey),
      );
}

extension FriendRequestDTOMapping on FriendRequestDTO {
  /// [incoming] is the direction the list was asked for; the DTO's
  /// `other_user` is the requester or the addressee accordingly.
  FriendRequest toFriendRequest({
    required bool incoming,
    String Function(String storageKey) mediaUrl = AppConstants.mediaUrl,
  }) =>
      FriendRequest(
        id: id.toInt(),
        user: otherUser.toSummary(mediaUrl: mediaUrl),
        incoming: incoming,
      );
}

extension BlockedUserDTOMapping on BlockedUserDTO {
  /// No avatar: the server does not send one for a blocked account.
  UserSummary toSummary() => UserSummary(publicId: publicId, displayName: displayName);
}

extension GetUserRelationshipResponseMapping on GetUserRelationshipResponse {
  /// An unknown status reads as [FriendStatus.none]: offering "Add as friend"
  /// is the safe default, and the server says if it does not apply.
  Relationship toRelationship() => Relationship(
        status: switch (status) {
          'self' => FriendStatus.self,
          'friends' => FriendStatus.friends,
          'request_sent' => FriendStatus.requestSent,
          'request_received' => FriendStatus.requestReceived,
          _ => FriendStatus.none,
        },
        incomingRequestId: incomingRequestId == 0 ? null : incomingRequestId.toInt(),
        blockedByMe: blocked,
        displayName: displayName.isEmpty ? null : displayName,
      );
}

// Domain -> request, the opposite direction from the other mapping files.

extension ProfileUpdateMapping on ProfileUpdate {
  /// The profile fields are proto3 `optional` on UpdateUserProfileRequest: a
  /// field left unset is "leave unchanged", one set to '' is "clear it". So a
  /// null field is set (to '') only when [clearsBlanks] says the user emptied
  /// it. Visibility scopes are plain strings where '' means unchanged.
  /// `user_id` is left unset: the interceptor resolves [userPublicId] and
  /// stamps it.
  UpdateUserProfileRequest toRequest(String userPublicId) {
    String scope(ProfileField field) => visibility[field]?.wire ?? '';
    final request = UpdateUserProfileRequest(
      userPublicId: userPublicId,
      firstNameVisibility: scope(ProfileField.firstName),
      lastNameVisibility: scope(ProfileField.lastName),
      bioVisibility: scope(ProfileField.bio),
      birthDateVisibility: scope(ProfileField.birthDate),
      locationVisibility: scope(ProfileField.location),
      phoneVisibility: scope(ProfileField.phone),
      preferencesVisibility: scope(ProfileField.preferences),
    );
    void put(String? value, void Function(String) set) {
      if (value != null || clearsBlanks) {
        set(value ?? '');
      }
    }

    put(firstName, (v) => request.firstName = v);
    put(lastName, (v) => request.lastName = v);
    put(birthDate == null ? null : _isoDate(birthDate!), (v) => request.birthDate = v);
    put(city, (v) => request.city = v);
    put(countryCode, (v) => request.countryCode = v);
    put(phoneNumber, (v) => request.phoneNumber = v);
    put(bio, (v) => request.bio = v);
    return request;
  }
}

/// YYYY-MM-DD, as the server parses birth_date. Not DateTime.toIso8601String:
/// that adds a time part.
String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
