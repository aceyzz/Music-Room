import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// A full-width tonal action button placed directly beneath tab filters or top headers
/// (such as "Create playlist" or "Create event").
class TabActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry padding;

  const TabActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.padding = const EdgeInsets.fromLTRB(
      AppDimens.spacingM,
      0,
      AppDimens.spacingM,
      AppDimens.spacingS,
    ),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.tonalIcon(
          onPressed: onPressed,
          icon: Icon(icon),
          label: Text(label),
        ),
      ),
    );
  }
}
