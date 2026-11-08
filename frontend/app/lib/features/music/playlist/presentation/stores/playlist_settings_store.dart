import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/user/data/user_source.dart';

/// A playlist's settings page: its name, who can see and edit it, and its
/// people, as they are now and as its owner changes them.
///
/// Page-level (built and stopped by PlaylistSettingsPage). Each change is
/// sent, then what it changed is read back: the server decides who may do
/// what, and its answer is what the page shows. The changes throw the
/// server's AppError for the page to show, leaving the state as it was.
class PlaylistSettingsStore {
  final PlaylistEditorApi _editor;
  final PlaylistSettingsApi _api;
  final SocialApi _social;
  final String _publicId;
  final String _userPublicId;

  final ValueNotifier<ItemState<PlaylistDetails>> details = ValueNotifier(ItemState.initial());
  final ValueNotifier<ListState<PlaylistMember>> members = ValueNotifier(ListState.initial());

  bool _stopped = false;

  PlaylistSettingsStore(
    this._editor,
    this._api,
    this._social,
    this._publicId,
    this._userPublicId,
  );

  /// The signed-in user's role: [PlaylistRole.viewer] while the members are
  /// loading, and for someone who sees a public playlist without being in it.
  PlaylistRole get myRole =>
      members.value.data?.where((m) => m.publicId == _userPublicId).firstOrNull?.role ??
      PlaylistRole.viewer;

  Future<void> start() => refresh();

  void stop() {
    _stopped = true;
    details.dispose();
    members.dispose();
  }

  Future<void> refresh() => Future.wait([_loadDetails(), _loadMembers()]);

  Future<void> rename(String name) async {
    await _api.rename(_publicId, name.trim());
    await _loadDetails();
  }

  Future<void> setVisibility(PlaylistVisibility visibility) async {
    await _api.setVisibility(_publicId, visibility);
    await _loadDetails();
  }

  Future<void> setEditLicense(EditLicense license) async {
    await _api.setEditLicense(_publicId, license);
    await _loadDetails();
  }

  /// The signed-in user's friends who are not in the playlist yet.
  Future<List<FriendSummary>> invitableFriends() async {
    final friends = await _social.friends(_userPublicId);
    final inside = {for (final m in members.value.data ?? const <PlaylistMember>[]) m.publicId};
    return [
      for (final f in friends)
        if (!inside.contains(f.publicId)) f
    ];
  }

  Future<void> invite(FriendSummary friend) async {
    await _api.invite(_publicId, _userPublicId, friend.publicId);
    await _loadMembers();
  }

  Future<void> delete() => _api.delete(_publicId);

  Future<void> _loadDetails() async {
    _set(details, ItemState.loading(details.value.data));
    try {
      final result = await _editor.openPlaylist(_publicId, _userPublicId);
      _set(details, ItemState.success(result.details));
    } on AppError catch (error) {
      _set(details, ItemState.error(error, details.value.data));
    }
  }

  Future<void> _loadMembers() async {
    _set(members, ListState.loading(members.value.data));
    try {
      _set(members,
          ListState.success(await _api.members(_publicId, _userPublicId), hasReachedEnd: true));
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
