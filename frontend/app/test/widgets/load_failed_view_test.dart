import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/load_failed_view.dart';

void main() {
  testWidgets('LoadFailedView renders message and triggers onRetry with default text button', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoadFailedView(
            message: 'Failed to load content.',
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Failed to load content.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    expect(retried, isTrue);
  });

  testWidgets('LoadFailedView renders tonal button and custom label', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoadFailedView(
            message: 'Network issue.',
            onRetry: () => retried = true,
            retryLabel: 'Try again',
            buttonType: RetryButtonType.tonal,
          ),
        ),
      ),
    );

    expect(find.text('Network issue.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Try again'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Try again'));
    expect(retried, isTrue);
  });

  testWidgets('LoadFailedView renders outlined button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoadFailedView(
            message: 'Profile load error.',
            onRetry: () {},
            retryLabel: 'Try again',
            buttonType: RetryButtonType.outlined,
          ),
        ),
      ),
    );

    expect(find.widgetWithText(OutlinedButton, 'Try again'), findsOneWidget);
  });
}
