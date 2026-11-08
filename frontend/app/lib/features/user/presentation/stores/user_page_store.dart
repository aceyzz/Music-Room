import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/relationship.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/user/data/user_source.dart';

/// Someone's profile page: their profile as the viewer may see it, and where
/// the viewer stands with them.
///
/// Page-level (built and stopped by UserPage, see the note in
/// globals/app_router.dart).
///
/// The two load and fail separately, and that is the point: once a block
/// exists the server refuses the profile but still answers the relationship,
/// which is what lets the page offer Unblock.
///
/// The actions throw [AppError] to the page, which shows it where the user
/// acted, and leave the state as it was. After each one both parts are read
/// again rather than patched locally: a friendship or a block changes which
/// profile fields come back, which only the server knows.
class UserPageStore {
  final SocialApi _api;
  final String _viewerPublicId;
  final String _targetPublicId;

  final ValueNotifier<ItemState<UserProfile>> profile = ValueNotifier(ItemState.initial());
  final ValueNotifier<ItemState<Relationship>> relationship = ValueNotifier(ItemState.initial());

  /// Set by [stop]. A request can outlive the page (back pressed during a
  /// call), and writing to a disposed notifier throws.
  bool _stopped = false;

  UserPageStore(this._api, this._viewerPublicId, this._targetPublicId);

  Future<void> start() => refresh();

  Future<void> refresh() async {
    await Future.wait([_loadProfile(), _loadRelationship()]);
  }

  void stop() {
    _stopped = true;
    profile.dispose();
    relationship.dispose();
  }

  Future<void> addFriend() => _act(() => _api.sendFriendRequest(_viewerPublicId, _targetPublicId));

  Future<void> acceptRequest() =>
      _act(() => _api.acceptFriendRequest(_viewerPublicId, _incomingRequestId()));

  Future<void> declineRequest() =>
      _act(() => _api.declineFriendRequest(_viewerPublicId, _incomingRequestId()));

  Future<void> removeFriend() => _act(() => _api.removeFriend(_viewerPublicId, _targetPublicId));

  Future<void> block() => _act(() => _api.block(_viewerPublicId, _targetPublicId));

  Future<void> unblock() => _act(() => _api.unblock(_viewerPublicId, _targetPublicId));

  /// The page only offers Accept and Decline when there is one.
  int _incomingRequestId() => relationship.value.data!.incomingRequestId!;

  Future<void> _act(Future<void> Function() call) async {
    await call();
    await refresh();
  }

  Future<void> _loadProfile() async {
    _set(profile, ItemState.loading(profile.value.data));
    try {
      _set(profile, ItemState.success(await _api.viewProfile(_viewerPublicId, _targetPublicId)));
    } on AppError catch (error) {
      // No stale data kept: a profile that was visible before a block must
      // not stay on screen after it.
      _set(profile, ItemState<UserProfile>.error(error, null));
    }
  }

  Future<void> _loadRelationship() async {
    _set(relationship, ItemState.loading(relationship.value.data));
    try {
      _set(
        relationship,
        ItemState.success(await _api.relationship(_viewerPublicId, _targetPublicId)),
      );
    } on AppError catch (error) {
      _set(relationship, ItemState.error(error, relationship.value.data));
    }
  }

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (!_stopped) {
      notifier.value = value;
    }
  }
}
