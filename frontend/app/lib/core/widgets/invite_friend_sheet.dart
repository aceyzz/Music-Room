import 'package:flutter/material.dart';

import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/user_tile.dart';

/// The friends who can be invited to a playlist or an event; picking one
/// closes the sheet with them (showModalBottomSheet's result).
class InviteFriendSheet extends StatelessWidget {
  final List<FriendSummary> friends;

  const InviteFriendSheet({super.key, required this.friends});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.spacingM,
              0,
              AppDimens.spacingM,
              AppDimens.spacingXS,
            ),
            child: Text('Invite a friend', style: Theme.of(context).textTheme.titleMedium),
          ),
          if (friends.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppDimens.spacingM,
                AppDimens.spacingXS,
                AppDimens.spacingM,
                AppDimens.spacingL,
              ),
              child: Text('All your friends are already in it, or you have none yet.'),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final friend in friends)
                    UserTile(
                      avatarUrl: friend.avatarUrl,
                      name: friend.displayName,
                      onTap: () => Navigator.of(context).pop(friend),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
