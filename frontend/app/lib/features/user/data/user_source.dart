import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';

import 'package:app/core/mapping/user.mapping.dart';
import 'package:app/core/models/user/friend_request.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/relationship.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/models/user/user_summary.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/sources/grpc_source.dart';
import 'package:app/features/user/data/commands/user_grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/user_service.pbgrpc.dart';

/// What the app needs from UserService. An interface so stores can be tested
/// without a channel.
///
/// Every method names the signed-in user by [userPublicId]; the server checks
/// it against the session, so it cannot be used to act on someone else.
abstract interface class UserApi {
  /// The profile as its owner sees it: every field, nothing redacted.
  Future<UserProfile> getProfile(String userPublicId);

  /// Writes the non-null fields of [profile] and returns the saved profile.
  Future<UserProfile> updateProfile(String userPublicId, ProfileUpdate profile);

  /// Replaces the whole set of music preferences (empty clears it) and
  /// returns what was stored.
  Future<List<MusicPreference>> setMusicPreferences(
    String userPublicId,
    List<MusicPreference> preferences,
  );

  /// Replaces the avatar. [contentType] is image/png, image/jpeg or
  /// image/webp: the server rejects anything else.
  Future<UserProfile> uploadAvatar(String userPublicId, Uint8List image, String contentType);

  /// Removes the avatar; succeeds when there was none.
  Future<UserProfile> deleteAvatar(String userPublicId);

  /// Everyone [userPublicId] is friends with, by display name.
  Future<List<FriendSummary>> getFriends(String userPublicId);
}

/// What a profile page needs from UserService: someone else's profile, where
/// the viewer stands with them, and the friend and block actions. Separate
/// from [UserApi] (the viewer's own account) so each page's store, and its
/// test fake, only see their half.
///
/// [viewerPublicId] is the signed-in user; the server checks it against the
/// session.
abstract interface class SocialApi {
  /// [targetPublicId]'s profile, with what the viewer may not see left out.
  /// Throws a not-found error when either has blocked the other.
  Future<UserProfile> viewProfile(String viewerPublicId, String targetPublicId);

  /// Answers even when a block exists, unlike [viewProfile].
  Future<Relationship> relationship(String viewerPublicId, String targetPublicId);

  Future<void> sendFriendRequest(String viewerPublicId, String targetPublicId);

  /// [requestId] is [Relationship.incomingRequestId].
  Future<void> acceptFriendRequest(String viewerPublicId, int requestId);
  Future<void> declineFriendRequest(String viewerPublicId, int requestId);

  /// Also takes back any music control the two gave each other.
  Future<void> removeFriend(String viewerPublicId, String targetPublicId);

  /// Ends the friendship, cancels pending requests and takes back music
  /// control, then hides each from the other.
  Future<void> block(String viewerPublicId, String targetPublicId);

  /// Does not restore the friendship.
  Future<void> unblock(String viewerPublicId, String targetPublicId);

  /// The viewer's friends, by name. The same call as [UserApi.getFriends],
  /// here so the friends page needs only this interface.
  Future<List<FriendSummary>> friends(String viewerPublicId);

  /// People whose name contains [query], those starting with it first; never
  /// the viewer, nor anyone with a block either way. At most [limit] (the
  /// server caps it at 50), no paging. A blank [query] returns nobody.
  Future<List<UserSummary>> searchUsers(String viewerPublicId, String query, {int limit = 20});

  /// Pending requests the viewer received ([incoming]) or sent, newest first.
  Future<List<FriendRequest>> friendRequests(String viewerPublicId, {required bool incoming});

  /// The accounts the viewer blocked, most recent first.
  Future<List<UserSummary>> blockedUsers(String viewerPublicId);
}

/// Native gRPC implementation of [UserApi] and [SocialApi]. Built with the network's
/// interceptors, so the session token is attached.
class UserGrpcSource extends GrpcSource<void, UserServiceClient> implements UserApi, SocialApi {
  @override
  final UserServiceClient client;

  UserGrpcSource(super.channel, super.interceptors)
      : client = UserServiceClient(channel, interceptors: interceptors);

  static UserGrpcSource from(AppNetwork appNetwork) =>
      GrpcSource.create(appNetwork, UserGrpcSource.new);

  @override
  Future<UserProfile> getProfile(String userPublicId) async {
    // Viewer and target are the same account, which is what makes GetUser
    // skip the per-field redaction (internal/user/service.go, relationFor).
    final response = await GetUserCommand(
      GetUserRequest(publicId: userPublicId, viewerPublicId: userPublicId),
    )(client);
    return response.user.toDomain();
  }

