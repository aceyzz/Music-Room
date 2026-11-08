import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// Style variant for an [EntityBadge].
enum EntityBadgeVariant {
  /// Simple inline icon and/or text with no enclosing background pill.
  inline,

  /// Enclosed in a compact rounded background pill.
  pill,
}

/// A compact badge indicating status, ownership, or visibility of an item
/// (e.g. owner star, private lock, or custom text label like "Host", "Private").
class EntityBadge extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final String? semanticLabel;
  final double? iconSize;
  final Color? color;
  final Color? backgroundColor;
  final EntityBadgeVariant variant;
  final TextStyle? textStyle;

  const EntityBadge({
    super.key,
    this.icon,
    this.label,
    this.semanticLabel,
    this.iconSize,
    this.color,
    this.backgroundColor,
    this.variant = EntityBadgeVariant.inline,
    this.textStyle,
  }) : assert(icon != null || label != null, 'Either icon or label must be provided');

  /// Standard badge for an owned or hosted item (Star icon).
  const EntityBadge.owner({
    super.key,
    this.label,
    String? semanticLabel,
    this.iconSize,
    this.color,
    this.backgroundColor,
    this.variant = EntityBadgeVariant.inline,
    this.textStyle,
  })  : icon = Icons.star_outline_rounded,
        semanticLabel = semanticLabel ?? (label == null ? 'You own it' : null);

  /// Standard badge for a hosted item (Star icon with "You host it" semantics).
  const EntityBadge.host({
    super.key,
    this.label,
    String? semanticLabel,
    this.iconSize,
    this.color,
    this.backgroundColor,
    this.variant = EntityBadgeVariant.inline,
    this.textStyle,
  })  : icon = Icons.star_outline_rounded,
        semanticLabel = semanticLabel ?? (label == null ? 'You host it' : null);

  /// Standard badge for a private item (Lock icon).
  const EntityBadge.private({
    super.key,
    this.label,
    String? semanticLabel,
    this.iconSize,
    this.color,
    this.backgroundColor,
    this.variant = EntityBadgeVariant.inline,
    this.textStyle,
  })  : icon = Icons.lock_outline,
        semanticLabel = semanticLabel ?? (label == null ? 'Private' : null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = color ?? theme.colorScheme.onSurfaceVariant;
    final iconData = icon;
    final text = label;

    final Widget content;
    if (iconData != null && text != null) {
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            iconData,
            size: iconSize ?? 16,
            color: foregroundColor,
            semanticLabel: semanticLabel,
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: textStyle ??
                theme.textTheme.labelSmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      );
    } else if (iconData != null) {
      content = Icon(
        iconData,
        size: iconSize,
        color: color,
        semanticLabel: semanticLabel,
      );
    } else {
      content = Text(
        text!,
        style: textStyle ??
            theme.textTheme.labelSmall?.copyWith(
              color: foregroundColor,
              fontWeight: FontWeight.w600,
            ),
      );
    }

    if (variant == EntityBadgeVariant.pill) {
      final bg = backgroundColor ?? theme.colorScheme.surfaceContainerHighest;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AppDimens.radiusS),
        ),
        child: content,
      );
    }

    return content;
  }
}

/// A row of [EntityBadge]s or custom widgets with consistent layout and spacing.
class EntityBadges extends StatelessWidget {
  final List<Widget> children;
  final double spacing;

  const EntityBadges({
    super.key,
    required this.children,
    this.spacing = 0.0,
  });

  /// Factory helper that produces an [EntityBadges] row for owner and private status,
  /// or returns `null` if neither applies and no extras are supplied.
  static Widget? fromFlags({
    bool isOwner = false,
    String? ownerLabel,
    String ownerSemanticLabel = 'You own it',
    bool isPrivate = false,
    String? privateLabel,
    String privateSemanticLabel = 'Private',
    double? iconSize,
    Color? color,
    Color? backgroundColor,
    EntityBadgeVariant variant = EntityBadgeVariant.inline,
    List<Widget> extra = const [],
    double spacing = 0.0,
  }) {
    final badges = <Widget>[
      if (isOwner)
        EntityBadge.owner(
          label: ownerLabel,
          semanticLabel: ownerSemanticLabel,
          iconSize: iconSize,
          color: color,
          backgroundColor: backgroundColor,
          variant: variant,
        ),
      if (isPrivate)
        EntityBadge.private(
          label: privateLabel,
          semanticLabel: privateSemanticLabel,
          iconSize: iconSize,
          color: color,
          backgroundColor: backgroundColor,
          variant: variant,
        ),
      ...extra,
    ];
    if (badges.isEmpty) return null;
    return EntityBadges(spacing: spacing, children: badges);
  }

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    if (children.length == 1) return children.first;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 && spacing > 0) SizedBox(width: spacing),
          children[i],
        ],
      ],
    );
  }
}
