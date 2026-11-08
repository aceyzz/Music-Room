import 'package:app/core/commands/categories/grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/playlist_service.pbgrpc.dart';

// One command per PlaylistService RPC the app calls. Add the rest as pages need them.

class CreatePlaylistCommand
    extends RpcCallCommand<CreatePlaylistRequest, CreatePlaylistResponse, PlaylistServiceClient> {
  const CreatePlaylistCommand(super.request);

  @override
  Future<CreatePlaylistResponse> execute(
    PlaylistServiceClient client,
    CreatePlaylistRequest request,
  ) =>
      client.createPlaylist(request);
}

class WatchPlaylistCommand
    extends RpcWatchCommand<WatchPlaylistRequest, WatchPlaylistResponse, PlaylistServiceClient> {
  const WatchPlaylistCommand(super.request);

  @override
  Stream<WatchPlaylistResponse> execute(
    PlaylistServiceClient client,
    WatchPlaylistRequest request,
  ) =>
      client.watchPlaylist(request);
}

class ListLibraryPlaylistsCommand extends RpcCallCommand<ListLibraryPlaylistsRequest,
    ListLibraryPlaylistsResponse, PlaylistServiceClient> {
  const ListLibraryPlaylistsCommand(super.request);

  @override
  Future<ListLibraryPlaylistsResponse> execute(
    PlaylistServiceClient client,
    ListLibraryPlaylistsRequest request,
  ) =>
      client.listLibraryPlaylists(request);
}

class SearchPublicPlaylistsCommand extends RpcCallCommand<SearchPublicPlaylistsRequest,
    SearchPublicPlaylistsResponse, PlaylistServiceClient> {
  const SearchPublicPlaylistsCommand(super.request);

  @override
  Future<SearchPublicPlaylistsResponse> execute(
    PlaylistServiceClient client,
    SearchPublicPlaylistsRequest request,
  ) =>
      client.searchPublicPlaylists(request);
}

class GetPlaylistCommand
    extends RpcCallCommand<GetPlaylistRequest, GetPlaylistResponse, PlaylistServiceClient> {
  const GetPlaylistCommand(super.request);

  @override
  Future<GetPlaylistResponse> execute(PlaylistServiceClient client, GetPlaylistRequest request) =>
      client.getPlaylist(request);
}

class AddSongToPlaylistCommand extends RpcCallCommand<AddSongToPlaylistRequest,
    AddSongToPlaylistResponse, PlaylistServiceClient> {
  const AddSongToPlaylistCommand(super.request);

  @override
  Future<AddSongToPlaylistResponse> execute(
    PlaylistServiceClient client,
    AddSongToPlaylistRequest request,
  ) =>
      client.addSongToPlaylist(request);
}

class RemoveSongFromPlaylistCommand extends RpcCallCommand<RemoveSongFromPlaylistRequest,
    RemoveSongFromPlaylistResponse, PlaylistServiceClient> {
  const RemoveSongFromPlaylistCommand(super.request);

  @override
  Future<RemoveSongFromPlaylistResponse> execute(
    PlaylistServiceClient client,
    RemoveSongFromPlaylistRequest request,
  ) =>
      client.removeSongFromPlaylist(request);
}

class MoveSongInPlaylistCommand extends RpcCallCommand<MoveSongInPlaylistRequest,
    MoveSongInPlaylistResponse, PlaylistServiceClient> {
  const MoveSongInPlaylistCommand(super.request);

  @override
  Future<MoveSongInPlaylistResponse> execute(
    PlaylistServiceClient client,
    MoveSongInPlaylistRequest request,
  ) =>
      client.moveSongInPlaylist(request);
}

class ListPlaylistMembersCommand extends RpcCallCommand<ListPlaylistMembersRequest,
    ListPlaylistMembersResponse, PlaylistServiceClient> {
  const ListPlaylistMembersCommand(super.request);

  @override
  Future<ListPlaylistMembersResponse> execute(
          PlaylistServiceClient client, ListPlaylistMembersRequest request) =>
      client.listPlaylistMembers(request);
}

class RenamePlaylistCommand
    extends RpcCallCommand<RenamePlaylistRequest, RenamePlaylistResponse, PlaylistServiceClient> {
  const RenamePlaylistCommand(super.request);

  @override
  Future<RenamePlaylistResponse> execute(
          PlaylistServiceClient client, RenamePlaylistRequest request) =>
      client.renamePlaylist(request);
}

class SetPlaylistVisibilityCommand extends RpcCallCommand<SetPlaylistVisibilityRequest,
    SetPlaylistVisibilityResponse, PlaylistServiceClient> {
  const SetPlaylistVisibilityCommand(super.request);

  @override
  Future<SetPlaylistVisibilityResponse> execute(
          PlaylistServiceClient client, SetPlaylistVisibilityRequest request) =>
      client.setPlaylistVisibility(request);
}

class SetPlaylistEditLicenseCommand extends RpcCallCommand<SetPlaylistEditLicenseRequest,
    SetPlaylistEditLicenseResponse, PlaylistServiceClient> {
  const SetPlaylistEditLicenseCommand(super.request);

  @override
  Future<SetPlaylistEditLicenseResponse> execute(
          PlaylistServiceClient client, SetPlaylistEditLicenseRequest request) =>
      client.setPlaylistEditLicense(request);
}

class InviteToPlaylistCommand extends RpcCallCommand<InviteToPlaylistRequest,
    InviteToPlaylistResponse, PlaylistServiceClient> {
  const InviteToPlaylistCommand(super.request);

  @override
  Future<InviteToPlaylistResponse> execute(
          PlaylistServiceClient client, InviteToPlaylistRequest request) =>
      client.inviteToPlaylist(request);
}

class DeletePlaylistCommand
    extends RpcCallCommand<DeletePlaylistRequest, DeletePlaylistResponse, PlaylistServiceClient> {
  const DeletePlaylistCommand(super.request);

  @override
  Future<DeletePlaylistResponse> execute(
          PlaylistServiceClient client, DeletePlaylistRequest request) =>
      client.deletePlaylist(request);
}
