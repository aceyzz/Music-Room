import 'package:flutter/material.dart';

/// A lightweight placeholder for inline list sections (such as member lists
/// on settings pages) showing either a centered spinner or an error message.
class InlineLoader extends StatelessWidget {
  final bool hasError;
  final String errorMessage;
  final EdgeInsetsGeometry padding;

  const InlineLoader({
    super.key,
    required this.hasError,
    this.errorMessage = 'The invited people could not be loaded. Pull to retry.',
    this.padding = const EdgeInsets.all(16),
  });

  @override
  Widget build(BuildContext context) {
    if (hasError) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(errorMessage),
      );
    }
    return Padding(
      padding: padding,
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}
