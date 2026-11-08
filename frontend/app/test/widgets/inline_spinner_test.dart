import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/inline_spinner.dart';

void main() {
  group('InlineSpinner', () {
    testWidgets('renders default 20x20 spinner with strokeWidth 2', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InlineSpinner(),
          ),
        ),
      );

      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.strokeWidth, 2);

      final sizedBox = tester.widget<SizedBox>(
        find.ancestor(
          of: find.byType(CircularProgressIndicator),
          matching: find.byType(SizedBox),
        ),
      );
      expect(sizedBox.width, 20);
      expect(sizedBox.height, 20);
    });

    testWidgets('supports custom size, strokeWidth, and color', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InlineSpinner(
              size: 24,
              strokeWidth: 3,
              color: Colors.red,
            ),
          ),
        ),
      );

      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.strokeWidth, 3);
      expect(indicator.color, Colors.red);

      final sizedBox = tester.widget<SizedBox>(
        find.ancestor(
          of: find.byType(CircularProgressIndicator),
          matching: find.byType(SizedBox),
        ),
      );
      expect(sizedBox.width, 24);
      expect(sizedBox.height, 24);
    });
  });
}
