import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/relationship.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/action_button.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/load_failed_view.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/stores/user_page_store.dart';
import 'package:app/globals/app_router.dart';

/// Someone's profile (`/users/:id`): their picture, name and the details they
/// share with the viewer, and the friend and block actions that fit where the
/// viewer stands with them.
///
/// One page for every relationship, so any list of people can link here:
///
/// | relationship      | actions                         |
/// | ----------------- | ------------------------------- |
/// | the viewer        | Edit profile                    |
/// | none              | Add as friend, Block            |
/// | request sent      | Request sent (disabled), Block  |
/// | request received  | Accept, Decline, Block          |
/// | friends           | Remove friend, Block            |
/// | blocked by viewer | Unblock                         |
/// | unavailable       | Block                           |
///
/// "Unavailable" is a refused profile with no block of the viewer's: the
/// account is gone, or its owner blocked the viewer. The page does not say
/// which, on purpose (docs/permissions.md §5).
class UserPage extends StatefulWidget {
  final String publicId;

  const UserPage({super.key, required this.publicId});

  @override
  State<UserPage> createState() => _UserPageState();
}

/// The action in flight, so its own button shows the spinner.
enum _Action { add, accept, decline, remove, block, unblock }

class _UserPageState extends State<UserPage> with BusyState<UserPage> {
  late final UserPageStore _store;
  _Action? _running;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    _store = UserPageStore(context.read<SocialApi>(), context.currentUserId, widget.publicId)..start();
  }

  @override
  void dispose() {
    _store.stop();
    super.dispose();
  }

  Future<void> _do(_Action action, Future<void> Function() call) async {
    setState(() => _running = action);
    final done = await run(call, message: (error) => _errorMessage(error, action));
    if (mounted) {
      setState(() => _running = null);
    }
    // A refusal usually means the page was out of date (they answered, or
    // blocked, in the meantime): show where things stand now.
    if (!done && mounted) {
      await _store.refresh();
    }
  }

  Future<void> _removeFriend(String name) async {
    final sure = await showConfirmDialog(
      context,
      title: 'Remove $name as a friend?',
      content: 'They will no longer see what you share with friends, and any control over '
          'music you gave each other is taken back.',
      confirmLabel: 'Remove',
    );
    if (sure) {
      await _do(_Action.remove, _store.removeFriend);
    }
  }

  Future<void> _block(String? name) async {
    final who = name ?? 'this user';
    final sure = await showConfirmDialog(
      context,
      title: 'Block $who?',
      content: 'You will stop being friends, any pending friend request is cancelled, and any '
          'control over music you gave each other is taken back. Neither of you will see '
          'the other\'s profile, and they cannot send you requests or invitations.',
      confirmLabel: 'Block',
    );
    if (sure) {
      await _do(_Action.block, _store.block);
    }
  }


  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_store.profile, _store.relationship]),
      builder: (context, _) {
        final profileState = _store.profile.value;
        final relationshipState = _store.relationship.value;
        final profile = profileState.data;
        final relationship = relationshipState.data;
        final name = profile?.displayName ?? relationship?.displayName;
        return Scaffold(
          appBar: AppBar(title: Text(name ?? 'Profile')),
          body: switch (relationship) {
            null when relationshipState.hasError => LoadFailedView(
              message: 'This profile could not be loaded.',
              onRetry: _store.refresh,
              buttonType: RetryButtonType.tonal,
            ),
            null => const Center(child: CircularProgressIndicator()),
            final relationship => RefreshIndicator(
                onRefresh: _store.refresh,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppDimens.spacingM,
                    AppDimens.spacingL,
                    AppDimens.spacingM,
                    AppDimens.spacingXL,
                  ),
                  children: _content(
                    relationship: relationship,
                    profile: profile,
                    profileError: profileState.error,
                    profileLoading: profileState.isLoading,
                    name: name,
                  ),
                ),
              ),
          },
        );
      },
    );
  }

  String? _captionFor(FriendStatus status, bool blocked, bool unavailable) =>
      switch (status) {
        _ when blocked => 'Blocked',
        _ when unavailable => 'This profile isn\'t available',
        FriendStatus.self => 'This is you',
        FriendStatus.friends => 'Friends',
        FriendStatus.requestSent => 'Friend request sent',
        FriendStatus.requestReceived => 'Wants to be your friend',
        FriendStatus.none => null,
      };

  Widget _actionButtons({
    required bool self,
    required bool blocked,
    required bool unavailable,
    required FriendStatus status,
    required String name,
  }) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: AppDimens.spacingXS,
      runSpacing: AppDimens.spacingXS,
      children: [
        if (self)
          FilledButton.tonalIcon(
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit profile'),
            onPressed: () => context.push(profileRoute),
          )
        else if (blocked)
          ActionButton.tonal(
            icon: Icons.lock_open,
            label: 'Unblock',
            busy: _running == _Action.unblock,
            onPressed: busy ? null : () => _do(_Action.unblock, _store.unblock),
          )
        else ...[
          if (!unavailable) ..._friendActions(status, name),
          ActionButton.danger(
            icon: Icons.block,
            label: 'Block',
            busy: _running == _Action.block,
            onPressed: busy ? null : () => _block(name),
          ),
        ],
      ],
    );
  }

  List<Widget> _content({
    required Relationship relationship,
    required UserProfile? profile,
    required AppError? profileError,
    required bool profileLoading,
    required String? name,
  }) {
    final blocked = relationship.blockedByMe;
    final unavailable = !blocked && profile == null && profileError is NotFoundError;
    final status = relationship.status;
    final self = status == FriendStatus.self;
    final caption = _captionFor(status, blocked, unavailable);
    final targetName = name ?? 'this user';

    return [
      _Header(
        // A blocked user's picture is not shown: the server does not send it.
        avatarUrl: blocked ? null : profile?.avatarUrl,
        name: name,
        caption: caption,
      ),
      const SizedBox(height: 20),
      _actionButtons(
        self: self,
        blocked: blocked,
        unavailable: unavailable,
        status: status,
        // "Remove them as a friend?" when the name is hidden or not loaded.
        name: name ?? 'them',
      ),
      const SizedBox(height: AppDimens.spacingL),
      if (blocked)
        _Note('You blocked $targetName. Neither of you can see the other\'s profile, '
            'and they cannot send you friend requests or invitations. Unblocking does not make '
            'you friends again.')
      else if (unavailable)
        const _Note('This account does not exist or is not available to you.')
      else if (profile != null)
        _Details(profile: profile, self: self, friends: status == FriendStatus.friends)
      else if (profileError != null)
        const _Note('Their details could not be loaded. Pull to retry.')
      else if (profileLoading)
        const Center(child: CircularProgressIndicator()),
    ];
  }

  List<Widget> _friendActions(FriendStatus status, String name) => switch (status) {
        FriendStatus.none => [
            ActionButton(
              icon: Icons.person_add_alt_1,
              label: 'Add as friend',
              busy: _running == _Action.add,
              onPressed: busy ? null : () => _do(_Action.add, _store.addFriend),
            ),
          ],
        FriendStatus.requestSent => [
            // No cancel for now (docs/todo.md §10): a request waits for an answer.
            const ActionButton(icon: Icons.schedule, label: 'Request sent', onPressed: null),
          ],
        FriendStatus.requestReceived => [
            ActionButton(
              icon: Icons.check,
              label: 'Accept',
              busy: _running == _Action.accept,
              onPressed: busy ? null : () => _do(_Action.accept, _store.acceptRequest),
            ),
            ActionButton.tonal(
              icon: Icons.close,
              label: 'Decline',
              busy: _running == _Action.decline,
              onPressed: busy ? null : () => _do(_Action.decline, _store.declineRequest),
            ),
          ],
        FriendStatus.friends => [
            ActionButton.tonal(
              icon: Icons.person_remove_outlined,
              label: 'Remove friend',
              busy: _running == _Action.remove,
              onPressed: busy ? null : () => _removeFriend(name),
            ),
          ],
        FriendStatus.self => const [],
      };
}

