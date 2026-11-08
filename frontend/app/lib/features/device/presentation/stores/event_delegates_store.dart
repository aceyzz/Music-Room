import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/device/control_license.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/user/data/user_source.dart';

/// One of the host's friends, and the licence that lets them control the
/// music on the event's speaker, if any.
typedef EventDelegate = ({
  FriendSummary friend,

  /// This event's licence, to revoke to take control back; null when they
  /// have none. There is no licence for every event (the server refuses one).
  int? licenseId,
});

/// The switches on the event settings' invited people (subject V.2.2): which
/// of the host's friends may control the music during this event.
///
/// The licence is on the event's speaker, the device that plays (the page
/// works it out): the server checks a delegate against it, and moves the
/// event's licences along when the host picks another (SetEventSpeaker).
///
/// Page-level, built with the section. [start] reports failure through
/// [state]; [toggle] throws [AppError] and leaves [state] as it was, so the
/// sheet shows the error where the host tapped.
class EventDelegatesStore {
  final DelegationApi _delegation;
  final SocialApi _social;
  final String _devicePublicId;
  final String _eventPublicId;
  final String _userPublicId;

  /// Run once before the first grant: with no speaker yet, it makes the
  /// device the licences name the speaker, without which the server lets
  /// only the host control (SetEventSpeaker). Null once run, or when there is
  /// a speaker.
  Future<void> Function()? _beforeGrant;

  final ValueNotifier<ItemState<List<EventDelegate>>> state = ValueNotifier(ItemState.initial());

  /// Set by [stop]: a toggle can outlive the sheet.
  bool _stopped = false;

  EventDelegatesStore(
    this._delegation,
    this._social,
    this._devicePublicId,
    this._eventPublicId,
    this._userPublicId, {
    Future<void> Function()? beforeGrant,
  }) : _beforeGrant = beforeGrant;

  Future<void> start() => reload();

  void stop() {
    _stopped = true;
    state.dispose();
  }

  void _set(ItemState<List<EventDelegate>> next) {
    if (!_stopped) {
      state.value = next;
    }
  }

  Future<void> reload() async {
    _set(ItemState.loading(state.value.data));
    try {
      final friends = await _social.friends(_userPublicId);
      final licenses = await _delegation.licenses(_devicePublicId);
      _set(ItemState.success([
        for (final friend in friends) _delegate(friend, licenses),
      ]));
    } on AppError catch (error) {
      _set(ItemState.error(error, state.value.data));
    }
  }

  EventDelegate _delegate(FriendSummary friend, List<ControlLicense> licenses) {
    final license = licenses
        .where((l) => l.granteePublicId == friend.publicId && l.eventPublicId == _eventPublicId)
        .firstOrNull;
    return (friend: friend, licenseId: license?.id);
  }

  /// Gives [delegate] control for this event, or takes back the licence they
  /// have. Refetches rather than editing the list: the licence id comes from
  /// the server.
  Future<void> toggle(EventDelegate delegate) async {
    final licenseId = delegate.licenseId;
    if (licenseId == null) {
      if (_beforeGrant case final before?) {
        await before();
        _beforeGrant = null;
      }
      await _delegation.grant(_devicePublicId, delegate.friend.publicId, _eventPublicId);
    } else {
      await _delegation.revoke(_devicePublicId, licenseId);
    }
    await reload();
  }
}
