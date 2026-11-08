import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/entity_badges.dart';

void main() {
  group('EntityBadge', () {
    testWidgets('renders icon-only with semantic label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EntityBadge.owner(semanticLabel: 'You own it'),
          ),
        ),
      );

      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.bySemanticsLabel('You own it'), findsOneWidget);
    });

    testWidgets('renders text-only badge', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EntityBadge(label: 'Admin'),
          ),
        ),
      );

      expect(find.text('Admin'), findsOneWidget);
    });

    testWidgets('renders both icon and text label', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EntityBadge.owner(label: 'Owner'),
          ),
        ),
      );

      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
    });

    testWidgets('renders pill variant', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EntityBadge.private(
              label: 'Private',
              variant: EntityBadgeVariant.pill,
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);
      expect(find.byType(Container), findsOneWidget);
    });
  });

  group('EntityBadges.fromFlags', () {
    test('returns null when no flags and no extra badges', () {
      final widget = EntityBadges.fromFlags(isOwner: false, isPrivate: false);
      expect(widget, isNull);
    });

    testWidgets('renders both owner and private badges when flags are set', (tester) async {
      final widget = EntityBadges.fromFlags(
        isOwner: true,
        isPrivate: true,
      );
      expect(widget, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: widget!),
        ),
      );

      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('renders badges with text labels', (tester) async {
      final widget = EntityBadges.fromFlags(
        isOwner: true,
        ownerLabel: 'Host',
        isPrivate: true,
        privateLabel: 'Private',
      );
      expect(widget, isNotNull);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: widget!),
        ),
      );

      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Private'), findsOneWidget);
      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });
  });
}
