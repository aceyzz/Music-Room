import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/inline_loader.dart';

void main() {
  group('InlineLoader', () {
    testWidgets('renders progress indicator when hasError is false', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InlineLoader(hasError: false),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('The invited people could not be loaded. Pull to retry.'), findsNothing);
    });

    testWidgets('renders error message when hasError is true', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: InlineLoader(hasError: true),
          ),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('The invited people could not be loaded. Pull to retry.'), findsOneWidget);
    });
  });
}
