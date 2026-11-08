import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/globals/app_router.dart';

/// The Home friends row, Instagram-style: "Manage friends" first, then
/// friends as circles with their name underneath, scrolling sideways.
///
/// At most [maxShown] friends; past that a last "View all" circle leads to the
/// same friends list as "Manage friends".
class FriendsBar extends StatelessWidget {
  final List<FriendSummary> friends;

  /// Called when the user comes back from a friend's profile or the friends
  /// page, where they may have removed, blocked or accepted someone: the row
  /// should show who their friends are now.
  final VoidCallback? onReturn;

  static const maxShown = 20;
  static const height = 92.0;

  const FriendsBar({super.key, required this.friends, this.onReturn});

  @override
  Widget build(BuildContext context) {
    final shown = friends.take(maxShown).toList();
    final items = <Widget>[
      _ActionCircle(
        icon: Icons.manage_accounts_outlined,
        label: 'Manage',
        semanticsLabel: 'Manage friends',
        onTap: () => _openFriends(context),
      ),
      for (final friend in shown) _FriendCircle(friend: friend, onReturn: onReturn),
      if (friends.length > maxShown)
        _ActionCircle(
          icon: Icons.arrow_forward,
          label: 'View all',
          semanticsLabel: 'View all friends',
          onTap: () => _openFriends(context),
        ),
      if (friends.isEmpty) const _NoFriendsHint(),
    ];
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (_, i) => items[i],
      ),
    );
  }

  Future<void> _openFriends(BuildContext context) async {
    await context.push(friendsRoute);
    onReturn?.call();
  }
}

const _circleRadius = 28.0;

/// A circle with a label underneath, the shape every item of the row has.
class _Labelled extends StatelessWidget {
  final Widget circle;
  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  const _Labelled({
    required this.circle,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(_circleRadius + 4),
        onTap: onTap,
        child: SizedBox(
          width: _circleRadius * 2 + 8,
          child: Column(
            children: [
              circle,
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FriendCircle extends StatelessWidget {
  final FriendSummary friend;
  final VoidCallback? onReturn;

  const _FriendCircle({required this.friend, this.onReturn});

  @override
  Widget build(BuildContext context) {
    return _Labelled(
      circle: UserAvatar(url: friend.avatarUrl, name: friend.displayName, radius: _circleRadius),
      label: friend.displayName,
      semanticsLabel: friend.displayName,
      onTap: () async {
        await context.push(userPath(friend.publicId));
        onReturn?.call();
      },
    );
  }
}

class _ActionCircle extends StatelessWidget {
  final IconData icon;
  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  const _ActionCircle({
    required this.icon,
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _Labelled(
      circle: CircleAvatar(
        radius: _circleRadius,
        backgroundColor: scheme.secondaryContainer,
        foregroundColor: scheme.onSecondaryContainer,
        child: Icon(icon),
      ),
      label: label,
      semanticsLabel: semanticsLabel,
      onTap: onTap,
    );
  }
}

class _NoFriendsHint extends StatelessWidget {
  const _NoFriendsHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Text(
          'Add friends to see them here.',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
