import 'package:app/core/models/song/song_detail.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/repository/repository.dart';
// import 'package:app/gen/api.dart';

/// Repository managing high-level song state operations and event transformations.
///
/// Converts raw server streams and snapshots from [SongSource] and [SongDetailSource]
/// into reactive, immutable domain models for UI consumption.
class SongRepository implements Repository {
  // final SongSource _songSource;
  // final SongDetailSource _songDetailSource;

  /// Creates a [SongRepository] wrapping the provided [_songSource] and [_songDetailSource].
  const SongRepository();

  // =============================================================================
  // REPOSITORY METHODS (SONGS)
  // =============================================================================

  /// Exposes a stream that starts with the full initial list and applies real-time changes.
  // Stream<List<Song>> watchAllSongs() async* {
  //   // 1. Get the initial full snapshot
  //   final List<Song> currentSongs = List.from(await _songSource.fetch());

  //   // 2. Yield the initial state immediately to the UI
  //   yield List.unmodifiable(currentSongs);

  //   // 3. Listen to ongoing event updates from the watch stream
  //   await for (final events in _songSource.watch()) {
  //     for (final event in events) {
  //       _applyEvent(currentSongs, event);
  //     }

  //     // 4. Yield the updated list on every new stream payload
  //     yield List.unmodifiable(currentSongs);
  //   }
  // }

  /// Establishes a bidirectional state synchronization session for songs.
  ///
  /// Pushes [localActions] to the server in real-time and yields a continuously
  /// updated list of songs based on incoming server events.
  // Stream<List<Song>> syncSongs(Stream<SyncSongsRequest> localActions) async* {
  //   // 1. Retrieve initial snapshot state
  //   final List<Song> currentSongs = List.from(await _songSource.fetch());
  //   yield List.unmodifiable(currentSongs);

  //   // 2. Pass outgoing local stream and apply incoming remote events
  //   await for (final events in _songSource.synchronize(localActions)) {
  //     for (final event in events) {
  //       _applyEvent(currentSongs, event);
  //     }

  //     // 3. Yield updated state on each payload
  //     yield List.unmodifiable(currentSongs);
  //   }
  // }

  // =============================================================================
  // REPOSITORY METHODS (SONG DETAILS)
  // =============================================================================

  /// Fetches a single [SongDetail] instance by its [id].
  // Future<SongDetail> getSongDetail(String id) {
  //   return _songDetailSource.fetchById(id);
  // }

  /// Exposes a stream that starts with the initial detail snapshot and applies real-time updates.
  // Stream<SongDetail> watchSongDetail(String id) async* {
  //   // 1. Fetch the initial song detail snapshot
  //   SongDetail currentDetail = await _songDetailSource.fetchById(id);

  //   // 2. Yield the initial state immediately
  //   yield currentDetail;

  //   // 3. Listen to ongoing event updates from the watch stream
  //   await for (final events in _songDetailSource.watchById(id)) {
  //     for (final event in events) {
  //       currentDetail = _applyDetailEvent(currentDetail, event);
  //     }

  //     // 4. Yield the updated state on every new event payload
  //     yield currentDetail;
  //   }
  // }

  /// Establishes a bidirectional playback synchronization session for a song detail state.
  ///
  /// Pushes [localActions] (play, pause, update progress) to the server in real-time
  /// and yields updated [SongDetail] models as the server emits events.
  // Stream<SongDetail> syncSongDetail(
  //   String id,
  //   Stream<SyncSongDetailRequest> localActions,
  // ) async* {
  //   // 1. Retrieve initial snapshot state
  //   SongDetail currentDetail = await _songDetailSource.fetchById(id);
  //   yield currentDetail;

  //   // 2. Pass outgoing local action stream and apply incoming remote events
  //   await for (final events in _songDetailSource.synchronize(localActions)) {
  //     for (final event in events) {
  //       currentDetail = _applyDetailEvent(currentDetail, event);
  //     }

  //     // 3. Yield updated detail state on each payload
  //     yield currentDetail;
  //   }
  // }

  // =============================================================================
  // FACTORY METHOD
  // =============================================================================

  static SongRepository create(AppNetwork appNetwork) {
    // final songSource = SongSource.from(appNetwork);
    // final detailSource = SongDetailSource.from(appNetwork);
    return SongRepository();
  }

}