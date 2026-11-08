import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/app_wordmark.dart';

void main() {
  group('AppWordmark', () {
    testWidgets('renders default music-room wordmark with brand tile', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppWordmark(),
          ),
        ),
      );

      expect(find.text('music-room'), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
    });

    testWidgets('renders subtitle when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppWordmark(subtitle: 'Create your account'),
          ),
        ),
      );

      expect(find.text('music-room'), findsOneWidget);
      expect(find.text('Create your account'), findsOneWidget);
    });

    testWidgets('renders custom title and custom icon widget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppWordmark(
              icon: Icon(Icons.mark_email_read_outlined, size: 64),
              title: 'Verify your email',
              subtitle: 'Check your inbox',
            ),
          ),
        ),
      );

      expect(find.text('Verify your email'), findsOneWidget);
      expect(find.text('Check your inbox'), findsOneWidget);
      expect(find.byIcon(Icons.mark_email_read_outlined), findsOneWidget);
      expect(find.byIcon(Icons.music_note_rounded), findsNothing);
    });
  });
}
