import 'package:flutter/foundation.dart';

/// Who may see one profile field (`visibility_scope` in the DB, a string on
/// the wire). [wire] is the exact value UserService sends and accepts.
enum ProfileVisibility {
  public('public', 'Everyone'),
  friends('friends', 'Friends'),
  private('private', 'Only me');

  final String wire;
  final String label;

  const ProfileVisibility(this.wire, this.label);

  /// Null for '' and for anything this build does not know, so the caller
  /// picks the fallback instead of an unknown scope being silently widened.
  static ProfileVisibility? fromWire(String value) {
    for (final v in values) {
      if (v.wire == value) {
        return v;
      }
    }
    return null;
  }
}

/// The profile fields that carry their own visibility, one per
/// `user_profiles.*_visibility` column. [location] covers city and country
/// together, [preferences] the music preferences.
enum ProfileField {
  firstName('First name'),
  lastName('Last name'),
  bio('Bio'),
  birthDate('Birth date'),
  location('Location'),
  phone('Phone'),
  preferences('Music preferences');

  final String label;

  const ProfileField(this.label);

  /// The server's defaults for an account that never saved its profile
  /// (db/query/profiles.sql, UpsertUserProfile), used when a response leaves
  /// a scope empty.
  ProfileVisibility get defaultVisibility => switch (this) {
        ProfileField.bio || ProfileField.preferences => ProfileVisibility.public,
        ProfileField.birthDate || ProfileField.phone => ProfileVisibility.private,
        _ => ProfileVisibility.friends,
      };
}

/// One music genre a user likes. [genreId] is Deezer's genre id; [weight]
/// is 1 to 5, as the server requires.
@immutable
class MusicPreference {
  final int genreId;
  final String genreName;
  final int weight;

  const MusicPreference({required this.genreId, required this.genreName, this.weight = 3});

  @override
  bool operator ==(Object other) =>
      other is MusicPreference &&
      other.genreId == genreId &&
      other.genreName == genreName &&
      other.weight == weight;

  @override
  int get hashCode => Object.hash(genreId, genreName, weight);
}

/// The genres a user can pick from: Deezer's own ids and names
/// (api.deezer.com/genre), the same list the seeder uses
/// (backend/cmd/seed/music.go). Fixed in the app rather than fetched: Deezer's
/// list barely changes, and the server stores whatever id and name it is sent.
const musicGenres = [
  MusicPreference(genreId: 132, genreName: 'Pop'),
  MusicPreference(genreId: 116, genreName: 'Rap/Hip Hop'),
  MusicPreference(genreId: 152, genreName: 'Rock'),
  MusicPreference(genreId: 113, genreName: 'Dance'),
  MusicPreference(genreId: 165, genreName: 'R&B'),
  MusicPreference(genreId: 85, genreName: 'Alternative'),
  MusicPreference(genreId: 106, genreName: 'Electro'),
  MusicPreference(genreId: 466, genreName: 'Folk'),
  MusicPreference(genreId: 144, genreName: 'Reggae'),
  MusicPreference(genreId: 129, genreName: 'Jazz'),
  MusicPreference(genreId: 98, genreName: 'Classical'),
  MusicPreference(genreId: 173, genreName: 'Films/Games'),
  MusicPreference(genreId: 464, genreName: 'Metal'),
  MusicPreference(genreId: 169, genreName: 'Soul & Funk'),
  MusicPreference(genreId: 2, genreName: 'African Music'),
  MusicPreference(genreId: 197, genreName: 'Latin Music'),
];

/// A user's profile as the server returned it to the current viewer.
///
/// For someone else's profile, a field hidden from the viewer comes back
/// empty and is null here: "not filled in" and "not yours to see" look the
/// same, on purpose (UserService.GetUser).
@immutable
class UserProfile {
  final String publicId;
  final String displayName;

  /// Absolute URL of the square thumbnail, or null if there is no avatar.
  final String? avatarUrl;

  final String? firstName;
  final String? lastName;
  final String? bio;
  final DateTime? birthDate;
  final String? city;

  /// ISO 3166-1 alpha-2, upper case.
  final String? countryCode;
  final String? phoneNumber;

  /// Empty when none are set, or when they are hidden from the viewer.
  final List<MusicPreference> musicPreferences;

  /// Always holds every [ProfileField].
  final Map<ProfileField, ProfileVisibility> visibility;

  const UserProfile({
    required this.publicId,
    required this.displayName,
    required this.visibility,
    this.avatarUrl,
    this.firstName,
    this.lastName,
    this.bio,
    this.birthDate,
    this.city,
    this.countryCode,
    this.phoneNumber,
    this.musicPreferences = const [],
  });

  ProfileVisibility visibilityOf(ProfileField field) =>
      visibility[field] ?? field.defaultVisibility;

  /// This profile with [preferences] in place of its music preferences:
  /// SetMusicPreferences returns only the list, not the whole profile.
  UserProfile withMusicPreferences(List<MusicPreference> preferences) => UserProfile(
        publicId: publicId,
        displayName: displayName,
        visibility: visibility,
        avatarUrl: avatarUrl,
        firstName: firstName,
        lastName: lastName,
        bio: bio,
        birthDate: birthDate,
        city: city,
        countryCode: countryCode,
        phoneNumber: phoneNumber,
        musicPreferences: preferences,
      );

  @override
  bool operator ==(Object other) =>
      other is UserProfile &&
      other.publicId == publicId &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl &&
      other.firstName == firstName &&
      other.lastName == lastName &&
      other.bio == bio &&
      other.birthDate == birthDate &&
      other.city == city &&
      other.countryCode == countryCode &&
      other.phoneNumber == phoneNumber &&
      listEquals(other.musicPreferences, musicPreferences) &&
      mapEquals(other.visibility, visibility);

  @override
  int get hashCode => Object.hash(
        publicId,
        displayName,
        avatarUrl,
        firstName,
        lastName,
        bio,
        birthDate,
        city,
        countryCode,
        phoneNumber,
        Object.hashAll(musicPreferences),
        Object.hashAllUnordered(visibility.entries.map((e) => Object.hash(e.key, e.value))),
      );
}
