import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// The form header used across authentication screens (login, register,
/// reset password, verify email): an icon or branded tile, a title, and an
/// optional explanatory subtitle.
class AppWordmark extends StatelessWidget {
  /// The main heading text (defaults to 'music-room').
  final String title;

  /// Optional line under the title ("Create your account", instructions, etc.).
  final String? subtitle;

  /// An optional custom icon widget (e.g. email verification icon).
  /// If null, renders the branded tile with [iconData].
  final Widget? icon;

  /// An optional icon for the branded tile (defaults to [Icons.music_note_rounded]).
  final IconData? iconData;

  /// Spacing between the icon and the title.
  final double iconSpacing;

  const AppWordmark({
    super.key,
    this.title = 'music-room',
    this.subtitle,
    this.icon,
    this.iconData,
    this.iconSpacing = AppDimens.spacingM,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final Widget iconWidget = icon ??
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: colorScheme.shadow.withValues(alpha: 0.1),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Icon(
            iconData ?? Icons.music_note_rounded,
            size: 44,
            color: colorScheme.onPrimaryContainer,
          ),
        );

    return Column(
      children: [
        iconWidget,
        SizedBox(height: iconSpacing),
        Text(
          title,
          style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        if (subtitle != null) ...[
          const SizedBox(height: AppDimens.spacingXS),
          Text(
            subtitle!,
            style: theme.textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}
