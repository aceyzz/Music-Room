import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/text_input_dialog.dart';

void main() {
  testWidgets('showTextInputDialog returns input on confirm', (tester) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showTextInputDialog(
                  context,
                  title: 'Rename playlist',
                  initial: 'Roadtrip',
                  confirmLabel: 'Save',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Rename playlist'), findsOneWidget);
    expect(find.text('Roadtrip'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Roadtrip 2026');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result, 'Roadtrip 2026');
  });

  testWidgets('showTextInputDialog returns null on cancel', (tester) async {
    String? result = 'initial';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showTextInputDialog(
                  context,
                  title: 'Rename playlist',
                  initial: 'Roadtrip',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
  });

  testWidgets('showTextInputDialog returns input on field submitted (Enter key)', (tester) async {
    String? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                result = await showTextInputDialog(
                  context,
                  title: 'Edit name',
                  initial: 'Original',
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Submitted Name');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(result, 'Submitted Name');
  });
}
