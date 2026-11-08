import 'package:flutter/material.dart';

/// A segment label on one line, scaled down if it does not fit horizontally.
class FittedSegmentLabel extends StatelessWidget {
  final String text;

  const FittedSegmentLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(text, maxLines: 1),
    );
  }
}
