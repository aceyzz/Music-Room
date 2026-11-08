import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/widgets/section_placeholder.dart';

void main() {
  testWidgets('SectionPlaceholder.loading displays progress indicator', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SectionPlaceholder.loading(height: 100),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('SectionPlaceholder.message displays text message', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SectionPlaceholder.message('No data available', height: 100),
        ),
      ),
    );

    expect(find.text('No data available'), findsOneWidget);
  });

  testWidgets('SectionPlaceholder.error displays mapped error message and retry button', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SectionPlaceholder.error(
            const NetworkError('Connection failed'),
            height: 100,
            onRetry: () => retried = true,
          ),
        ),
      ),
    );

    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Try again'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Try again'));
    expect(retried, isTrue);
  });
}
