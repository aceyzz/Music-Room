import 'package:app/core/commands/categories/grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/music_provider_service.pbgrpc.dart';

// One command per MusicProviderService RPC the app calls. The commented-out
// grpc_commands.dart next to this file targets the old MusicService.

class GetSongCommand
    extends RpcCallCommand<GetSongRequest, GetSongResponse, MusicProviderServiceClient> {
  const GetSongCommand(super.request);

  @override
  Future<GetSongResponse> execute(
    MusicProviderServiceClient client,
    GetSongRequest request,
  ) =>
      client.getSong(request);
}

class SearchSongsCommand
    extends RpcCallCommand<SearchSongsRequest, SearchSongsResponse, MusicProviderServiceClient> {
  const SearchSongsCommand(super.request);

  @override
  Future<SearchSongsResponse> execute(
    MusicProviderServiceClient client,
    SearchSongsRequest request,
  ) =>
      client.searchSongs(request);
}
