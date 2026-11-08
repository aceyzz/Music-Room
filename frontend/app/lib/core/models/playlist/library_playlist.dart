import 'package:flutter/foundation.dart';

import 'package:app/core/models/playlist/playlist_settings.dart';

/// How the signed-in user relates to a playlist, as the Playlists tab labels
/// it. Exactly one per playlist, decided by the server in this order of
/// precedence: a playlist you own is [mine] even if a friend edits it with
/// you, one you were invited to is [shared] even if its owner is a friend.
enum PlaylistRelation {
  /// You own it.
  mine,

  /// You are a member (an editor) but not the owner.
  shared,

  /// A friend owns it and you are not a member: you see it because it is
  /// public.
  friend,

  /// A public playlist with no other tie to you (Public pill, search).
  public,
}

/// A playlist as the Playlists tab lists it.
@immutable
class LibraryPlaylist {
  final String publicId;
  final String name;

  /// The first song's album art, null for an empty playlist.
  final String? coverUrl;
  final int songCount;

  /// Everyone who may edit it as a member: the owner, admins and editors. A
  /// playlist nobody was invited to has 1. People who may edit only because
  /// the licence is "everyone" are not counted: they are not a list.
  final int editorCount;
  final String ownerPublicId;
  final String ownerName;
  final PlaylistRelation relation;

  /// Separate from [relation]: a friend's playlist you edit is labelled
  /// Shared, and its owner is still a friend.
  final bool ownerIsFriend;

  /// Who can find it: the row marks a private one with a lock.
  final PlaylistVisibility visibility;

  const LibraryPlaylist({
    required this.publicId,
    required this.name,
    required this.songCount,
    required this.editorCount,
    required this.ownerPublicId,
    required this.ownerName,
    required this.relation,
    this.ownerIsFriend = false,
    this.coverUrl,
    this.visibility = PlaylistVisibility.public,
  });

  /// The line under the name: "3 editors · 24 songs". Whose it is, the row
  /// says with a star (yours), and the playlist's page with its owner.
  String get subtitle => [
        editorCount == 1 ? '1 editor' : '$editorCount editors',
        songCount == 1 ? '1 song' : '$songCount songs',
      ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is LibraryPlaylist &&
      other.publicId == publicId &&
      other.name == name &&
      other.coverUrl == coverUrl &&
      other.songCount == songCount &&
      other.editorCount == editorCount &&
      other.ownerPublicId == ownerPublicId &&
      other.ownerName == ownerName &&
      other.relation == relation &&
      other.ownerIsFriend == ownerIsFriend &&
      other.visibility == visibility;

  @override
  int get hashCode => Object.hash(publicId, name, coverUrl, songCount, editorCount, ownerPublicId,
      ownerName, relation, ownerIsFriend, visibility);
}

/// The pills of the Playlists tab: the user's [library] (theirs, shared with
/// them, their friends'; each row says which), or every [public] playlist,
/// searched. Two rather than one per relation: the rows already name it, and
/// a pill per relation overlapped (a friend's playlist you edit is both).
enum LibraryFilter {
  library('Library'),
  public('Public');

  final String label;

  const LibraryFilter(this.label);

  /// The `filter` query parameter (`/playlists?filter=public`); null for
  /// [library], which is the page's address without one.
  String? get queryValue => this == library ? null : name;

  /// An unknown or missing value is [library], so an old link
  /// (`?filter=mine`) still opens the tab.
  static LibraryFilter fromQuery(String? value) =>
      values.firstWhere((f) => f.name == value, orElse: () => library);
}

/// One page of public playlists. [nextPageToken] is null on the last one.
@immutable
class PlaylistResults {
  final List<LibraryPlaylist> items;
  final String? nextPageToken;

  const PlaylistResults(this.items, {this.nextPageToken});

  static const empty = PlaylistResults([]);
}
