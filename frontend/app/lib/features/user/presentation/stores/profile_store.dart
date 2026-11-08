import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/user/data/avatar_image.dart';
import 'package:app/features/user/data/user_source.dart';

/// The signed-in user's own profile, for the profile page.
///
/// Page-level (built and stopped by ProfilePage, see the note in
/// globals/app_router.dart): reopening the page refetches instead of showing
/// what was loaded last time.
///
/// [start] reports failure through [state], since there is no action to
/// attach an error to; the edit methods throw [AppError] and leave [state]
/// as it was, like SessionStore, so the page can show the error where the
/// user acted.
class ProfileStore {
  final UserApi _users;
  final String _userPublicId;

  final ValueNotifier<ItemState<UserProfile>> state = ValueNotifier(ItemState.initial());

  /// Set by [stop]. A request can outlive the page (back pressed during a
  /// save), and writing to a disposed notifier throws.
  bool _stopped = false;

  /// Called with every profile loaded or saved here, so the rest of the app
  /// (CurrentUserStore, the top bar) sees a new picture without refetching.
  final void Function(UserProfile profile)? onChanged;

  ProfileStore(this._users, this._userPublicId, {this.onChanged});

  UserProfile? get profile => state.value.data;

  Future<void> start() => reload();

  void stop() {
    _stopped = true;
    state.dispose();
  }

  void _set(ItemState<UserProfile> next) {
    if (!_stopped) {
      state.value = next;
    }
    // Even after stop: a save that finishes once the page is closed still
    // happened on the server.
    final loaded = next.data;
    if (!next.isLoading && !next.hasError && loaded != null) {
      onChanged?.call(loaded);
    }
  }

  Future<void> reload() async {
    _set(ItemState.loading(profile));
    try {
      _set(ItemState.success(await _users.getProfile(_userPublicId)));
    } on AppError catch (error) {
      _set(ItemState.error(error, profile));
    }
  }

  /// Saves [update]. Build it with `clearBlanks: true` from a whole form, so
  /// a field the user emptied is cleared on the server too.
  Future<void> save(ProfileUpdate update) async {
    _set(ItemState.success(await _users.updateProfile(_userPublicId, update)));
  }

  /// Replaces the music preferences with [preferences].
  Future<void> savePreferences(List<MusicPreference> preferences) async {
    final saved = await _users.setMusicPreferences(_userPublicId, preferences);
    final current = profile;
    if (current != null) {
      _set(ItemState.success(current.withMusicPreferences(saved)));
    }
  }

  /// Checks [image] locally (format, size), then uploads it. Throws
  /// [AvatarRejectedError] without calling the server if it would be refused.
  Future<void> changeAvatar(Uint8List image) async {
    final contentType = avatarContentType(image);
    _set(ItemState.success(await _users.uploadAvatar(_userPublicId, image, contentType)));
  }

  Future<void> removeAvatar() async {
    _set(ItemState.success(await _users.deleteAvatar(_userPublicId)));
  }
}
