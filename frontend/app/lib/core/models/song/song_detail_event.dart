import 'song_detail.dart';

// =============================================================================
// EVENTS
// =============================================================================

/// Sealed hierarchy representing updates for a specific song's detailed view.
sealed class SongDetailEvent {
  const SongDetailEvent();
}

/// Emitted when the server sends a full refresh of the song detail state.
class SongDetailRefreshed extends SongDetailEvent {
  final SongDetail detail;

  const SongDetailRefreshed(this.detail);
}

/// Emitted when only the playback state (position, status) changes incrementally.
class PlaybackStateUpdated extends SongDetailEvent {
  final PlaybackState state;

  const PlaybackStateUpdated(this.state);
}

/// Sealed hierarchy representing client actions dispatched during a sync session.
sealed class PlaybackAction {
  const PlaybackAction();
}

/// Dispatched when starting or resuming song playback.
class PlaySongAction extends PlaybackAction {
  final Duration? startPosition;

  const PlaySongAction({this.startPosition});
}

/// Dispatched during real-time position updates/scrubbing.
class UpdateProgressAction extends PlaybackAction {
  final Duration position;

  const UpdateProgressAction(this.position);
}