import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/danger_action_button.dart';
import 'package:app/core/widgets/invite_friend_sheet.dart';
import 'package:app/core/widgets/settings_members_section.dart';
import 'package:app/core/widgets/text_input_dialog.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/playlist/presentation/stores/playlist_settings_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/globals/app_router.dart';

/// A playlist's settings (`/playlists/:id/settings`), opened from its page:
/// its name, who can see it, who can edit its songs, and its people.
///
/// Everyone who can open the playlist sees all of it; the controls follow
/// the signed-in user's role (PlaylistRole): the owner changes the settings
/// and deletes, the people invited may invite too. The server checks each
/// change again.
///
/// Pops with true once the playlist is deleted, so its page closes as well.
class PlaylistSettingsPage extends StatefulWidget {
  final String publicId;

  const PlaylistSettingsPage({super.key, required this.publicId});

  @override
  State<PlaylistSettingsPage> createState() => _PlaylistSettingsPageState();
}

class _PlaylistSettingsPageState extends State<PlaylistSettingsPage>
    with BusyState<PlaylistSettingsPage> {
  late final PlaylistSettingsStore _store;
  late final String _userPublicId;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    _userPublicId = context.currentUserId;
    _store = PlaylistSettingsStore(
      context.read<PlaylistEditorApi>(),
      context.read<PlaylistSettingsApi>(),
      context.read<SocialApi>(),
      widget.publicId,
      _userPublicId,
    )..start();
  }

  @override
  void dispose() {
    _store.stop();
    super.dispose();
  }

  Future<void> _rename(String current) async {
    final name = await showTextInputDialog(
      context,
      title: 'Rename playlist',
      initial: current,
      confirmLabel: 'Rename',
    );
    if (name != null && name.trim().isNotEmpty && name.trim() != current) {
      await run(() => _store.rename(name), message: _errorMessage);
    }
  }

  Future<void> _invite() async {
    final List<FriendSummary> friends;
    try {
      friends = await _store.invitableFriends();
    } on AppError catch (error) {
      showError(_errorMessage(error));
      return;
    }
    if (!mounted) {
      return;
    }
    final picked = await showModalBottomSheet<FriendSummary>(
      context: context,
      showDragHandle: true,
      builder: (context) => InviteFriendSheet(friends: friends),
    );
    if (picked != null && await run(() => _store.invite(picked), message: _errorMessage)) {
      showInfo('${picked.displayName} is in the playlist now.');
    }
  }

  Future<void> _delete(String name) async {
    final sure = await showConfirmDialog(
      context,
      title: 'Delete $name?',
      content: 'It disappears for everyone in it. This cannot be undone.',
      confirmLabel: 'Delete',
    );
    if (sure && await run(_store.delete, message: _errorMessage) && mounted) {
      // Opened from its page, which closes too; reached directly (a link),
      // the playlists list is what is left.
      context.canPop() ? context.pop(true) : context.go(playlistsRoute);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Playlist settings')),
      body: ListenableBuilder(
        listenable: Listenable.merge([_store.details, _store.members]),
        builder: (context, _) {
          final details = _store.details.value;
          final playlist = details.data;
          if (playlist == null) {
            return details.hasError
                ? Center(
                    child: TextButton(onPressed: _store.refresh, child: const Text('Try again')),
                  )
                : const Center(child: CircularProgressIndicator());
          }
          return RefreshIndicator(
            onRefresh: _store.refresh,
            child: _settings(playlist, _store.myRole),
          );
        },
      ),
    );
  }

  Widget _settings(PlaylistDetails playlist, PlaylistRole role) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final manage = role.canManage && !busy;
    final members = _store.members.value.data;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: AppDimens.settingsPagePadding,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Name'),
          subtitle: Text(playlist.name),
          trailing: role.canManage ? const Icon(Icons.edit_outlined) : null,
          onTap: manage ? () => _rename(playlist.name) : null,
        ),
        const SizedBox(height: AppDimens.spacingXS),
        _PlaylistVisibilitySection(
          visibility: playlist.visibility,
          enabled: manage,
          onChanged: (v) => run(() => _store.setVisibility(v), message: _errorMessage),
        ),
        const SizedBox(height: AppDimens.spacingM),
        _PlaylistEditLicenseSection(
          editLicense: playlist.editLicense,
          enabled: manage,
          onChanged: (l) => run(() => _store.setEditLicense(l), message: _errorMessage),
        ),
        if (!role.canManage) ...[
          const SizedBox(height: AppDimens.spacingXXS),
          Text('Only its owner can change these.', style: hint),
        ],
        const SizedBox(height: AppDimens.spacingL),
        SettingsMembersSection<PlaylistMember>(
          members: members,
          hasError: _store.members.value.hasError,
          currentUserId: _userPublicId,
          canInvite: role.canInvite,
          onInvite: busy ? null : _invite,
          displayName: (m) => m.displayName,
          avatarUrl: (m) => m.avatarUrl,
          publicId: (m) => m.publicId,
          roleLabel: (m) => m.role == PlaylistRole.owner ? 'Owner' : 'Invited',
        ),
        if (role.canDelete)
          DangerActionButton(
            icon: Icons.delete_outline,
            label: 'Delete playlist',
            onPressed: busy ? null : () => _delete(playlist.name),
          ),
      ],
    );
  }
}

class _PlaylistVisibilitySection extends StatelessWidget {
  final PlaylistVisibility visibility;
  final bool enabled;
  final ValueChanged<PlaylistVisibility> onChanged;

  const _PlaylistVisibilitySection({
    required this.visibility,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Who can see it', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppDimens.spacingXS),
        SegmentedButton<PlaylistVisibility>(
          segments: [
            for (final v in PlaylistVisibility.values)
              ButtonSegment(value: v, label: Text(v.label)),
          ],
          selected: {visibility},
          onSelectionChanged: enabled ? (picked) => onChanged(picked.single) : null,
        ),
        const SizedBox(height: AppDimens.spacingXXS),
        Text(visibility.description, style: hint),
      ],
    );
  }
}

class _PlaylistEditLicenseSection extends StatelessWidget {
  final EditLicense editLicense;
  final bool enabled;
  final ValueChanged<EditLicense> onChanged;

  const _PlaylistEditLicenseSection({
    required this.editLicense,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Who can edit songs', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppDimens.spacingXS),
        SegmentedButton<EditLicense>(
          segments: [
            for (final l in EditLicense.values) ButtonSegment(value: l, label: Text(l.label)),
          ],
          selected: {editLicense},
          onSelectionChanged: enabled ? (picked) => onChanged(picked.single) : null,
        ),
        const SizedBox(height: AppDimens.spacingXXS),
        Text(editLicense.description, style: hint),
      ],
    );
  }
}

String _errorMessage(AppError error) => switch (error) {
      UnauthorizedError() => "You can't change this playlist.",
      NotFoundError() => 'This playlist or this person no longer exists.',
      NetworkError() => 'Cannot reach the server. Check your connection.',
      _ => 'Something went wrong. Please try again.',
    };
