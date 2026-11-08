import 'package:flutter/foundation.dart';

import 'package:app/core/models/user/user_summary.dart';

/// A pending friend request, seen from the signed-in user's side.
@immutable
class FriendRequest {
  /// What Accept and Decline take.
  final int id;

  /// The other person: who sent it when [incoming], who it went to otherwise.
  final UserSummary user;

  final bool incoming;

  const FriendRequest({required this.id, required this.user, required this.incoming});

  @override
  bool operator ==(Object other) =>
      other is FriendRequest && other.id == id && other.user == user && other.incoming == incoming;

  @override
  int get hashCode => Object.hash(id, user, incoming);
}
