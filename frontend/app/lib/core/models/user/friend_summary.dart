import 'package:flutter/foundation.dart';

/// A friend as a list shows them.
@immutable
class FriendSummary {
  final String publicId;
  final String displayName;
  final String? avatarUrl;

  const FriendSummary({required this.publicId, required this.displayName, this.avatarUrl});

  @override
  bool operator ==(Object other) =>
      other is FriendSummary &&
      other.publicId == publicId &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(publicId, displayName, avatarUrl);
}
