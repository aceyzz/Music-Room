import 'dart:async';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';

/// A 30-second song called [title], by "Artist of [title]".
EventTrack song(int deezerId, String title) => EventTrack(
      deezerId: deezerId,
      title: title,
      artist: 'Artist of $title',
      duration: const Duration(seconds: 30),
    );

/// In-memory [PlaylistEditorApi] holding one playlist, `p1`, and behaving
/// like the server: every change bumps [revision], a song already there is
/// refused with ConflictError unless allowed, and a move or remove naming a
/// row that is gone is NotFoundError.
///
/// [calls] records what was asked ("open", "add 42", "add 42 again",
/// "remove 3", "move 3 after 1"). [failure] is thrown by every call while set,
/// [failNext] by the next call only.
/// While [holdOpen] is set, openPlaylist answers with the playlist as it was
/// when asked, once it completes: a read that started before an edit.
///
/// watchPlaylist ("watch" in [calls]) sends the playlist when listened to,
/// then again on each [push]: someone else's edit reaches the screen only
/// when a test pushes it, the way the server's push arrives a moment later.
/// [endWatches] drops every open stream (a server restart).
class FakePlaylistEditorApi implements PlaylistEditorApi {
  String name = 'Road trip';
  PlaylistVisibility visibility = PlaylistVisibility.public;
  EditLicense editLicense = EditLicense.everyone;
  bool canEdit = true;
  int revision = 1;
  List<PlaylistEntry> rows = [];

  /// What addSong adds for a Deezer id; [song] (id, "Song id") otherwise.
  Map<int, EventTrack> catalogue = {};

  AppError? failure;
  AppError? failNext;
  Completer<void>? holdOpen;
  final List<String> calls = [];
  int _nextRow = 100;
  final List<StreamController<PlaylistView>> _watches = [];

  /// Fills the playlist with [tracks], as rows 1, 2, 3...
  void seed(List<EventTrack> tracks) {
    rows = [for (var i = 0; i < tracks.length; i++) PlaylistEntry(id: i + 1, track: tracks[i])];
  }

  /// Someone else's edit: [change] the rows, and the revision moves on.
  void othersEdit(void Function(List<PlaylistEntry> rows) change) {
    change(rows);
    revision++;
  }

  /// What the server would push now to every open stream.
  void push() {
    for (final watch in [..._watches]) {
      watch.add(_view());
    }
  }

  /// The viewer may no longer see the playlist (made private, deleted): every
  /// open stream ends on NotFound, as the server's does.
  void loseAccess() {
    for (final watch in [..._watches]) {
      watch.addError(const NotFoundError('playlist not found'));
      watch.close();
    }
  }

  void endWatches() {
    for (final watch in [..._watches]) {
      watch.close();
    }
  }

  PlaylistView _view() {
    final contents = _contents();
    return (details: contents.details, songs: contents.songs, canEdit: canEdit);
  }

  PlaylistContents _contents() => (
        details: PlaylistDetails(
          publicId: 'p1',
          name: name,
          visibility: visibility,
          editLicense: editLicense,
          songCount: rows.length,
          totalDuration: rows.fold(Duration.zero, (sum, e) => sum + e.track.duration),
          revision: revision,
        ),
        songs: List.unmodifiable(rows),
      );

  void _call(String call) {
    calls.add(call);
    final once = failNext;
    if (once != null) {
      failNext = null;
      throw once;
    }
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  Future<({PlaylistDetails details, List<PlaylistEntry> songs, bool canEdit})> openPlaylist(
      String publicId, String viewerPublicId) async {
    _call('open');
    final asked = _contents();
    await holdOpen?.future;
    return (details: asked.details, songs: asked.songs, canEdit: canEdit);
  }

  @override
  Stream<PlaylistView> watchPlaylist(String publicId, String viewerPublicId) {
    late final StreamController<PlaylistView> watch;
    watch = StreamController(
      onListen: () {
        try {
          _call('watch');
        } on AppError catch (error) {
          watch.addError(error);
          watch.close();
          return;
        }
        _watches.add(watch);
        watch.add(_view());
      },
      onCancel: () => _watches.remove(watch),
    );
    return watch.stream;
  }

  @override
  Future<PlaylistContents> addSong(String publicId, String userPublicId, int deezerId,
      {bool allowDuplicate = false}) async {
    _call(allowDuplicate ? 'add $deezerId again' : 'add $deezerId');
    if (!allowDuplicate && rows.any((e) => e.track.deezerId == deezerId)) {
      throw const ConflictError('song already exists in the playlist');
    }
    rows = [
      ...rows,
      PlaylistEntry(id: _nextRow++, track: catalogue[deezerId] ?? song(deezerId, 'Song $deezerId')),
    ];
    revision++;
    return _contents();
  }

  @override
  Future<PlaylistContents> removeSong(String publicId, String userPublicId, int entryId) async {
    _call('remove $entryId');
    if (!rows.any((e) => e.id == entryId)) {
      throw const NotFoundError('playlist or playlist song not found');
    }
    rows = rows.where((e) => e.id != entryId).toList();
    revision++;
    return _contents();
  }

  @override
  Future<PlaylistContents> moveSong(String publicId, String userPublicId, int entryId,
      {required int afterEntryId}) async {
    _call('move $entryId after $afterEntryId');
    final moved = rows.where((e) => e.id == entryId).firstOrNull;
    if (moved == null || (afterEntryId != 0 && !rows.any((e) => e.id == afterEntryId))) {
      throw const NotFoundError('the song or the one it goes after is no longer in the playlist');
    }
    final rest = rows.where((e) => e.id != entryId).toList();
    rest.insert(afterEntryId == 0 ? 0 : rest.indexWhere((e) => e.id == afterEntryId) + 1, moved);
    rows = rest;
    revision++;
    return _contents();
  }
}
