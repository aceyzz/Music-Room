import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/section_header.dart';

void main() {
  group('SectionHeader', () {
    testWidgets('renders title without count', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionHeader(title: 'Requests'),
          ),
        ),
      );

      expect(find.text('Requests'), findsOneWidget);
    });

    testWidgets('renders title with count', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionHeader(title: 'Friends', count: 7),
          ),
        ),
      );

      expect(find.text('Friends (7)'), findsOneWidget);
    });

    testWidgets('renders trailing widget and triggers callback', (tester) async {
      var inviteTapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SectionHeader(
              title: 'Invited people',
              count: 3,
              trailing: TextButton(
                onPressed: () => inviteTapped = true,
                child: const Text('Invite'),
              ),
            ),
          ),
        ),
      );

      expect(find.text('Invited people (3)'), findsOneWidget);
      expect(find.text('Invite'), findsOneWidget);

      await tester.tap(find.text('Invite'));
      expect(inviteTapped, isTrue);
    });

    testWidgets('respects custom padding', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionHeader(
              title: 'Settings',
              padding: EdgeInsets.all(32),
            ),
          ),
        ),
      );

      final padding = tester.widget<Padding>(find.byType(Padding).first);
      expect(padding.padding, const EdgeInsets.all(32));
    });
  });
}
