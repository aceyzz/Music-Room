import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/friend_request.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/relationship.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/models/user/user_summary.dart';
import 'package:app/features/user/data/user_source.dart';

/// [SocialApi] as a small state machine that behaves like the server: each
/// action moves [current] the way the real one would, and a block refuses the
/// profile.
///
/// The friends page's lists live here too: accepting moves a request into
/// [friendList], declining drops it, unblocking empties the slot in
/// [blockedList]. [searchUsers] matches [directory] by name.
class FakeSocialApi implements SocialApi {
  UserProfile profile = person();
  Relationship current = const Relationship(status: FriendStatus.none);

  /// Thrown by [viewProfile] when no block explains it (deleted account, or
  /// blocked by them).
  AppError? profileFailure;

  /// Thrown by the next action instead of doing it.
  AppError? actionFailure;

  /// The actions called, in order.
  final calls = <String>[];

  List<FriendSummary> friendList = [];
  List<FriendRequest> incomingList = [];
  List<FriendRequest> outgoingList = [];
  List<UserSummary> blockedList = [];

  /// Everyone [searchUsers] can find.
  List<UserSummary> directory = [];

  /// The queries [searchUsers] was called with, in order.
  final searches = <String>[];

  /// Thrown by the next list or search read instead of answering.
  AppError? listFailure;

  @override
  Future<UserProfile> viewProfile(String viewerPublicId, String targetPublicId) async {
    if (current.blockedByMe) {
      throw const NotFoundError('user not found');
    }
    if (profileFailure case final failure?) {
      throw failure;
    }
    return profile;
  }

  @override
  Future<Relationship> relationship(String viewerPublicId, String targetPublicId) async => current;

  Future<void> _act(String name, Relationship next) async {
    calls.add(name);
    if (actionFailure case final failure?) {
      actionFailure = null;
      throw failure;
    }
    current = next;
  }

  @override
  Future<void> sendFriendRequest(String viewerPublicId, String targetPublicId) =>
      _act('send', const Relationship(status: FriendStatus.requestSent));

  @override
  Future<void> acceptFriendRequest(String viewerPublicId, int requestId) async {
    await _act('accept $requestId', const Relationship(status: FriendStatus.friends));
    // The profile page's tests set [current] only, with no list behind it.
    for (final request in incomingList.where((r) => r.id == requestId).toList()) {
      incomingList = [...incomingList]..remove(request);
      friendList = [
        ...friendList,
        FriendSummary(publicId: request.user.publicId, displayName: request.user.displayName),
      ];
    }
  }

  @override
  Future<void> declineFriendRequest(String viewerPublicId, int requestId) async {
    await _act('decline $requestId', const Relationship(status: FriendStatus.none));
    incomingList = [...incomingList]..removeWhere((r) => r.id == requestId);
  }

  @override
  Future<void> removeFriend(String viewerPublicId, String targetPublicId) =>
      _act('remove', const Relationship(status: FriendStatus.none));

  @override
  Future<void> block(String viewerPublicId, String targetPublicId) => _act(
        'block',
        Relationship(
          status: FriendStatus.none,
          blockedByMe: true,
          displayName: profile.displayName,
        ),
      );

  @override
  Future<void> unblock(String viewerPublicId, String targetPublicId) async {
    await _act('unblock', const Relationship(status: FriendStatus.none));
    blockedList = [...blockedList]..removeWhere((u) => u.publicId == targetPublicId);
  }

  Future<T> _read<T>(T value) async {
    if (listFailure case final failure?) {
      listFailure = null;
      throw failure;
    }
    return value;
  }

  @override
  Future<List<FriendSummary>> friends(String viewerPublicId) => _read(friendList);

  @override
  Future<List<FriendRequest>> friendRequests(String viewerPublicId, {required bool incoming}) =>
      _read(incoming ? incomingList : outgoingList);

  @override
  Future<List<UserSummary>> blockedUsers(String viewerPublicId) => _read(blockedList);

  @override
  Future<List<UserSummary>> searchUsers(
    String viewerPublicId,
    String query, {
    int limit = 20,
  }) {
    searches.add(query);
    final needle = query.toLowerCase();
    return _read([
      for (final user in directory)
        if (user.displayName.toLowerCase().contains(needle)) user,
    ].take(limit).toList());
  }
}

UserSummary someone(String name) => UserSummary(publicId: 'id-$name', displayName: name);

UserProfile person({
  String publicId = 'u-2',
  String displayName = 'Trinity',
  String? bio,
  String? city,
  Map<ProfileField, ProfileVisibility> visibility = const {},
}) =>
    UserProfile(
      publicId: publicId,
      displayName: displayName,
      bio: bio,
      city: city,
      visibility: {
        for (final field in ProfileField.values)
          field: visibility[field] ?? field.defaultVisibility,
      },
    );