  @override
  Future<UserProfile> updateProfile(String userPublicId, ProfileUpdate profile) async {
    final response = await UpdateUserProfileCommand(profile.toRequest(userPublicId))(client);
    return response.user.toDomain();
  }

  @override
  Future<List<MusicPreference>> setMusicPreferences(
    String userPublicId,
    List<MusicPreference> preferences,
  ) async {
    final response = await SetMusicPreferencesCommand(SetMusicPreferencesRequest(
      userPublicId: userPublicId,
      preferences: [for (final p in preferences) p.toDto()],
    ))(client);
    return [for (final p in response.preferences) p.toDomain()];
  }

  @override
  Future<UserProfile> uploadAvatar(
    String userPublicId,
    Uint8List image,
    String contentType,
  ) async {
    final response = await UploadAvatarCommand(UploadAvatarRequest(
      userPublicId: userPublicId,
      imageData: image,
      contentType: contentType,
    ))(client);
    return response.user.toDomain();
  }

  @override
  Future<UserProfile> deleteAvatar(String userPublicId) async {
    final response =
        await DeleteAvatarCommand(DeleteAvatarRequest(userPublicId: userPublicId))(client);
    return response.user.toDomain();
  }

  @override
  Future<List<FriendSummary>> getFriends(String userPublicId) async {
    final response =
        await GetFriendsCommand(GetFriendsRequest(userPublicId: userPublicId))(client);
    return [for (final friend in response.friends) friend.toSummary()];
  }

  @override
  Future<UserProfile> viewProfile(String viewerPublicId, String targetPublicId) async {
    final response = await GetUserCommand(
      GetUserRequest(publicId: targetPublicId, viewerPublicId: viewerPublicId),
    )(client);
    return response.user.toDomain();
  }

  @override
  Future<Relationship> relationship(String viewerPublicId, String targetPublicId) async {
    final response = await GetUserRelationshipCommand(GetUserRelationshipRequest(
      viewerPublicId: viewerPublicId,
      targetPublicId: targetPublicId,
    ))(client);
    return response.toRelationship();
  }

  @override
  Future<void> sendFriendRequest(String viewerPublicId, String targetPublicId) =>
      SendFriendRequestCommand(SendFriendRequestRequest(
        requesterPublicId: viewerPublicId,
        addresseePublicId: targetPublicId,
      ))(client);

  @override
  Future<void> acceptFriendRequest(String viewerPublicId, int requestId) =>
      AcceptFriendRequestCommand(AcceptFriendRequestRequest(
        addresseePublicId: viewerPublicId,
        requestId: Int64(requestId),
      ))(client);

  @override
  Future<void> declineFriendRequest(String viewerPublicId, int requestId) =>
      DeclineFriendRequestCommand(DeclineFriendRequestRequest(
        addresseePublicId: viewerPublicId,
        requestId: Int64(requestId),
      ))(client);

  @override
  Future<void> removeFriend(String viewerPublicId, String targetPublicId) =>
      RemoveFriendCommand(RemoveFriendRequest(
        userPublicId: viewerPublicId,
        friendPublicId: targetPublicId,
      ))(client);

  @override
  Future<void> block(String viewerPublicId, String targetPublicId) =>
      BlockUserCommand(BlockUserRequest(
        blockerPublicId: viewerPublicId,
        blockedPublicId: targetPublicId,
      ))(client);

  @override
  Future<void> unblock(String viewerPublicId, String targetPublicId) =>
      UnblockUserCommand(UnblockUserRequest(
        blockerPublicId: viewerPublicId,
        blockedPublicId: targetPublicId,
      ))(client);

  @override
  Future<List<FriendSummary>> friends(String viewerPublicId) => getFriends(viewerPublicId);

  @override
  Future<List<UserSummary>> searchUsers(
    String viewerPublicId,
    String query, {
    int limit = 20,
  }) async {
    final response = await SearchUsersCommand(SearchUsersRequest(
      viewerPublicId: viewerPublicId,
      query: query,
      limit: limit,
    ))(client);
    return [for (final user in response.users) user.toSummary()];
  }

  @override
  Future<List<FriendRequest>> friendRequests(
    String viewerPublicId, {
    required bool incoming,
  }) async {
    final response = await ListFriendRequestsCommand(ListFriendRequestsRequest(
      userPublicId: viewerPublicId,
      direction: incoming ? 'incoming' : 'outgoing',
    ))(client);
    return [
      for (final request in response.requests) request.toFriendRequest(incoming: incoming),
    ];
  }

  @override
  Future<List<UserSummary>> blockedUsers(String viewerPublicId) async {
    final response = await ListBlockedUsersCommand(
      ListBlockedUsersRequest(blockerPublicId: viewerPublicId),
    )(client);
    return [for (final user in response.blockedUsers) user.toSummary()];
  }
}
