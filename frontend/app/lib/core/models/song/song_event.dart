import 'package:fixnum/fixnum.dart';
import 'song.dart';

// =============================================================================
// EVENTS
// =============================================================================

/// Base representation of real-time song updates received from the watch stream.
sealed class SongEvent {}

/// Event triggered when a new song is added.
class SongAdded extends SongEvent {
  final Song song;
  SongAdded(this.song);
}

/// Event triggered when a song is deleted.
class SongDeleted extends SongEvent {
  final String id;
  SongDeleted(this.id);
}

/// Event triggered to keep the connection alive and report server time.
class SongHeartbeat extends SongEvent {
  final Int64 timestamp;
  SongHeartbeat(this.timestamp);
}

