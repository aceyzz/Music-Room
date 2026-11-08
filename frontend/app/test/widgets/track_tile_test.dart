import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/core/widgets/track_tile.dart';

void main() {
  group('formatTrackDuration', () {
    test('formats zero seconds', () {
      expect(formatTrackDuration(Duration.zero), '0:00');
    });

    test('formats seconds under one minute with padding', () {
      expect(formatTrackDuration(const Duration(seconds: 5)), '0:05');
      expect(formatTrackDuration(const Duration(seconds: 42)), '0:42');
    });

    test('formats multiple minutes and seconds', () {
      expect(formatTrackDuration(const Duration(minutes: 3, seconds: 24)), '3:24');
      expect(formatTrackDuration(const Duration(minutes: 10, seconds: 8)), '10:08');
    });
  });

  group('TrackTile widget', () {
    testWidgets('renders track title, artist, duration and cover', (tester) async {
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TrackTile(
              title: 'Midnight City',
              artist: 'M83',
              duration: const Duration(minutes: 4, seconds: 3),
              coverUrl: 'https://example.com/cover.jpg',
              onTap: () => tapped = true,
              trailing: const Icon(Icons.star),
            ),
          ),
        ),
      );

      expect(find.text('Midnight City'), findsOneWidget);
      expect(find.text('M83 · 4:03'), findsOneWidget);
      expect(find.byType(PlaylistCover), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);

      await tester.tap(find.text('Midnight City'));
      expect(tapped, isTrue);
    });

    testWidgets('renders custom subtitle when provided', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrackTile(
              title: 'Song Name',
              artist: 'Artist',
              subtitle: Text('Custom subtitle text'),
            ),
          ),
        ),
      );

      expect(find.text('Song Name'), findsOneWidget);
      expect(find.text('Custom subtitle text'), findsOneWidget);
      expect(find.text('Artist'), findsNothing);
    });

    testWidgets('respects selected property', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: TrackTile(
              title: 'Playing Song',
              selected: true,
            ),
          ),
        ),
      );

      final listTile = tester.widget<ListTile>(find.byType(ListTile));
      expect(listTile.selected, isTrue);
    });
  });
}
