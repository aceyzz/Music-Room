import 'package:flutter/foundation.dart';

/// A song as an event plays or queues it: what the player shows, plus the
/// Deezer 30-second preview it plays. Also what the song search returns
/// (SongSearchApi), so a result can be suggested by its [deezerId] and
/// matched against the queue.
@immutable
class EventTrack {
  /// The song's id in Deezer's catalogue, what SuggestSong takes. The same
  /// song has the same id in a search result, the queue and the playback.
  /// 0 when unknown.
  final int deezerId;
  final String title;
  final String artist;
  final String album;

  /// Null when Deezer has no art for it.
  final String? coverUrl;

  /// Null when there is nothing to play: the track still shows, silent.
  final String? previewUrl;
  final Duration duration;

  const EventTrack({
    required this.title,
    required this.artist,
    required this.duration,
    this.deezerId = 0,
    this.album = '',
    this.coverUrl,
    this.previewUrl,
  });

  @override
  bool operator ==(Object other) =>
      other is EventTrack &&
      other.deezerId == deezerId &&
      other.title == title &&
      other.artist == artist &&
      other.album == album &&
      other.coverUrl == coverUrl &&
      other.previewUrl == previewUrl &&
      other.duration == duration;

  @override
  int get hashCode => Object.hash(deezerId, title, artist, album, coverUrl, previewUrl, duration);
}

/// What an event is playing, as the server last said.
///
/// The server does not tick: it stores the playhead as of [updatedAt], and a
/// client works the live position out from there ([positionAt]). That is why
/// a joining or refreshing client lands in the right place without the server
/// pushing anything.
@immutable
class EventPlayback {
  /// The queue entry playing; null when nothing is (the queue ran dry, or the
  /// host has not started yet). Internal id: only compared, never sent.
  final int? currentEntryId;

  /// Set exactly when [currentEntryId] is.
  final EventTrack? track;
  final bool isPaused;

  /// The playhead as of [updatedAt].
  final Duration position;
  final DateTime updatedAt;

  /// The device that plays the sound (the host's first play sets it); null
  /// until then. Internal id, compared with this app's own device: only that
  /// app plays the sound, the others are remotes.
  final int? speakerDeviceId;

  const EventPlayback({
    required this.isPaused,
    required this.position,
    required this.updatedAt,
    this.currentEntryId,
    this.track,
    this.speakerDeviceId,
  });

  /// Nothing playing.
  const EventPlayback.idle(this.updatedAt, {this.speakerDeviceId})
      : currentEntryId = null,
        track = null,
        isPaused = true,
        position = Duration.zero;

  bool get isPlaying => track != null && !isPaused;

  /// The playhead at [now]: [position] while paused, otherwise [position] plus
  /// the time since [updatedAt]. Kept between zero and the song's length, so a
  /// late refresh shows the song finished rather than past its end, and a
  /// clock slightly behind the server's never shows a negative time.
  Duration positionAt(DateTime now) {
    final track = this.track;
    if (track == null) {
      return Duration.zero;
    }
    final at = isPaused ? position : position + now.difference(updatedAt);
    if (at < Duration.zero) {
      return Duration.zero;
    }
    return at > track.duration ? track.duration : at;
  }

  @override
  bool operator ==(Object other) =>
      other is EventPlayback &&
      other.currentEntryId == currentEntryId &&
      other.track == track &&
      other.isPaused == isPaused &&
      other.position == position &&
      other.updatedAt == updatedAt &&
      other.speakerDeviceId == speakerDeviceId;

  @override
  int get hashCode =>
      Object.hash(currentEntryId, track, isPaused, position, updatedAt, speakerDeviceId);
}

/// One song waiting in an event's vote queue. The server sends the queue
/// already in play order (most votes first).
@immutable
class QueueEntry {
  final String publicId;
  final int voteCount;
  final EventTrack track;

  /// Whether the signed-in user has voted for it. A vote cannot be taken
  /// back (CastVote is upvote-only), so this only ever goes from false to
  /// true.
  final bool viewerHasVoted;

  const QueueEntry({
    required this.publicId,
    required this.voteCount,
    required this.track,
    this.viewerHasVoted = false,
  });

  @override
  bool operator ==(Object other) =>
      other is QueueEntry &&
      other.publicId == publicId &&
      other.voteCount == voteCount &&
      other.track == track &&
      other.viewerHasVoted == viewerHasVoted;

  @override
  int get hashCode => Object.hash(publicId, voteCount, track, viewerHasVoted);
}
