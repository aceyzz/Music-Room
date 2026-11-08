import 'package:flutter/material.dart';

/// The styling variant for an [ActionButton].
enum ActionButtonVariant {
  /// Primary filled button ([FilledButton.icon]).
  filled,

  /// Secondary tonal button ([FilledButton.tonalIcon]).
  tonal,

  /// Outlined button ([OutlinedButton.icon]).
  outlined,
}

/// An action button that displays an icon and text, with built-in asynchronous
/// loading state that automatically swaps the icon for a spinner when [busy] is true.
class ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final ActionButtonVariant variant;
  final bool isDanger;
  final ButtonStyle? style;

  const ActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.variant = ActionButtonVariant.filled,
    this.isDanger = false,
    this.style,
  });

  /// Convenience constructor for a tonal action button.
  const ActionButton.tonal({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.style,
  })  : variant = ActionButtonVariant.tonal,
        isDanger = false;

  /// Convenience constructor for an outlined action button.
  const ActionButton.outlined({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.style,
  })  : variant = ActionButtonVariant.outlined,
        isDanger = false;

  /// Convenience constructor for a danger / destructive outlined action button (such as Block).
  const ActionButton.danger({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.busy = false,
    this.style,
  })  : variant = ActionButtonVariant.outlined,
        isDanger = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorColor = theme.colorScheme.error;

    final Widget iconWidget = busy
        ? SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: isDanger ? errorColor : null,
            ),
          )
        : Icon(icon);

    if (isDanger) {
      final dangerStyle = OutlinedButton.styleFrom(
        foregroundColor: errorColor,
        side: BorderSide(color: errorColor),
      ).merge(style);

      return OutlinedButton.icon(
        style: dangerStyle,
        icon: iconWidget,
        label: Text(label),
        onPressed: onPressed,
      );
    }

    return switch (variant) {
      ActionButtonVariant.filled => FilledButton.icon(
          style: style,
          icon: iconWidget,
          label: Text(label),
          onPressed: onPressed,
        ),
      ActionButtonVariant.tonal => FilledButton.tonalIcon(
          style: style,
          icon: iconWidget,
          label: Text(label),
          onPressed: onPressed,
        ),
      ActionButtonVariant.outlined => OutlinedButton.icon(
          style: style,
          icon: iconWidget,
          label: Text(label),
          onPressed: onPressed,
        ),
    };
  }
}
