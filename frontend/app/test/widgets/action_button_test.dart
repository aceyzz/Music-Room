import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/action_button.dart';

void main() {
  group('ActionButton', () {
    testWidgets('renders filled variant with icon and label', (tester) async {
      var pressed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActionButton(
              icon: Icons.person_add_alt_1,
              label: 'Add as friend',
              onPressed: () => pressed = true,
            ),
          ),
        ),
      );

      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('Add as friend'), findsOneWidget);
      expect(find.byIcon(Icons.person_add_alt_1), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.tap(find.text('Add as friend'));
      expect(pressed, isTrue);
    });

    testWidgets('renders tonal variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActionButton.tonal(
              icon: Icons.lock_open,
              label: 'Unblock',
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.byType(FilledButton), findsOneWidget);
      expect(find.text('Unblock'), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('renders outlined variant', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActionButton.outlined(
              icon: Icons.info_outline,
              label: 'Details',
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.text('Details'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline), findsOneWidget);
    });

    testWidgets('renders danger variant with error coloring', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
          home: Scaffold(
            body: ActionButton.danger(
              icon: Icons.block,
              label: 'Block',
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.byType(OutlinedButton), findsOneWidget);
      expect(find.text('Block'), findsOneWidget);
      expect(find.byIcon(Icons.block), findsOneWidget);
    });

    testWidgets('shows CircularProgressIndicator when busy', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActionButton(
              icon: Icons.person_add_alt_1,
              label: 'Add as friend',
              busy: true,
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.person_add_alt_1), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

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
      expect(sizedBox.width, 18);
      expect(sizedBox.height, 18);
    });

    testWidgets('shows colored spinner when danger button is busy', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue)),
          home: Scaffold(
            body: ActionButton.danger(
              icon: Icons.block,
              label: 'Block',
              busy: true,
              onPressed: () {},
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.block), findsNothing);
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.color, isNotNull);
    });

    testWidgets('disabled when onPressed is null', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ActionButton(
              icon: Icons.schedule,
              label: 'Request sent',
              onPressed: null,
            ),
          ),
        ),
      );

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
    });
  });
}