/// User-facing text for a failed action. The server's own strings are
/// written for developers, so they are not shown.
String _errorMessage(AppError error, _Action action) => switch ((error, action)) {
      (NetworkError(), _) => 'Cannot reach the server. Check your connection.',
      (ConflictError(), _Action.add) => 'You are already friends, or a request is waiting.',
      (NotFoundError(), _Action.accept || _Action.decline) => 'That request was already answered.',
      (NotFoundError(), _) => 'This account is no longer available.',
      (UnauthorizedError(), _Action.add) => 'You cannot send this person a friend request.',
      _ => 'Something went wrong. Please try again.',
    };

/// The big picture, the name, and one line on where the viewer stands.
class _Header extends StatelessWidget {
  final String? avatarUrl;
  final String? name;
  final String? caption;

  const _Header({required this.avatarUrl, required this.name, required this.caption});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = this.name;
    final caption = this.caption;
    return Column(
      children: [
        if (name != null)
          UserAvatar(url: avatarUrl, name: name, radius: 48)
        else
          CircleAvatar(
            radius: 48,
            backgroundColor: scheme.surfaceContainerHighest,
            foregroundColor: scheme.onSurfaceVariant,
            child: const Icon(Icons.person_outline, size: 48),
          ),
        const SizedBox(height: AppDimens.spacingS),
        if (name != null)
          Text(name, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
        if (caption != null) ...[
          const SizedBox(height: AppDimens.spacingXXS),
          Text(
            caption,
            style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}


/// What the server sent back: a field hidden from the viewer is null, the
/// same as one never filled in.
class _Details extends StatelessWidget {
  final UserProfile profile;
  final bool self;
  final bool friends;

  const _Details({required this.profile, required this.self, required this.friends});

  List<(IconData, String, String)> get _rows {
    final fullName = [profile.firstName, profile.lastName].whereType<String>().join(' ');
    final location = [profile.city, profile.countryCode].whereType<String>().join(', ');
    final birthDate = profile.birthDate;
    return [
      if (fullName.isNotEmpty) (Icons.badge_outlined, 'Name', fullName),
      if (location.isNotEmpty) (Icons.place_outlined, 'Location', location),
      if (birthDate != null)
        (Icons.cake_outlined, 'Birthday', DateFormat.yMMMMd().format(birthDate)),
      if (profile.phoneNumber case final phone?) (Icons.phone_outlined, 'Phone', phone),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bio = profile.bio;
    final rows = _rows;
    final sharesMore = !self &&
        !friends &&
        profile.visibility.values.any((scope) => scope == ProfileVisibility.friends);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bio != null) ...[
          Text(bio, style: theme.textTheme.bodyLarge),
          const SizedBox(height: AppDimens.spacingS),
        ],
        for (final (icon, label, value) in rows)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(icon),
            title: Text(value),
            subtitle: Text(label),
          ),
        if (profile.musicPreferences.isNotEmpty) ...[
          const SizedBox(height: AppDimens.spacingS),
          Text('Music preferences', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppDimens.spacingXS),
          Wrap(
            spacing: AppDimens.spacingXS,
            runSpacing: AppDimens.spacingXS,
            children: [
              for (final pref in profile.musicPreferences) Chip(label: Text(pref.genreName)),
            ],
          ),
        ],
        if (bio == null && rows.isEmpty && profile.musicPreferences.isEmpty)
          _Note(self ? 'Nothing filled in yet.' : 'Nothing shared with you yet.'),
        if (sharesMore) _Note('${profile.displayName} shares more with friends.'),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  final String text;

  const _Note(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: AppDimens.spacingXS),
        child: Text(
          text,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
}

