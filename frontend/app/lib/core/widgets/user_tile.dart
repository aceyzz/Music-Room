import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/user_avatar.dart';

/// A standard list tile or card representing a user.
///
/// If [actions] is provided, renders the actions on a line under the name
/// to avoid cramped layout on narrow phone screens.
class UserTile extends StatelessWidget {
  final String name;
  final String? avatarUrl;
  final String? subtitle;
  final Widget? trailing;
  final Widget? actions;
  final EdgeInsetsGeometry? contentPadding;
  final VoidCallback? onTap;

  const UserTile({
    super.key,
    required this.name,
    this.avatarUrl,
    this.subtitle,
    this.trailing,
    this.actions,
    this.contentPadding,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    final actions = this.actions;
    if (actions == null) {
      return ListTile(
        contentPadding: contentPadding,
        leading: UserAvatar(url: avatarUrl, name: name),
        title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: trailing,
        onTap: onTap,
      );
    }

    // Not a ListTile: its height is capped at two lines of text, and a row of
    // buttons under them overflows it and paints over the name. Under the
    // name, not beside it: two buttons on the right left the name a column
    // one letter wide on a phone.
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: contentPadding ??
            const EdgeInsets.symmetric(
              horizontal: AppDimens.spacingM,
              vertical: AppDimens.spacingS,
            ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatar(url: avatarUrl, name: name),
            const SizedBox(width: AppDimens.spacingM),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: theme.textTheme.bodyLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  const SizedBox(height: 8),
                  actions,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
