// import 'package:app/core/models/song/song_detail.dart';
// import 'package:app/core/models/song/song_detail_event.dart';
// import 'package:app/core/network/app_network.dart';
// import 'package:app/core/sources/source.dart';
// import 'package:app/gen/api.dart';
// import 'package:app/core/mapping/mappers.dart';

// import 'commands/grpc_commands.dart'
//     if (dart.library.js_interop) './commands/web_commands.dart';
// import 'sources/song_detail_grpc_source.dart'
//     if (dart.library.js_interop) './sources/song_detail_web_source.dart';

// /// Entry point for managing song detail data operations.
// ///
// /// Coordinates fetch, watch, and synchronization network sources across native
// /// (gRPC) and web platforms.
// class SongDetailSource extends DomainSource<SongDetail, SongDetailEvent,
//     SongDetailEvent, SyncSongDetailRequest> {
//   final SongDetailFetchSource _fetchSource;
//   final SongDetailWatchSource _watchSource;
//   final SongDetailSyncSource _syncSource;

//   /// Private constructor to enforce initialization via [SongDetailSource.from].
//   SongDetailSource._(
//     this._fetchSource,
//     this._watchSource,
//     this._syncSource,
//   );

//   // =============================================================================
//   // FACTORY INVOCATIONS
//   // =============================================================================

//   /// Instantiates a platform-aware [SongDetailSource] bound to the given [appNetwork].
//   static SongDetailSource from(AppNetwork appNetwork) {
//     final fetchSource = SongDetailFetchSource.create(appNetwork);
//     final watchSource = SongDetailWatchSource.create(appNetwork);
//     final syncSource = SongDetailSyncSource.create(appNetwork);

//     return SongDetailSource._(fetchSource, watchSource, syncSource);
//   }

//   // =============================================================================
//   // DOMAIN SOURCE IMPLEMENTATION
//   // =============================================================================

//   @override
//   Future<List<SongDetail>> fetch() {
//     // Note: If you need to pass a specific song ID, update GetSongDetailRequest
//     final command = GetSongDetailCommand(GetSongDetailRequest());
//     return _fetchSource.execute(command, (res) => res.toDomainList());
//   }

//   @override
//   Stream<List<SongDetailEvent>> watch() {
//     final command = WatchSongDetailCommand(WatchSongDetailRequest());
//     return _watchSource.executeStream(command, (res) => res.toDomainList());
//   }

//   @override
//   Stream<List<SongDetailEvent>> synchronize(
//       Stream<SyncSongDetailRequest> clientActions) {
//     final command = SyncSongDetailCommand(clientActions);
//     return _syncSource.executeBiStream(
//       command,
//       clientActions,
//       (res) => res.toDomainList(),
//     );
//   }

//   // =============================================================================
//   // SPECIFIC QUERY METHODS
//   // =============================================================================

//   /// Fetches the details for a specific song by its [id].
//   Future<SongDetail> fetchById(String id) async {
//     final command = GetSongDetailCommand(GetSongDetailRequest(id: id));
//     final result = await _fetchSource.execute(
//       command,
//       (res) async => [res.songDetail.toDomain()],
//     );
//     return result.first;
//   }

//   /// Establishes a watch stream for a specific song by its [id].
//   Stream<List<SongDetailEvent>> watchById(String id) {
//     final command = WatchSongDetailCommand(WatchSongDetailRequest(id: id));
//     return _watchSource.executeStream(command, (res) => res.toDomainList());
//   }
// }