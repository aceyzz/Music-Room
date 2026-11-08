import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';

import 'fake_playlist_editor_api.dart';

/// In-memory [PlaylistSettingsApi] over a [FakePlaylistEditorApi]'s playlist,
/// so a change made here shows in what the editor fake answers. [calls]
/// records what was asked ("rename Trip", "invite u-3"); [failure] is
/// thrown by every change while set.
class FakePlaylistSettingsApi implements PlaylistSettingsApi {
  final FakePlaylistEditorApi playlist;
  List<PlaylistMember> people;
  final List<String> calls = [];
  AppError? failure;
  bool deleted = false;

  FakePlaylistSettingsApi(this.playlist, {this.people = const []});

  void _change(String call) {
    calls.add(call);
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  Future<List<PlaylistMember>> members(String publicId, String userPublicId) async => people;

  @override
  Future<void> rename(String publicId, String name) async {
    _change('rename $name');
    playlist.name = name;
  }

  @override
  Future<void> setVisibility(String publicId, PlaylistVisibility visibility) async {
    _change('visibility ${visibility.wire}');
    playlist.visibility = visibility;
  }

  @override
  Future<void> setEditLicense(String publicId, EditLicense license) async {
    _change('license ${license.wire}');
    playlist.editLicense = license;
  }

  @override
  Future<void> invite(String publicId, String userPublicId, String inviteePublicId) async {
    _change('invite $inviteePublicId');
    people = [
      ...people,
      PlaylistMember(
          publicId: inviteePublicId, displayName: inviteePublicId, role: PlaylistRole.editor),
    ];
  }

  @override
  Future<void> delete(String publicId) async {
    _change('delete');
    deleted = true;
  }
}
