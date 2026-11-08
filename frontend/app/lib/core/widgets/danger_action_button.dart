import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// A centered destructive action button placed at the bottom of settings or
/// detail pages (such as "Delete playlist" or "End event").
class DangerActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry padding;

  const DangerActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.padding = const EdgeInsets.only(top: AppDimens.spacingXL),
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Center(
        child: TextButton.icon(
          onPressed: onPressed,
          style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
          icon: Icon(icon),
          label: Text(label),
        ),
      ),
    );
  }
}
