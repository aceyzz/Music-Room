import 'package:flutter/foundation.dart';

import 'package:app/core/models/user/user_profile.dart';

/// The optional profile fields a user can fill in (sign-up, the profile
/// page). What a null field means depends on [clearsBlanks]: not sent, so
/// "leave unchanged" on the server, or sent empty, so "clear it".
///
/// Sign-up leaves [visibility] empty: the server's defaults
/// (docs/data-model.md, the user_profiles table) are the right starting point
/// for a new account. The profile page sends every scope.
@immutable
class ProfileUpdate {
  final String? firstName;
  final String? lastName;
  final DateTime? birthDate;
  final String? city;

  /// ISO 3166-1 alpha-2, upper case.
  final String? countryCode;
  final String? phoneNumber;
  final String? bio;

  /// Only the scopes to change; a missing field keeps its current one.
  final Map<ProfileField, ProfileVisibility> visibility;

  /// True when this update is a whole form: a null field then means the user
  /// emptied it, and it is sent empty, which the server stores as cleared.
  /// The profile page sets it. Sign-up does not: a new account has nothing to
  /// clear, and sending only what was filled in keeps the request minimal.
  final bool clearsBlanks;

  const ProfileUpdate({
    this.firstName,
    this.lastName,
    this.birthDate,
    this.city,
    this.countryCode,
    this.phoneNumber,
    this.bio,
    this.visibility = const {},
    this.clearsBlanks = false,
  });

  /// Builds an update from raw form text: trims, and treats blank as null,
  /// which [clearBlanks] turns into "clear it" (see [clearsBlanks]).
  factory ProfileUpdate.fromForm({
    String firstName = '',
    String lastName = '',
    DateTime? birthDate,
    String city = '',
    String countryCode = '',
    String phoneNumber = '',
    String bio = '',
    Map<ProfileField, ProfileVisibility> visibility = const {},
    bool clearBlanks = false,
  }) {
    String? clean(String s) => s.trim().isEmpty ? null : s.trim();
    return ProfileUpdate(
      firstName: clean(firstName),
      lastName: clean(lastName),
      birthDate: birthDate,
      city: clean(city),
      countryCode: clean(countryCode)?.toUpperCase(),
      phoneNumber: clean(phoneNumber),
      bio: clean(bio),
      visibility: visibility,
      clearsBlanks: clearBlanks,
    );
  }

  /// Nothing would change on the server.
  bool get isEmpty =>
      !clearsBlanks &&
      firstName == null &&
      lastName == null &&
      birthDate == null &&
      city == null &&
      countryCode == null &&
      phoneNumber == null &&
      bio == null &&
      visibility.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is ProfileUpdate &&
      other.firstName == firstName &&
      other.lastName == lastName &&
      other.birthDate == birthDate &&
      other.city == city &&
      other.countryCode == countryCode &&
      other.phoneNumber == phoneNumber &&
      other.bio == bio &&
      mapEquals(other.visibility, visibility) &&
      other.clearsBlanks == clearsBlanks;

  @override
  int get hashCode => Object.hash(
        firstName,
        lastName,
        birthDate,
        city,
        countryCode,
        phoneNumber,
        bio,
        Object.hashAllUnordered(visibility.entries.map((e) => Object.hash(e.key, e.value))),
        clearsBlanks,
      );
}
