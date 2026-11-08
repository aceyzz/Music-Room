import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/danger_action_button.dart';

void main() {
  group('DangerActionButton', () {
    testWidgets('renders icon and label with error color, triggers callback on tap', (tester) async {
      var pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DangerActionButton(
              icon: Icons.delete_outline,
              label: 'Delete playlist',
              onPressed: () => pressed = true,
            ),
          ),
        ),
      );

      expect(find.text('Delete playlist'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      await tester.tap(find.text('Delete playlist'));
      expect(pressed, isTrue);
    });

    testWidgets('respects null onPressed (disabled state)', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DangerActionButton(
              icon: Icons.stop_circle_outlined,
              label: 'End event',
              onPressed: null,
            ),
          ),
        ),
      );

      final button = tester.widget<TextButton>(find.byType(TextButton));
      expect(button.onPressed, isNull);
    });
  });
}
