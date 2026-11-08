import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/widgets/entity_badges.dart';
import 'package:app/core/widgets/inline_loader.dart';
import 'package:app/core/widgets/section_header.dart';
import 'package:app/core/widgets/user_tile.dart';
import 'package:app/globals/app_router.dart';

/// The standard members list displayed in event and playlist settings pages.
class SettingsMembersSection<T> extends StatelessWidget {
  final List<T>? members;
  final bool hasError;
  final String currentUserId;
  final bool canInvite;
  final VoidCallback? onInvite;
  final String Function(T member) displayName;
  final String? Function(T member) avatarUrl;
  final String? Function(T member) publicId;
  final String Function(T member) roleLabel;

  /// Draws the list itself when given, from [members] and the section's own
  /// row ([tile], with a control on the right and the role under the name
  /// when there is one): the event's music-control switches.
  final Widget Function(List<T> members, Widget Function(T member, Widget? control) tile)? list;

  const SettingsMembersSection({
    super.key,
    required this.members,
    required this.hasError,
    required this.currentUserId,
    required this.canInvite,
    required this.onInvite,
    required this.displayName,
    required this.avatarUrl,
    required this.publicId,
    required this.roleLabel,
    this.list,
  });

  Widget _tile(BuildContext context, T member, Widget? control) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final me = publicId(member) == currentUserId;
    return UserTile(
      contentPadding: EdgeInsets.zero,
      avatarUrl: avatarUrl(member),
      name: me ? '${displayName(member)} (you)' : displayName(member),
      subtitle: control == null ? null : roleLabel(member),
      onTap: me || publicId(member) == null ? null : () => context.push(userPath(publicId(member)!)),
      trailing: control ?? EntityBadge(label: roleLabel(member), textStyle: hint),
    );
  }

  @override
  Widget build(BuildContext context) {
    final members = this.members;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          padding: EdgeInsets.zero,
          title: 'Invited people',
          count: members?.length,
          trailing: canInvite
              ? TextButton.icon(
                  onPressed: onInvite,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('Invite'),
                )
              : null,
        ),
        if (members == null)
          InlineLoader(hasError: hasError)
        else if (list case final list?)
          list(members, (member, control) => _tile(context, member, control))
        else
          for (final member in members) _tile(context, member, null),
      ],
    );
  }
}
