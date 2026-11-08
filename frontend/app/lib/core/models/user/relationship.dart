import 'package:flutter/foundation.dart';

/// Where the viewer stands with another user, as far as friendship goes
/// (GetUserRelationship).
enum FriendStatus {
  /// The viewer's own profile.
  self,
  none,
  friends,

  /// The viewer asked; the other user has not answered yet.
  requestSent,

  /// The other user asked the viewer.
  requestReceived,
}

/// What a profile page needs to pick its buttons.
///
/// A block by the OTHER user is never reported: the server answers [FriendStatus.none]
/// and refuses the profile, which looks the same as a deleted account, on purpose.
@immutable
class Relationship {
  final FriendStatus status;

  /// The request to accept or decline, set for [FriendStatus.requestReceived].
  final int? incomingRequestId;

  /// The viewer blocked this user.
  final bool blockedByMe;

  /// The user's name when [blockedByMe]: their profile is refused then, so it
  /// comes from here instead.
  final String? displayName;

  const Relationship({
    required this.status,
    this.incomingRequestId,
    this.blockedByMe = false,
    this.displayName,
  });

  @override
  bool operator ==(Object other) =>
      other is Relationship &&
      other.status == status &&
      other.incomingRequestId == incomingRequestId &&
      other.blockedByMe == blockedByMe &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(status, incomingRequestId, blockedByMe, displayName);
}
