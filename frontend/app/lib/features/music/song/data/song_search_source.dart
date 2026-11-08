import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/sources/grpc_source.dart';
import 'package:app/features/music/song/data/commands/catalog_grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/music_provider_service.pbgrpc.dart';

/// A search of Deezer's whole catalogue, through the backend. An interface so
/// stores can be tested without a channel.
abstract interface class SongSearchApi {
  /// The songs matching [query], Deezer's first page (25 at most), in
  /// Deezer's order. Nothing is stored by searching: a song reaches the
  /// backend's cache when it is suggested or added somewhere.
  Future<List<EventTrack>> searchSongs(String query);

  /// One song as Deezer describes it now, by its Deezer id: what gives a
  /// fresh preview link, the stored ones being signed for 15 minutes.
  Future<EventTrack> getSong(int deezerId);
}

/// Native gRPC implementation of [SongSearchApi]. Built with the network's
/// interceptors, so the session token is attached.
class MusicProviderGrpcSource extends GrpcSource<void, MusicProviderServiceClient>
    implements SongSearchApi {
  @override
  final MusicProviderServiceClient client;

  MusicProviderGrpcSource(super.channel, super.interceptors)
      : client = MusicProviderServiceClient(channel, interceptors: interceptors);

  static MusicProviderGrpcSource from(AppNetwork appNetwork) =>
      GrpcSource.create(appNetwork, MusicProviderGrpcSource.new);

  @override
  Future<List<EventTrack>> searchSongs(String query) async {
    final response = await SearchSongsCommand(SearchSongsRequest(query: query))(client);
    return [for (final song in response.songs) song.toTrack()];
  }

  @override
  Future<EventTrack> getSong(int deezerId) async {
    final response = await GetSongCommand(GetSongRequest(id: '$deezerId'))(client);
    return response.song.toTrack();
  }
}
