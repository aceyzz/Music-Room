import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';

/// The signed-in user's own profile, for what every tab shows of it (the
/// picture and name in the top bar).
///
/// Global, unlike ProfileStore (see the note in globals/app_router.dart): it
/// is built in main.dart next to [SessionStore] and follows it. The session
/// knows the name but not the picture, which only GetUserProfile returns.
///
/// Best effort: a failed load leaves [profile] null and the bar falls back to
/// the session's name and initials. The profile page pushes every profile it
/// loads or saves through [update], so opening it is also the retry.
class CurrentUserStore {
  final UserApi _users;
  final SessionStore _session;

  final ValueNotifier<UserProfile?> profile = ValueNotifier(null);

  /// Whose profile is loaded or loading, so a session change for the same
  /// user (email verified, token refreshed) does not refetch.
  String? _loadedFor;

  /// Set by [stop]: writing to a disposed notifier throws.
  bool _stopped = false;

  CurrentUserStore(this._users, this._session);

  void start() {
    _session.state.addListener(_onSession);
    _onSession();
  }

  void stop() {
    _stopped = true;
    _session.state.removeListener(_onSession);
    profile.dispose();
  }

  void update(UserProfile next) {
    if (!_stopped && next.publicId == _currentUserId) {
      profile.value = next;
    }
  }

  /// Only once the email is verified: until then the user is held on the
  /// verification page, which shows no profile.
  String? get _currentUserId => switch (_session.state.value) {
        SignedIn(:final user) when user.emailVerified => user.publicId,
        _ => null,
      };

  void _onSession() {
    final userId = _currentUserId;
    if (userId == _loadedFor) {
      return;
    }
    _loadedFor = userId;
    profile.value = null;
    if (userId != null) {
      _load(userId);
    }
  }

  Future<void> _load(String userId) async {
    try {
      final loaded = await _users.getProfile(userId);
      // Dropped if the user signed out (or someone else signed in) meanwhile.
      if (!_stopped && _loadedFor == userId) {
        profile.value = loaded;
      }
    } on AppError {
      // Best effort, see the class comment.
    }
  }
}
