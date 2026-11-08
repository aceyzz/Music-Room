import 'package:flutter/material.dart';

/// A compact spinner for inline action rows, list tile trailings, and button substitutions.
class InlineSpinner extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final Color? color;

  const InlineSpinner({
    super.key,
    this.size = 20,
    this.strokeWidth = 2,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        color: color,
      ),
    );
  }
}
