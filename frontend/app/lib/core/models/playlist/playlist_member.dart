import 'package:flutter/foundation.dart';

/// What a member may do with a playlist (`playlist_members.role`), from most
/// to least. The rights below are the server's (authz/model.fga); the app
/// only uses them to decide which controls to show. The page shows two
/// kinds, as the subject does: the owner, and the people invited -- an
/// invitation makes an editor, and the app sets no other role.
enum PlaylistRole {
  owner('owner'),
  admin('admin'),
  editor('editor'),
  viewer('viewer');

  final String wire;

  const PlaylistRole(this.wire);

  /// Unknown values read as [viewer]: the fewest controls.
  static PlaylistRole fromWire(String value) =>
      values.firstWhere((r) => r.wire == value, orElse: () => viewer);

  /// Rename, visibility, licence. The owner only: the app shows owner and
  /// invited, nothing in between, so an admin (which the app never sets) is
  /// treated as invited.
  bool get canManage => this == owner;

  bool get canInvite => this != viewer;

  bool get canDelete => this == owner;
}

/// Someone in a playlist's member list (ListPlaylistMembers).
@immutable
class PlaylistMember {
  final String publicId;
  final String displayName;

  /// Absolute URL of their picture, or null if they have none.
  final String? avatarUrl;
  final PlaylistRole role;

  const PlaylistMember({
    required this.publicId,
    required this.displayName,
    required this.role,
    this.avatarUrl,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaylistMember &&
      other.publicId == publicId &&
      other.displayName == displayName &&
      other.avatarUrl == avatarUrl &&
      other.role == role;

  @override
  int get hashCode => Object.hash(publicId, displayName, avatarUrl, role);
}
