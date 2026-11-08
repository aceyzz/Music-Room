import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/sources/live_stream.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';

/// The playlist page: one playlist, its songs, and the edits to them.
///
/// Page-level (built and stopped by PlaylistDetailPage, see the note in
/// globals/app_router.dart).
///
/// Several people can edit the same playlist. The server pushes the whole
/// playlist after every change anyone makes (PlaylistService.WatchPlaylist),
/// for as long as the page is open, and each edit's answer carries it too.
///
/// Those can arrive out of order: a push sent before an edit can come after
/// its answer. The server's revision orders them -- it is bumped by every
/// change -- so a state older than what is shown is dropped.
///
/// Removing and moving show at once, before the server answers: a swiped row
/// has to leave the list on the spot, and a dragged one has to stay where it
/// was dropped. The answer then replaces the guess.
class PlaylistEditorStore {
  final PlaylistEditorApi _api;
  final String _publicId;
  final String _userPublicId;

  final ValueNotifier<ItemState<PlaylistDetails>> details = ValueNotifier(ItemState.initial());
  final ValueNotifier<ListState<PlaylistEntry>> songs = ValueNotifier(ListState.initial());

  /// Whether the signed-in user may add, move and remove songs.
  final ValueNotifier<bool> canEdit = ValueNotifier(false);

  late final LiveStream<PlaylistView> _live;

  /// Set by [stop]. A request can outlive the page, and writing to a disposed
  /// notifier throws.
  bool _stopped = false;

  PlaylistEditorStore(
    this._api,
    this._publicId,
    this._userPublicId, {
    List<Duration> retryDelays = LiveStream.defaultRetryDelays,
  }) {
    _live = LiveStream(
      () => _api.watchPlaylist(_publicId, _userPublicId),
      onState: (state) {
        if (_show((details: state.details, songs: state.songs))) {
          _set(canEdit, state.canEdit);
        }
      },
      // A dropped connection keeps what is shown: only a page with nothing
      // yet, or a playlist that is gone (deleted, made private), shows it.
      onError: (error) {
        if (details.value.data == null || error is NotFoundError) {
          _set(details, ItemState.error(error, details.value.data));
          _set(songs, ListState.error(error, songs.value.data));
        }
      },
      retryDelays: retryDelays,
    );
  }

  /// Opens the stream. Completes once the first state is shown, or the first
  /// attempt failed.
  Future<void> start() {
    _set(details, ItemState.loading(details.value.data));
    _set(songs, ListState.loading(songs.value.data));
    return _live.start();
  }

  void stop() {
    _stopped = true;
    _live.stop();
    details.dispose();
    songs.dispose();
    canEdit.dispose();
  }

  /// Reads the playlist again, and opens the stream again if it had stopped
  /// for good (the "Try again" after a NotFoundError).
  Future<void> refresh() async {
    _set(details, ItemState.loading(details.value.data));
    _set(songs, ListState.loading(songs.value.data));
    try {
      final result = await _api.openPlaylist(_publicId, _userPublicId);
      if (_show((details: result.details, songs: result.songs))) {
        _set(canEdit, result.canEdit);
      }
      _live.resume();
    } on AppError catch (error) {
      _set(details, ItemState.error(error, details.value.data));
      _set(songs, ListState.error(error, songs.value.data));
    }
  }

  // --- The edits. Each throws the server's AppError for the page to show.

  /// Appends [track] (a search result). Throws ConflictError when the song is
  /// already in the playlist -- added by this user or by someone else since
  /// the last read -- unless [allowDuplicate]: the page asks first.
  Future<void> add(EventTrack track, {bool allowDuplicate = false}) => _write(
      () => _api.addSong(_publicId, _userPublicId, track.deezerId, allowDuplicate: allowDuplicate));

  /// Removes [entry]. It leaves the list at once; if the server refuses, the
  /// list is read again so it comes back. Already removed by someone else is
  /// not an error: the result is the one the user wanted.
  Future<void> remove(PlaylistEntry entry) async {
    final shown = songs.value.data ?? const <PlaylistEntry>[];
    _set(songs, _whole(shown.where((e) => e.id != entry.id).toList()));
    try {
      await _write(() => _api.removeSong(_publicId, _userPublicId, entry.id));
    } on NotFoundError {
      unawaited(refresh());
    } on AppError {
      unawaited(refresh());
      rethrow;
    }
  }

  /// Moves the song at [from] so that it ends up at [to], both indexes in the
  /// list as shown (where [to] counts without the moved song, as when it is
  /// dropped). It lands there at once.
  ///
  /// The server is told where relative to the song now just above it ("after
  /// Y", or "to the top"), not an index: an index would mean something else
  /// once someone else has added or removed a song, the anchor does not. So
  /// the move is refused only when the song or the anchor has been removed
  /// meanwhile: NotFoundError, and the list is read again.
  Future<void> move(int from, int to) async {
    final shown = [...?songs.value.data];
    if (from == to || from < 0 || from >= shown.length || to < 0 || to >= shown.length) {
      return;
    }
    final entry = shown.removeAt(from);
    shown.insert(to, entry);
    _set(songs, _whole(shown));
    final after = to == 0 ? 0 : shown[to - 1].id;
    try {
      await _write(() => _api.moveSong(_publicId, _userPublicId, entry.id, afterEntryId: after));
    } on AppError {
      unawaited(refresh());
      rethrow;
    }
  }

  // --- Helpers.

  Future<void> _write(Future<PlaylistContents> Function() send) async {
    // An edit's answer is newer than anything shown: it is the state right
    // after this edit, under the server's lock.
    _show(await send(), force: true);
  }

  /// Shows [contents] unless what is shown is newer, and says whether it did.
  /// [force] for an edit's answer, which a read or push that started before
  /// the edit cannot have seen.
  bool _show(PlaylistContents contents, {bool force = false}) {
    final shown = details.value.data?.revision;
    if (!force && shown != null && contents.details.revision < shown) {
      // Still clear the loading flags the read set.
      _set(details, ItemState.success(details.value.data!));
      _set(songs, _whole(songs.value.data ?? const []));
      return false;
    }
    _set(details, ItemState.success(contents.details));
    _set(songs, _whole(contents.songs));
    return true;
  }

  /// A playlist is always read whole: there is no next page.
  static ListState<PlaylistEntry> _whole(List<PlaylistEntry> entries) =>
      ListState.success(entries, hasReachedEnd: true);

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (!_stopped) {
      notifier.value = value;
    }
  }
}
