import 'package:flutter/material.dart';

enum RetryButtonType { text, tonal, outlined }

/// A centered view showing a load failure message and a retry button.
class LoadFailedView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final String retryLabel;
  final RetryButtonType buttonType;

  const LoadFailedView({
    super.key,
    required this.message,
    required this.onRetry,
    this.retryLabel = 'Retry',
    this.buttonType = RetryButtonType.text,
  });

  @override
  Widget build(BuildContext context) {
    final Widget button = switch (buttonType) {
      RetryButtonType.text => TextButton(onPressed: onRetry, child: Text(retryLabel)),
      RetryButtonType.tonal => FilledButton.tonal(onPressed: onRetry, child: Text(retryLabel)),
      RetryButtonType.outlined => OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
    };

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(message, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          button,
        ],
      ),
    );
  }
}
