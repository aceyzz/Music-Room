import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';

/// The Playlists tab: the signed-in user's library, and the public playlists
/// the Public pill lists and searches.
///
/// Page-level (built and stopped by PlaylistsPage, see the note in
/// globals/app_router.dart). Which pill is selected is not kept here: it is
/// the page's address, and every pill but Public is a filter over [library].
class LibraryStore {
  final PlaylistApi _api;
  final String _userPublicId;

  /// The signed-in user's name, the owner shown on a playlist they create.
  final String _userName;

  /// How long typing must pause before a search is sent, so a word is one
  /// request rather than one per letter.
  static const searchDelay = Duration(milliseconds: 300);
  static const pageSize = 30;

  final ValueNotifier<ListState<LibraryPlaylist>> library = ValueNotifier(ListState.initial());
  final ValueNotifier<ListState<LibraryPlaylist>> publicResults =
      ValueNotifier(ListState.initial());

  /// What the search field holds, trimmed.
  String get query => _query;
  String _query = '';

  /// The query [publicResults] answers. Differs from [query] while a search
  /// is waiting or in flight.
  String get resultsQuery => _resultsQuery;
  String _resultsQuery = '';

  /// Only playlists by people with the user's taste (the "My taste" chip).
  bool get myTaste => _myTaste;
  bool _myTaste = false;

  /// Whether [publicResults] were read with [myTaste] on, next to
  /// [resultsQuery]: the two together say what the results answer.
  bool _resultsMyTaste = false;

  String? _nextPageToken;

  /// Playlists created on this page that the server has not listed yet.
  final List<LibraryPlaylist> _created = [];

  /// Bumped by every new search or reload. A response carrying an older
  /// number is dropped: a slow answer to "ro" must not overwrite "rock".
  int _generation = 0;

  Timer? _searchTimer;
  bool _publicRequested = false;

  /// What "Try again" does after a public request failed: reload the first
  /// page, or fetch the page that failed.
  Future<void> Function()? _publicRetry;

  /// Set by [stop]. A request can outlive the page, and writing to a disposed
  /// notifier throws.
  bool _stopped = false;

  LibraryStore(this._api, this._userPublicId, this._userName);

  Future<void> start() => reloadLibrary();

  void stop() {
    _stopped = true;
    _searchTimer?.cancel();
    library.dispose();
    publicResults.dispose();
  }

  /// Creates a playlist and puts it at the top of [library]. Throws the
  /// server's [AppError], leaving the library as it was.
  ///
  /// Added here rather than by reloading: the server lists a playlist once
  /// its owner tuple has reached OpenFGA (the outbox), a moment after
  /// CreatePlaylist answers.
  Future<LibraryPlaylist> create({
    required String name,
    required PlaylistVisibility visibility,
    required EditLicense editLicense,
  }) async {
    final created = await _api.createPlaylist(
      _userPublicId,
      name: name,
      visibility: visibility,
      editLicense: editLicense,
    );
    final playlist = LibraryPlaylist(
      publicId: created.publicId,
      name: created.name,
      coverUrl: created.coverUrl,
      songCount: created.songCount,
      editorCount: 1, // the owner; nobody is invited yet
      ownerPublicId: _userPublicId,
      ownerName: _userName,
      relation: PlaylistRelation.mine,
    );
    _created.insert(0, playlist);
    final current = library.value;
    _set(library, ListState.success([playlist, ...?current.data], hasReachedEnd: true));
    return playlist;
  }

  Future<void> reloadLibrary() async {
    _set(library, ListState.loading(library.value.data));
    try {
      final loaded = await _api.library(_userPublicId);
      // A playlist created here a moment ago may not be listed yet (its
      // owner tuple reaches OpenFGA through the outbox): keep it on top
      // until the server lists it.
      _created.removeWhere((c) => loaded.any((p) => p.publicId == c.publicId));
      _set(library, ListState.success([..._created, ...loaded], hasReachedEnd: true));
    } on AppError catch (error) {
      _set(library, ListState.error(error, library.value.data));
    }
  }

  /// Loads the public playlists the first time the Public pill is shown;
  /// later visits keep what is there (pull down to refresh).
  Future<void> ensurePublicLoaded() async {
    if (!_publicRequested) {
      await reloadPublic();
    }
  }

  /// Searches public playlists once typing pauses for [searchDelay].
  void search(String text) {
    final next = text.trim();
    if (next == _query) {
      return;
    }
    _query = next;
    _generation++; // what is in flight answers an older query
    _searchTimer?.cancel();
    _searchTimer = Timer(searchDelay, reloadPublic);
  }

  /// Turns the "My taste" filter on or off, and reads the first page again.
  Future<void> setMyTaste(bool on) {
    if (on == _myTaste) {
      return Future.value();
    }
    _myTaste = on;
    return reloadPublic();
  }

  /// The first page for [query]. Results for another query, or with the
  /// other filter, are cleared rather than shown under the new one while it
  /// loads.
  Future<void> reloadPublic() async {
    _searchTimer?.cancel();
    _publicRequested = true;
    final generation = ++_generation;
    final query = _query;
    final myTaste = _myTaste;
    final kept =
        query == _resultsQuery && myTaste == _resultsMyTaste ? publicResults.value.data : null;
    _set(publicResults, ListState.loading(kept));
    try {
      final page = await _api.publicPlaylists(query: query, pageSize: pageSize, myTaste: myTaste);
      if (generation != _generation) {
        return;
      }
      _resultsQuery = query;
      _resultsMyTaste = myTaste;
      _nextPageToken = page.nextPageToken;
      _set(publicResults, ListState.success(page.items, hasReachedEnd: page.nextPageToken == null));
    } on AppError catch (error) {
      if (generation != _generation) {
        return;
      }
      _publicRetry = reloadPublic;
      _set(publicResults, ListState.error(error, kept));
    }
  }

  /// The next page of public results. Does nothing while a request is
  /// running, at the end, or before the first page.
  Future<void> loadMorePublic() async {
    if (_stopped) {
      return; // called after a frame, which can come after the page is gone
    }
    final state = publicResults.value;
    final shown = state.data;
    final token = _nextPageToken;
    if (shown == null ||
        token == null ||
        state.isLoading ||
        state.isFetchingMore ||
        state.hasReachedEnd ||
        state.hasError) {
      return;
    }
    final generation = _generation;
    _set(publicResults, ListState.fetchingMore(currentData: shown));
    try {
      final page = await _api.publicPlaylists(
          query: _query, pageToken: token, pageSize: pageSize, myTaste: _myTaste);
      if (generation != _generation) {
        return;
      }
      _nextPageToken = page.nextPageToken;
      _set(
        publicResults,
        ListState.success([...shown, ...page.items], hasReachedEnd: page.nextPageToken == null),
      );
    } on AppError catch (error) {
      if (generation != _generation) {
        return;
      }
      _publicRetry = _retryMore;
      _set(publicResults, ListState.error(error, shown));
    }
  }

  /// "Try again" under the public list: repeats whatever failed.
  Future<void> retryPublic() => (_publicRetry ?? reloadPublic)();

  /// [loadMorePublic] refuses to run on an error state; clear it first.
  Future<void> _retryMore() async {
    final shown = publicResults.value.data;
    if (shown != null) {
      _set(publicResults, ListState.success(shown));
    }
    await loadMorePublic();
  }

  void _set<S>(ValueNotifier<S> state, S next) {
    if (!_stopped) {
      state.value = next;
    }
  }
}
