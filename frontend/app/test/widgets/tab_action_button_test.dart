import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/tab_action_button.dart';

void main() {
  testWidgets('TabActionButton renders label, icon and handles tap', (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TabActionButton(
            label: 'Create playlist',
            icon: Icons.add,
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.text('Create playlist'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    expect(pressed, isTrue);
  });
}
