// import 'package:app/core/sources/grpc_source.dart';
// import 'package:app/gen/api.dart';
// import 'package:app/core/models/song/song_event.dart';
// import 'package:app/core/models/song/song.dart';
// import 'package:app/core/network/app_network.dart';

// // Conditionally imported alongside `song_web_sources.dart`.
// //
// // Contains native gRPC data sources executed exclusively when running on non-web
// // platforms (e.g., iOS, Android, macOS).

// // =============================================================================
// // FETCH SOURCE
// // =============================================================================

// /// Native gRPC data source for executing single request-response song fetch RPCs.
// class SongFetchSource extends GrpcSource<Song, MusicServiceClient> {
//   @override
//   final MusicServiceClient client;

//   /// Creates a [SongFetchSource] using the provided gRPC [channel].
//   SongFetchSource(super.channel) : client = MusicServiceClient(channel);

//   /// Instantiates a [SongFetchSource] bound to the gRPC channel managed by [AppNetwork].
//   static SongFetchSource create(AppNetwork appNetwork) =>
//       SongFetchSource(appNetwork.grpcService.channel);
// }

// // =============================================================================
// // WATCH SOURCE
// // =============================================================================

// /// Native gRPC data source for receiving server-streaming real-time song updates.
// class SongWatchSource extends GrpcSource<SongEvent, MusicServiceClient> {
//   @override
//   final MusicServiceClient client;

//   /// Creates a [SongWatchSource] using the provided gRPC [channel].
//   SongWatchSource(super.channel) : client = MusicServiceClient(channel);

//   /// Instantiates a [SongWatchSource] bound to the gRPC channel managed by [AppNetwork].
//   static SongWatchSource create(AppNetwork appNetwork) =>
//       SongWatchSource(appNetwork.grpcService.channel);
// }

// // =============================================================================
// // Synchronize SOURCE
// // =============================================================================

// /// Native gRPC data source for bidirectional streaming song state synchronization.
// class SongSyncSource extends GrpcSource<SongEvent, MusicServiceClient> {
//   @override
//   final MusicServiceClient client;

//   /// Creates a [SongSyncSource] using the provided gRPC [channel].
//   SongSyncSource(super.channel) : client = MusicServiceClient(channel);

//   /// Instantiates a [SongSyncSource] bound to the gRPC channel managed by [AppNetwork].
//   static SongSyncSource create(AppNetwork appNetwork) =>
//       SongSyncSource(appNetwork.grpcService.channel);
// }
