import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/event/data/event_source.dart';

/// The Events tab: the signed-in user's events, loaded once.
///
/// Page-level (built and stopped by EventsPage, see the note in
/// globals/app_router.dart). Which pill is selected is not kept here: it is
/// EventsPage's state, and each pill is [EventFilter.pick] over [events] as
/// of now, so an event moves from Upcoming to Current without a reload.
class MyEventsStore {
  final EventApi _api;
  final String _userPublicId;

  final ValueNotifier<ListState<EventSummary>> events = ValueNotifier(ListState.initial());

  /// Set by [stop]. A request can outlive the page, and writing to a disposed
  /// notifier throws.
  bool _stopped = false;

  MyEventsStore(this._api, this._userPublicId);

  Future<void> start() => reload();

  void stop() {
    _stopped = true;
    events.dispose();
  }

  Future<void> reload() async {
    _set(ListState.loading(events.value.data));
    try {
      _set(ListState.success(await _api.myEvents(_userPublicId), hasReachedEnd: true));
    } on AppError catch (error) {
      _set(ListState.error(error, events.value.data));
    }
  }

  /// Creates an event and adds it to [events]. Throws the server's
  /// [AppError], leaving the list as it was.
  ///
  /// Unlike a new playlist, it stays after a reload: GetMusicEvents lists the
  /// events the user hosts, and this is one.
  Future<EventSummary> create({
    required String name,
    required String description,
    required EventVisibility visibility,
    required VoteLicense voteLicense,
    required DateTime startsAt,
    required DateTime endsAt,
    EventVenue? venue,
  }) async {
    final created = await _api.createEvent(
      _userPublicId,
      name: name,
      description: description,
      visibility: visibility,
      voteLicense: voteLicense,
      startsAt: startsAt,
      endsAt: endsAt,
      venue: venue,
    );
    _set(ListState.success([created, ...?events.value.data], hasReachedEnd: true));
    return created;
  }

  void _set(ListState<EventSummary> next) {
    if (!_stopped) {
      events.value = next;
    }
  }
}
