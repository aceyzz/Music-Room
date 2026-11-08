import 'package:flutter/foundation.dart';


/// Someone invited to an event, or its host (ListEventMembers).
@immutable
class EventMember {
  final String displayName;

  /// What opens their profile (`/users/:id`). Null only if the server sent
  /// none.
  final String? publicId;

  /// Absolute URL of their picture, or null if they have none.
  final String? avatarUrl;

  /// owner | admin | editor | viewer, as the server sends it. The host is
  /// the owner; an invited user is a viewer.
  final String role;

  final DateTime? joinedAt;

  const EventMember({
    required this.displayName,
    required this.role,
    this.publicId,
    this.avatarUrl,
    this.joinedAt,
  });

  bool get isHost => role == 'owner';

  @override
  bool operator ==(Object other) =>
      other is EventMember &&
      other.displayName == displayName &&
      other.publicId == publicId &&
      other.avatarUrl == avatarUrl &&
      other.role == role &&
      other.joinedAt == joinedAt;

  @override
  int get hashCode => Object.hash(displayName, publicId, avatarUrl, role, joinedAt);
}

