import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/loading_button.dart';

void main() {
  testWidgets('renders label and triggers onPressed when not busy', (tester) async {
    var pressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoadingButton(
            label: 'Submit',
            busy: false,
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.text('Submit'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Submit'));
    expect(pressed, isTrue);
  });

  testWidgets('shows spinner and ignores taps when busy', (tester) async {
    var pressed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoadingButton(
            label: 'Submit',
            busy: true,
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.text('Submit'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byType(CircularProgressIndicator));
    expect(pressed, isFalse);
  });

  testWidgets('respects custom height and null height', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LoadingButton(label: 'Custom Height', height: 48, onPressed: () {}),
              LoadingButton(label: 'Null Height', height: null, onPressed: () {}),
            ],
          ),
        ),
      ),
    );

    final sizedBoxes = tester.widgetList<SizedBox>(find.byType(SizedBox));
    expect(sizedBoxes.any((box) => box.height == 48), isTrue);
  });
}
