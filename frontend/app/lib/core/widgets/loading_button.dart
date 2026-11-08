import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// The primary action of a form. Shows a spinner and ignores taps while
/// [busy], so a slow request can't be submitted twice.
class LoadingButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final double? height;
  final ButtonStyle? style;

  const LoadingButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.height = AppDimens.buttonHeightForm,
    this.style,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final button = FilledButton(
      style: style,
      onPressed: busy ? null : onPressed,
      child: busy
          ? SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: colorScheme.primary),
            )
          : Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
    );

    if (height == null) {
      return button;
    }
    return SizedBox(
      height: height,
      child: button,
    );
  }
}
