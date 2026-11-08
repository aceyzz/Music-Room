// import 'package:app/core/models/song/song.dart';

// import 'package:app/core/sources/source.dart';
// import 'package:app/core/network/app_network.dart';
// import 'package:app/core/models/song/song_event.dart';
// import 'package:app/gen/api.dart';
// import 'package:app/core/mapping/mappers.dart';

// import 'commands/grpc_commands.dart' if (dart.library.js_interop) './commands/web_commands.dart';

// import 'sources/song_grpc_source.dart'
//     if (dart.library.js_interop) './sources/song_web_sources.dart';

// /// Entry point for managing song data operations.
// ///
// /// Coordinates fetch, watch, and synchronization network sources across native
// /// (gRPC) and web platforms.
// class SongSource extends DomainSource<Song, SongEvent, SongEvent, SyncSongsRequest> {
//   final SongFetchSource _fetchSource;
//   final SongWatchSource _watchSource;
//   final SongSyncSource _syncSource;

//   /// Private constructor to enforce initialization via [SongSource.from].
//   SongSource._(this._fetchSource, this._watchSource, this._syncSource);

//   // =============================================================================
//   // FACTORY INVOCATIONS
//   // =============================================================================

//   /// Instantiates a platform-aware [SongSource] bound to the given [appNetwork].
//   static SongSource from(AppNetwork appNetwork) {
//     final fetchSource = SongFetchSource.create(appNetwork);
//     final watchSource = SongWatchSource.create(appNetwork);
//     final syncSource = SongSyncSource.create(appNetwork);
//     return SongSource._(fetchSource, watchSource, syncSource);
//   }

//   // =============================================================================
//   // DOMAIN SOURCE IMPLEMENTATION
//   // =============================================================================

//   @override
//   Future<List<Song>> fetch() {
//     final command = GetSongsCommand(GetSongsRequest());
//     return _fetchSource.execute(command, (res) => res.toDomainList());
//   }

//   @override
//   Stream<List<SongEvent>> watch() {
//     final command = WatchSongsCommand(WatchSongsRequest());
//     return _watchSource.executeStream(command, (res) => res.toDomainList());
//   }

//   @override
//   Stream<List<SongEvent>> synchronize(Stream<SyncSongsRequest> clientActions) {
//     final command = SyncSongsCommand(clientActions);
//     return _syncSource.executeBiStream(command, clientActions, (res) => res.toDomainList());
//   }

//   // =============================================================================
//   // SPECIFIC QUERY METHODS
//   // =============================================================================

//   /// Searches for a specific song or matching query against the underlying source.
//   Future<List<Song>> search(String query) {
//     final command = GetSongCommand(GetSongRequest());
//     return _fetchSource.execute(command, (res) => res.toDomainList());
//   }
// }
