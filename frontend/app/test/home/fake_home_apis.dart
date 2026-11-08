import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';

/// In-memory [EventApi]: returns [events], or throws [failure]. [created]
/// records what createEvent was sent; it answers with an event `new-N`.
class FakeEventApi implements EventApi {
  List<EventSummary> events = const [];
  AppError? failure;
  int calls = 0;
  final List<
      ({
        String host,
        String name,
        String description,
        EventVisibility visibility,
        VoteLicense voteLicense,
        DateTime startsAt,
        DateTime endsAt,
        EventVenue? venue,
      })> created = [];

  @override
  Future<List<EventSummary>> myEvents(String userPublicId) async {
    calls++;
    if (failure != null) {
      throw failure!;
    }
    return events;
  }

  @override
  Future<EventSummary> createEvent(
    String hostPublicId, {
    required String name,
    String description = '',
    required EventVisibility visibility,
    required VoteLicense voteLicense,
    required DateTime startsAt,
    required DateTime endsAt,
    EventVenue? venue,
  }) async {
    if (failure != null) {
      throw failure!;
    }
    created.add((
      host: hostPublicId,
      name: name,
      description: description,
      visibility: visibility,
      voteLicense: voteLicense,
      startsAt: startsAt,
      endsAt: endsAt,
      venue: venue,
    ));
    return EventSummary(
      publicId: 'new-${created.length}',
      name: name,
      description: description.isEmpty ? null : description,
      status: 'scheduled',
      startsAt: startsAt,
      endsAt: endsAt,
      createdAt: startsAt,
      visibility: visibility,
    );
  }
}

/// In-memory [PlaylistApi]: returns [playlists] (cut to the limit),
/// [libraryPlaylists], or [publicPlaylistsByQuery] split into pages of the
/// requested size; or throws [failure]. [calls] records what was asked.
class FakePlaylistApi implements PlaylistApi {
  List<PlaylistSummary> playlists = const [];
  List<LibraryPlaylist> libraryPlaylists = const [];
  Map<String, List<LibraryPlaylist>> publicPlaylistsByQuery = const {};
  AppError? failure;
  final List<String> calls = [];

  /// When set, publicPlaylists waits for it: lets a test answer out of order.
  Future<void> Function(String query)? beforePublicAnswer;

  void _call(String name) {
    calls.add(name);
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  Future<List<PlaylistSummary>> recentPlaylists(String userPublicId, {int limit = 5}) async {
    _call('recentPlaylists');
    return playlists.take(limit).toList();
  }

  @override
  Future<List<LibraryPlaylist>> library(String userPublicId) async {
    _call('library');
    return libraryPlaylists;
  }

  /// What [createPlaylist] was asked to create, in order.
  final List<({String owner, String name, PlaylistVisibility visibility, EditLicense editLicense})>
      created = [];

  /// Returns `new-1`, `new-2`... with no songs.
  @override
  Future<PlaylistSummary> createPlaylist(
    String ownerPublicId, {
    required String name,
    required PlaylistVisibility visibility,
    required EditLicense editLicense,
  }) async {
    _call('createPlaylist');
    created
        .add((owner: ownerPublicId, name: name, visibility: visibility, editLicense: editLicense));
    return PlaylistSummary(publicId: 'new-${created.length}', name: name, songCount: 0);
  }

  /// The page token is the index of the page's first item.
  @override
  Future<PlaylistResults> publicPlaylists({
    String query = '',
    String? pageToken,
    int pageSize = 30,
    bool myTaste = false,
  }) async {
    calls.add('publicPlaylists($query${pageToken == null ? '' : ', $pageToken'}'
        '${myTaste ? ', my taste' : ''})');
    await beforePublicAnswer?.call(query);
    if (failure != null) {
      throw failure!;
    }
    // "My taste" answers are keyed "taste:<query>".
    final all =
        publicPlaylistsByQuery[myTaste ? 'taste:$query' : query] ?? const <LibraryPlaylist>[];
    final start = int.parse(pageToken ?? '0');
    final end = (start + pageSize).clamp(0, all.length);
    return PlaylistResults(
      all.sublist(start, end),
      nextPageToken: end < all.length ? '$end' : null,
    );
  }
}

/// A library row; the owner's name is [owner].
LibraryPlaylist libraryPlaylist(
  String id, {
  PlaylistRelation relation = PlaylistRelation.mine,
  String owner = 'neo',
  bool ownerIsFriend = false,
  int editors = 1,
  int songs = 0,
  PlaylistVisibility visibility = PlaylistVisibility.public,
}) =>
    LibraryPlaylist(
      publicId: id,
      name: 'Playlist $id',
      songCount: songs,
      editorCount: editors,
      ownerPublicId: 'owner-$owner',
      ownerName: owner,
      relation: relation,
      ownerIsFriend: ownerIsFriend,
      visibility: visibility,
    );

final epoch = DateTime.utc(2026, 1, 1);

EventSummary event(
  String id, {
  String status = 'scheduled',
  DateTime? startsAt,
  DateTime? endsAt,
  DateTime? createdAt,
  EventVisibility visibility = EventVisibility.public,
  bool host = false,
  // Yours by default: Home shows only the events the user is in.
  bool member = true,
}) =>
    EventSummary(
      publicId: id,
      name: 'Event $id',
      status: status,
      startsAt: startsAt,
      endsAt: endsAt,
      createdAt: createdAt ?? epoch,
      visibility: visibility,
      viewerIsHost: host,
      viewerIsMember: member || host,
    );
