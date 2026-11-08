import 'package:flutter/foundation.dart';

/// Someone as a list of people shows them: a search result, a request's
/// sender, a blocked account. Enough to show a row and open their profile.
@immutable
class UserSummary {
  final String publicId;
  final String displayName;
  final String? avatarUrl;

  const UserSummary({required this.publicId, required this.displayName, this.avatarUrl});

  @override
  bool operator ==(Object other) =>
      other is UserSummary &&
      other.publicId == publicId &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(publicId, displayName, avatarUrl);
}
