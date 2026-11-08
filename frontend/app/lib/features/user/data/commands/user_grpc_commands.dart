import 'package:app/core/commands/categories/grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/user_service.pbgrpc.dart';

// One command per UserService RPC the app calls. Add the rest as pages need them.

class UpdateUserProfileCommand extends RpcCallCommand<UpdateUserProfileRequest,
    UpdateUserProfileResponse, UserServiceClient> {
  const UpdateUserProfileCommand(super.request);

  @override
  Future<UpdateUserProfileResponse> execute(
    UserServiceClient client,
    UpdateUserProfileRequest request,
  ) =>
      client.updateUserProfile(request);
}

class SetMusicPreferencesCommand extends RpcCallCommand<SetMusicPreferencesRequest,
    SetMusicPreferencesResponse, UserServiceClient> {
  const SetMusicPreferencesCommand(super.request);

  @override
  Future<SetMusicPreferencesResponse> execute(
          UserServiceClient client, SetMusicPreferencesRequest request) =>
      client.setMusicPreferences(request);
}

class GetUserCommand
    extends RpcCallCommand<GetUserRequest, GetUserResponse, UserServiceClient> {
  const GetUserCommand(super.request);

  @override
  Future<GetUserResponse> execute(UserServiceClient client, GetUserRequest request) =>
      client.getUser(request);
}

class UploadAvatarCommand
    extends RpcCallCommand<UploadAvatarRequest, UploadAvatarResponse, UserServiceClient> {
  const UploadAvatarCommand(super.request);

  @override
  Future<UploadAvatarResponse> execute(UserServiceClient client, UploadAvatarRequest request) =>
      client.uploadAvatar(request);
}

class DeleteAvatarCommand
    extends RpcCallCommand<DeleteAvatarRequest, DeleteAvatarResponse, UserServiceClient> {
  const DeleteAvatarCommand(super.request);

  @override
  Future<DeleteAvatarResponse> execute(UserServiceClient client, DeleteAvatarRequest request) =>
      client.deleteAvatar(request);
}

class GetFriendsCommand
    extends RpcCallCommand<GetFriendsRequest, GetFriendsResponse, UserServiceClient> {
  const GetFriendsCommand(super.request);

  @override
  Future<GetFriendsResponse> execute(UserServiceClient client, GetFriendsRequest request) =>
      client.getFriends(request);
}

class GetUserRelationshipCommand extends RpcCallCommand<GetUserRelationshipRequest,
    GetUserRelationshipResponse, UserServiceClient> {
  const GetUserRelationshipCommand(super.request);

  @override
  Future<GetUserRelationshipResponse> execute(
          UserServiceClient client, GetUserRelationshipRequest request) =>
      client.getUserRelationship(request);
}

class SendFriendRequestCommand
    extends RpcCallCommand<SendFriendRequestRequest, SendFriendRequestResponse, UserServiceClient> {
  const SendFriendRequestCommand(super.request);

  @override
  Future<SendFriendRequestResponse> execute(
          UserServiceClient client, SendFriendRequestRequest request) =>
      client.sendFriendRequest(request);
}

class AcceptFriendRequestCommand extends RpcCallCommand<AcceptFriendRequestRequest,
    AcceptFriendRequestResponse, UserServiceClient> {
  const AcceptFriendRequestCommand(super.request);

  @override
  Future<AcceptFriendRequestResponse> execute(
          UserServiceClient client, AcceptFriendRequestRequest request) =>
      client.acceptFriendRequest(request);
}

class DeclineFriendRequestCommand extends RpcCallCommand<DeclineFriendRequestRequest,
    DeclineFriendRequestResponse, UserServiceClient> {
  const DeclineFriendRequestCommand(super.request);

  @override
  Future<DeclineFriendRequestResponse> execute(
          UserServiceClient client, DeclineFriendRequestRequest request) =>
      client.declineFriendRequest(request);
}

class RemoveFriendCommand
    extends RpcCallCommand<RemoveFriendRequest, RemoveFriendResponse, UserServiceClient> {
  const RemoveFriendCommand(super.request);

  @override
  Future<RemoveFriendResponse> execute(UserServiceClient client, RemoveFriendRequest request) =>
      client.removeFriend(request);
}

class BlockUserCommand
    extends RpcCallCommand<BlockUserRequest, BlockUserResponse, UserServiceClient> {
  const BlockUserCommand(super.request);

  @override
  Future<BlockUserResponse> execute(UserServiceClient client, BlockUserRequest request) =>
      client.blockUser(request);
}

class UnblockUserCommand
    extends RpcCallCommand<UnblockUserRequest, UnblockUserResponse, UserServiceClient> {
  const UnblockUserCommand(super.request);

  @override
  Future<UnblockUserResponse> execute(UserServiceClient client, UnblockUserRequest request) =>
      client.unblockUser(request);
}

class SearchUsersCommand
    extends RpcCallCommand<SearchUsersRequest, SearchUsersResponse, UserServiceClient> {
  const SearchUsersCommand(super.request);

  @override
  Future<SearchUsersResponse> execute(UserServiceClient client, SearchUsersRequest request) =>
      client.searchUsers(request);
}

class ListFriendRequestsCommand extends RpcCallCommand<ListFriendRequestsRequest,
    ListFriendRequestsResponse, UserServiceClient> {
  const ListFriendRequestsCommand(super.request);

  @override
  Future<ListFriendRequestsResponse> execute(
          UserServiceClient client, ListFriendRequestsRequest request) =>
      client.listFriendRequests(request);
}

class ListBlockedUsersCommand
    extends RpcCallCommand<ListBlockedUsersRequest, ListBlockedUsersResponse, UserServiceClient> {
  const ListBlockedUsersCommand(super.request);

  @override
  Future<ListBlockedUsersResponse> execute(
          UserServiceClient client, ListBlockedUsersRequest request) =>
      client.listBlockedUsers(request);
}
