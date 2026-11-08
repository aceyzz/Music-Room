// import 'package:app/core/models/song/song_detail.dart';
// import 'package:app/core/models/song/song_detail_event.dart';
// import 'package:app/core/network/app_network.dart';
// import 'package:app/core/sources/grpc_source.dart';
// import 'package:app/gen/api.dart';

// // Conditionally imported alongside `song_detail_web_sources.dart`.
// //
// // Contains native gRPC data sources executed exclusively when running on non-web
// // platforms (e.g., iOS, Android, macOS).

// // =============================================================================
// // FETCH SOURCE
// // =============================================================================

// /// Native gRPC data source for executing single request-response song detail fetch RPCs.
// class SongDetailFetchSource extends GrpcSource<SongDetail, MusicServiceClient> {
//   @override
//   final MusicServiceClient client;

//   /// Creates a [SongDetailFetchSource] using the provided gRPC [channel].
//   SongDetailFetchSource(super.channel) : client = MusicServiceClient(channel);

//   /// Instantiates a [SongDetailFetchSource] bound to the gRPC channel managed by [AppNetwork].
//   static SongDetailFetchSource create(AppNetwork appNetwork) =>
//       SongDetailFetchSource(appNetwork.grpcService.channel);
// }

// // =============================================================================
// // WATCH SOURCE
// // =============================================================================

// /// Native gRPC data source for receiving server-streaming real-time song detail updates.
// class SongDetailWatchSource
//     extends GrpcSource<SongDetailEvent, MusicServiceClient> {
//   @override
//   final MusicServiceClient client;

//   /// Creates a [SongDetailWatchSource] using the provided gRPC [channel].
//   SongDetailWatchSource(super.channel) : client = MusicServiceClient(channel);

//   /// Instantiates a [SongDetailWatchSource] bound to the gRPC channel managed by [AppNetwork].
//   static SongDetailWatchSource create(AppNetwork appNetwork) =>
//       SongDetailWatchSource(appNetwork.grpcService.channel);
// }

// // =============================================================================
// // SYNCHRONIZE SOURCE
// // =============================================================================

// /// Native gRPC data source for bidirectional streaming song detail state synchronization.
// class SongDetailSyncSource
//     extends GrpcSource<SongDetailEvent, MusicServiceClient> {
//   @override
//   final MusicServiceClient client;

//   /// Creates a [SongDetailSyncSource] using the provided gRPC [channel].
//   SongDetailSyncSource(super.channel) : client = MusicServiceClient(channel);

//   /// Instantiates a [SongDetailSyncSource] bound to the gRPC channel managed by [AppNetwork].
//   static SongDetailSyncSource create(AppNetwork appNetwork) =>
//       SongDetailSyncSource(appNetwork.grpcService.channel);
// }