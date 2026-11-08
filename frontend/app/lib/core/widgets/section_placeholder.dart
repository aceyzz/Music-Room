import 'package:flutter/material.dart';

import 'package:app/core/errors/app_error.dart';

/// What a section shows instead of its content: a spinner, an error with a
/// retry, or a short message. [height] keeps the page from jumping when the
/// content arrives.
class SectionPlaceholder extends StatelessWidget {
  final double height;
  final String? message;
  final VoidCallback? onRetry;

  const SectionPlaceholder.loading({super.key, required this.height})
      : message = null,
        onRetry = null;

  const SectionPlaceholder.message(this.message, {super.key, required this.height})
      : onRetry = null;

  SectionPlaceholder.error(
    AppError error, {
    super.key,
    required this.height,
    required VoidCallback this.onRetry,
  }) : message = switch (error) {
          NetworkError() => 'Cannot reach the server. Check your connection.',
          UnauthorizedError() => 'Your session has ended. Please sign in again.',
          _ => 'This could not be loaded.',
        };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = this.message;
    final onRetry = this.onRetry;
    return SizedBox(
      height: height,
      child: Center(
        child: message == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    if (onRetry != null)
                      TextButton(onPressed: onRetry, child: const Text('Try again')),
                  ],
                ),
              ),
      ),
    );
  }
}
