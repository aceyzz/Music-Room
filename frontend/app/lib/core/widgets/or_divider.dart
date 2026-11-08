import 'package:flutter/material.dart';

/// A rule with a word in the middle, between two alternative ways to do the
/// same thing (password sign-in vs. a provider).
class OrDivider extends StatelessWidget {
  final String label;

  const OrDivider({super.key, this.label = 'OR'});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = Expanded(child: Divider(color: theme.colorScheme.outlineVariant));
    return Row(
      children: [
        line,
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        line,
      ],
    );
  }
}
