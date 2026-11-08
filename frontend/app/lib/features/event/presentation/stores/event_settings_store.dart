import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/user/data/user_source.dart';

/// An event's settings page: who can find it, who can vote, and its people,
/// as they are now and as its host and admins change them.
///
/// Page-level (built and stopped by EventSettingsPage). Each change is sent,
/// then what it changed is read back. The changes throw the server's
/// AppError for the page to show, leaving the state as it was.
class EventSettingsStore {
  final EventInfoApi _info;
  final EventSettingsApi _api;
  final SocialApi _social;
  final String _eventPublicId;
  final String _userPublicId;

  final ValueNotifier<ItemState<EventSummary>> event = ValueNotifier(ItemState.initial());
  final ValueNotifier<ListState<EventMember>> members = ValueNotifier(ListState.initial());

  bool _stopped = false;

  EventSettingsStore(this._info, this._api, this._social, this._eventPublicId, this._userPublicId);

  /// The signed-in user's role (owner | admin | editor | viewer, the host
  /// being the owner); empty while the members load, and for someone who
  /// sees a public event without being in it.
  String get myRole =>
      members.value.data?.where((m) => m.publicId == _userPublicId).firstOrNull?.role ?? '';

  /// Who can find it, who can vote. The host only: the app shows host and
  /// invited, nothing in between, so an admin (which the app never sets) is
  /// treated as invited.
  bool get canManage => myRole == 'owner';

  bool get canInvite => canManage || myRole == 'editor';

  bool get canEnd => myRole == 'owner';

  Future<void> start() => refresh();

  void stop() {
    _stopped = true;
    event.dispose();
    members.dispose();
  }

  Future<void> refresh() => Future.wait([_loadEvent(), _loadMembers()]);

  Future<void> setVisibility(EventVisibility visibility) async {
    await _api.setVisibility(_eventPublicId, _userPublicId, visibility);
    await _loadEvent();
  }

  Future<void> setVoteLicense(VoteLicense license) async {
    await _api.setVoteLicense(_eventPublicId, _userPublicId, license);
    await _loadEvent();
  }

  /// Only people within [venue] can vote, while the event runs: the window is
  /// its planned times (voteWindowFor). Throws [StateError] for an event
  /// with no times, which the page does not offer it for.
  Future<void> setPlaceAndTime(EventVenue venue) async {
    final current = event.value.data;
    final window = voteWindowFor(current?.startsAt, current?.endsAt);
    if (window == null) {
      throw StateError('a place-and-time licence needs the event\'s times');
    }
    await _api.setPlaceAndTime(_eventPublicId, _userPublicId, venue, window);
    await _loadEvent();
  }

  /// The signed-in user's friends who are not in the event yet.
  Future<List<FriendSummary>> invitableFriends() async {
    final friends = await _social.friends(_userPublicId);
    final inside = {for (final m in members.value.data ?? const <EventMember>[]) m.publicId};
    return [
      for (final f in friends)
        if (!inside.contains(f.publicId)) f
    ];
  }

  Future<void> invite(FriendSummary friend) async {
    await _api.invite(_eventPublicId, _userPublicId, friend.publicId);
    await _loadMembers();
  }

  /// Ends it for everyone, whether it started or not.
  Future<void> end() => _api.end(_eventPublicId);

  Future<void> _loadEvent() async {
    _set(event, ItemState.loading(event.value.data));
    try {
      _set(event, ItemState.success(await _info.event(_eventPublicId, _userPublicId)));
    } on AppError catch (error) {
      _set(event, ItemState.error(error, event.value.data));
    }
  }

  Future<void> _loadMembers() async {
    _set(members, ListState.loading(members.value.data));
    try {
      final loaded = await _info.members(_eventPublicId, _userPublicId);
      _set(members, ListState.success(loaded, hasReachedEnd: true));
    } on AppError catch (error) {
      _set(members, ListState.error(error, members.value.data));
    }
  }

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (!_stopped) {
      notifier.value = value;
    }
  }
}
