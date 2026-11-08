import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/user/data/user_source.dart';

/// The Home tab's three sections: the signed-in user's events, friends, and
/// recent playlists.
///
/// Page-level (built and stopped by HomePage, see the note in
/// globals/app_router.dart). Each section loads and fails on its own, so a
/// friends call that fails does not hide the events; each has its own retry.
class HomeStore {
  final EventApi _events;
  final UserApi _users;
  final PlaylistApi _playlists;
  final String _userPublicId;

  /// Where "now" is when sorting events into past and upcoming. A parameter
  /// so tests can pin it.
  final DateTime Function() _now;

  /// How many playlists the Home row shows.
  static const playlistCount = 5;

  final ValueNotifier<ItemState<EventTimeline>> events = ValueNotifier(ItemState.initial());
  final ValueNotifier<ListState<FriendSummary>> friends = ValueNotifier(ListState.initial());
  final ValueNotifier<ListState<PlaylistSummary>> playlists = ValueNotifier(ListState.initial());

  /// Set by [stop]. A request can outlive the page, and writing to a disposed
  /// notifier throws.
  bool _stopped = false;

  HomeStore(
    this._events,
    this._users,
    this._playlists,
    this._userPublicId, {
    DateTime Function() now = DateTime.now,
  }) : _now = now;

  Future<void> start() => reload();

  void stop() {
    _stopped = true;
    events.dispose();
    friends.dispose();
    playlists.dispose();
  }

  /// All three sections, in parallel (pull-to-refresh).
  Future<void> reload() async {
    await Future.wait([reloadEvents(), reloadFriends(), reloadPlaylists()]);
  }

  Future<void> reloadEvents() async {
    _set(events, ItemState.loading(events.value.data));
    try {
      final found = await _events.myEvents(_userPublicId);
      // Yours: hosted or invited to. The Events tab lists the public ones too.
      final yours = found.where((e) => e.viewerIsMember);
      _set(events, ItemState.success(EventTimeline.from(yours, _now())));
    } on AppError catch (error) {
      _set(events, ItemState.error(error, events.value.data));
    }
  }

  Future<void> reloadFriends() => _loadList(friends, () => _users.getFriends(_userPublicId));

  Future<void> reloadPlaylists() => _loadList(
        playlists,
        () => _playlists.recentPlaylists(_userPublicId, limit: playlistCount),
      );

  Future<void> _loadList<T>(
    ValueNotifier<ListState<T>> state,
    Future<List<T>> Function() fetch,
  ) async {
    _set(state, ListState.loading(state.value.data));
    try {
      _set(state, ListState.success(await fetch(), hasReachedEnd: true));
    } on AppError catch (error) {
      _set(state, ListState.error(error, state.value.data));
    }
  }

  void _set<S>(ValueNotifier<S> state, S next) {
    if (!_stopped) {
      state.value = next;
    }
  }
}
