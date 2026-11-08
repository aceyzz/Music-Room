import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/music/song/data/song_search_source.dart';

/// A search of Deezer's catalogue as the user types: the suggest sheet of a
/// live event today, the playlist page's "add songs" later.
///
/// Owned by the widget that shows it, built and stopped with it. The same
/// mechanism as the people search (FriendsStore.search): a request once
/// typing pauses, and only the newest answer shown.
class SongSearchStore {
  final SongSearchApi _api;

  /// How long typing must pause before a search is sent: the app's other
  /// searches wait as long.
  static const searchDelay = Duration(milliseconds: 300);

  final ValueNotifier<ListState<EventTrack>> results = ValueNotifier(ListState.initial());

  /// What the search field holds, trimmed. Empty means nothing is searched.
  String get query => _query;
  String _query = '';

  /// The query [results] answers. Differs from [query] while a search is
  /// waiting or in flight.
  String get resultsQuery => _resultsQuery;
  String _resultsQuery = '';

  /// Bumped by every new search. A response carrying an older number is
  /// dropped: a slow answer to "da" must not overwrite "daft".
  int _generation = 0;

  Timer? _searchTimer;

  /// Set by [stop]. A request can outlive the sheet, and writing to a
  /// disposed notifier throws.
  bool _stopped = false;

  SongSearchStore(this._api);

  void stop() {
    _stopped = true;
    _searchTimer?.cancel();
    results.dispose();
  }

  /// Searches once typing pauses for [searchDelay]. Clearing the field drops
  /// the results at once, with no request.
  void search(String text) {
    final next = text.trim();
    if (next == _query) {
      return;
    }
    _query = next;
    _generation++; // what is in flight answers an older query
    _searchTimer?.cancel();
    if (next.isEmpty) {
      _resultsQuery = '';
      _set(results, ListState<EventTrack>.initial());
      return;
    }
    _searchTimer = Timer(searchDelay, retry);
  }

  /// Runs the search for [query] now: after the pause, or from a Retry
  /// button. Results for another query are cleared rather than shown under
  /// the new one while it loads.
  Future<void> retry() async {
    _searchTimer?.cancel();
    final generation = ++_generation;
    final query = _query;
    if (query.isEmpty) {
      return;
    }
    final kept = query == _resultsQuery ? results.value.data : null;
    _set(results, ListState.loading(kept));
    try {
      final found = await _api.searchSongs(query);
      if (generation != _generation) {
        return;
      }
      _resultsQuery = query;
      _set(results, ListState.success(found, hasReachedEnd: true));
    } on AppError catch (error) {
      if (generation != _generation) {
        return;
      }
      _set(results, ListState.error(error, kept));
    }
  }

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (!_stopped) {
      notifier.value = value;
    }
  }
}
