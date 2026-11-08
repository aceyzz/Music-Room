import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/friend_request.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/user_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/user/data/user_source.dart';

/// The friends page: searching people, and the viewer's requests, friends and
/// blocks.
///
/// Page-level (built and stopped by FriendsPage, see the note in
/// globals/app_router.dart).
///
/// The four lists load and fail separately, so a failed blocked list does not
/// hide the friends. The actions throw [AppError] to the page and then read
/// the lists they touch again rather than patching them: accepting a request
/// that was meanwhile cancelled must show the list as the server has it.
class FriendsStore {
  final SocialApi _api;
  final String _viewerPublicId;

  /// How long typing must pause before a search is sent: the same delay, and
  /// the same mechanism, as the public playlist search (LibraryStore).
  static const searchDelay = Duration(milliseconds: 300);

  /// Search results asked for. The server returns no more and has no paging,
  /// so a full list means "keep typing".
  static const searchLimit = 20;

  final ValueNotifier<ListState<FriendSummary>> friends = ValueNotifier(ListState.initial());
  final ValueNotifier<ListState<FriendRequest>> incoming = ValueNotifier(ListState.initial());
  final ValueNotifier<ListState<FriendRequest>> outgoing = ValueNotifier(ListState.initial());
  final ValueNotifier<ListState<UserSummary>> blocked = ValueNotifier(ListState.initial());
  final ValueNotifier<ListState<UserSummary>> results = ValueNotifier(ListState.initial());

  /// What the search field holds, trimmed. Empty means the page shows its
  /// lists instead of results.
  String get query => _query;
  String _query = '';

  /// The query [results] answers. Differs from [query] while a search is
  /// waiting or in flight.
  String get resultsQuery => _resultsQuery;
  String _resultsQuery = '';

  /// Bumped by every new search. A response carrying an older number is
  /// dropped: a slow answer to "an" must not overwrite "anna".
  int _generation = 0;

  Timer? _searchTimer;

  /// Set by [stop]. A request can outlive the page, and writing to a disposed
  /// notifier throws.
  bool _stopped = false;

  FriendsStore(this._api, this._viewerPublicId);

  Future<void> start() => refresh();

  /// Reloads the four lists; the search results stay as they are.
  Future<void> refresh() async {
    await Future.wait([reloadFriends(), reloadIncoming(), reloadOutgoing(), reloadBlocked()]);
  }

  void stop() {
    _stopped = true;
    _searchTimer?.cancel();
    friends.dispose();
    incoming.dispose();
    outgoing.dispose();
    blocked.dispose();
    results.dispose();
  }

  Future<void> reloadFriends() => _load(friends, () => _api.friends(_viewerPublicId));

  Future<void> reloadIncoming() =>
      _load(incoming, () => _api.friendRequests(_viewerPublicId, incoming: true));

  Future<void> reloadOutgoing() =>
      _load(outgoing, () => _api.friendRequests(_viewerPublicId, incoming: false));

  Future<void> reloadBlocked() => _load(blocked, () => _api.blockedUsers(_viewerPublicId));

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
      _set(results, ListState<UserSummary>.initial());
      return;
    }
    _searchTimer = Timer(searchDelay, reloadResults);
  }

  /// Runs the search for [query] now. Results for another query are cleared
  /// rather than shown under the new one while it loads.
  Future<void> reloadResults() async {
    _searchTimer?.cancel();
    final generation = ++_generation;
    final query = _query;
    if (query.isEmpty) {
      return;
    }
    final kept = query == _resultsQuery ? results.value.data : null;
    _set(results, ListState.loading(kept));
    try {
      final found = await _api.searchUsers(_viewerPublicId, query, limit: searchLimit);
      if (generation != _generation) {
        return;
      }
      _resultsQuery = query;
      _set(results, ListState.success(found, hasReachedEnd: found.length < searchLimit));
    } on AppError catch (error) {
      if (generation != _generation) {
        return;
      }
      _set(results, ListState.error(error, kept));
    }
  }

  Future<void> accept(FriendRequest request) async {
    try {
      await _api.acceptFriendRequest(_viewerPublicId, request.id);
    } finally {
      await Future.wait([reloadIncoming(), reloadFriends()]);
    }
  }

  Future<void> decline(FriendRequest request) async {
    try {
      await _api.declineFriendRequest(_viewerPublicId, request.id);
    } finally {
      await reloadIncoming();
    }
  }

  Future<void> unblock(UserSummary user) async {
    try {
      await _api.unblock(_viewerPublicId, user.publicId);
    } finally {
      await reloadBlocked();
    }
  }

  Future<void> _load<T>(
    ValueNotifier<ListState<T>> list,
    Future<List<T>> Function() fetch,
  ) async {
    _set(list, ListState.loading(list.value.data));
    try {
      _set(list, ListState.success(await fetch(), hasReachedEnd: true));
    } on AppError catch (error) {
      _set(list, ListState.error(error, list.value.data));
    }
  }

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (!_stopped) {
      notifier.value = value;
    }
  }
}
