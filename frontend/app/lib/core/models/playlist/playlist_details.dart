import 'package:flutter/foundation.dart';

import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';

/// A playlist as its own page shows it: the header above the songs.
@immutable
class PlaylistDetails {
  final String publicId;
  final String name;

  /// The uploaded cover, null when there is none.
  final String? coverUrl;
  final PlaylistVisibility visibility;
  final EditLicense editLicense;
  final int songCount;
  final Duration totalDuration;

  /// Bumped by the server on every change to the playlist. Two answers about
  /// the same playlist are ordered by it: the one with the higher revision is
  /// the newer state (PlaylistEditorStore).
  final int revision;

  const PlaylistDetails({
    required this.publicId,
    required this.name,
    required this.visibility,
    required this.editLicense,
    required this.songCount,
    required this.totalDuration,
    required this.revision,
    this.coverUrl,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaylistDetails &&
      other.publicId == publicId &&
      other.name == name &&
      other.coverUrl == coverUrl &&
      other.visibility == visibility &&
      other.editLicense == editLicense &&
      other.songCount == songCount &&
      other.totalDuration == totalDuration &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(
      publicId, name, coverUrl, visibility, editLicense, songCount, totalDuration, revision);
}

/// One row of a playlist. The same song can be in a playlist twice, so a row
/// is named by [id], never by its song.
@immutable
class PlaylistEntry {
  /// The row's id (`PlaylistSongDTO.id`), what RemoveSongFromPlaylist and
  /// MoveSongInPlaylist take.
  final int id;

  /// EventTrack because the song search returns one too: a search result is
  /// matched against the rows by [EventTrack.deezerId].
  final EventTrack track;

  const PlaylistEntry({required this.id, required this.track});

  @override
  bool operator ==(Object other) =>
      other is PlaylistEntry && other.id == id && other.track == track;

  @override
  int get hashCode => Object.hash(id, track);
}

/// A playlist and its songs, in order, as one answer from the server.
typedef PlaylistContents = ({PlaylistDetails details, List<PlaylistEntry> songs});
