import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/event/event_summary.dart';
import 'package:app/features/event/presentation/widgets/event_tile.dart';

void main() {
  final now = DateTime(2026, 10, 15, 20);
  EventSummary live({String status = 'live'}) => EventSummary(
        publicId: 'e',
        name: 'E',
        status: status,
        createdAt: now,
        startsAt: DateTime(2026, 10, 15, 19),
        endsAt: DateTime(2026, 10, 15, 23),
      );

  test('a running event says until when, whatever plays: no status to read', () {
    for (final status in ['live', 'scheduled']) {
      expect(EventTile.when(live(status: status), now), 'Until 23:00', reason: status);
    }
  });

  test('just after midnight is still the time alone', () {
    final night = EventSummary(
      publicId: 'n',
      name: 'N',
      status: 'live',
      createdAt: now,
      startsAt: DateTime(2026, 10, 15, 19),
      endsAt: DateTime(2026, 10, 16, 1, 30),
    );
    expect(EventTile.when(night, now), 'Until 01:30');
  });

  test('an end on another day says the day too', () {
    final festival = EventSummary(
      publicId: 'f',
      name: 'F',
      status: 'live',
      createdAt: now,
      startsAt: DateTime(2026, 10, 15, 12),
      endsAt: DateTime(2026, 10, 18, 2),
    );
    expect(EventTile.when(festival, now), 'Until 18 Oct 02:00');
  });

  test('an end in another year says the year too', () {
    final long = EventSummary(
      publicId: 'l',
      name: 'L',
      status: 'live',
      createdAt: now,
      startsAt: DateTime(2026, 10, 15, 12),
      endsAt: DateTime(2027, 10, 17, 2),
    );
    expect(EventTile.when(long, now), 'Until 17 Oct 2027 02:00');
  });

  group('an upcoming row says the hours: the leaf has the day', () {
    EventSummary at(DateTime starts, Duration length) => EventSummary(
          publicId: 'u',
          name: 'U',
          status: 'scheduled',
          createdAt: now,
          startsAt: starts,
          endsAt: starts.add(length),
        );

    test('within a day, and how soon', () {
      expect(EventTile.slot(at(DateTime(2026, 10, 15, 20, 20), const Duration(hours: 3)), now),
          '20:20 – 23:20 · in 20 min');
      expect(EventTile.slot(at(DateTime(2026, 10, 16, 2), const Duration(hours: 2)), now),
          '02:00 – 04:00 · in 6 h');
    });

    test('later, the hours only', () {
      expect(EventTile.slot(at(DateTime(2026, 10, 19, 20), const Duration(hours: 3)), now),
          '20:00 – 23:00');
    });

    test('an end on another day says that day: across midnight, or days later', () {
      expect(EventTile.slot(at(DateTime(2026, 10, 19, 23), const Duration(hours: 3)), now),
          '23:00 – 20 Oct 02:00');
      expect(EventTile.slot(at(DateTime(2026, 11, 2, 21), const Duration(days: 5)), now),
          '21:00 – 7 Nov 21:00');
    });

    test('an end in another year says the year', () {
      expect(EventTile.slot(at(DateTime(2026, 12, 31, 21), const Duration(hours: 6)), now),
          '21:00 – 1 Jan 2027 03:00');
    });
  });

  testWidgets("the leaf says the year when it is not this one, before or after", (tester) async {
    Future<void> pumpRow(DateTime starts) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: EventTile(
              event: EventSummary(
                publicId: 'y',
                name: 'Y',
                status: 'scheduled',
                createdAt: now,
                startsAt: starts,
                endsAt: starts.add(const Duration(hours: 3)),
              ),
              now: now,
            ),
          ),
        ));

    await pumpRow(DateTime(2027, 1, 15, 20));
    expect(find.text("JAN '27"), findsOneWidget);

    // A past year too: an event started last December that still runs.
    await pumpRow(DateTime(2025, 12, 20, 20));
    expect(find.text("DEC '25"), findsOneWidget);

    await pumpRow(DateTime(2026, 11, 2, 20));
    expect(find.text('NOV'), findsOneWidget);
  });

  group('dates, for the banner', () {
    EventSummary at(DateTime starts, Duration length) => EventSummary(
          publicId: 'd',
          name: 'D',
          status: 'scheduled',
          createdAt: now,
          startsAt: starts,
          endsAt: starts.add(length),
        );

    test('this year: the day, no year', () {
      expect(EventTile.dates(at(DateTime(2026, 10, 16, 20), const Duration(hours: 3)), now),
          'Fri 16 Oct · 20:00 – 23:00');
      expect(EventTile.dates(at(DateTime(2026, 10, 16, 23), const Duration(hours: 3)), now),
          '16 Oct 23:00 – 17 Oct 02:00');
    });

    test('another year, after or before: the year too', () {
      expect(EventTile.dates(at(DateTime(2027, 1, 15, 20), const Duration(hours: 3)), now),
          'Fri 15 Jan 2027 · 20:00 – 23:00');
      expect(EventTile.dates(at(DateTime(2025, 12, 20, 20), const Duration(hours: 3)), now),
          'Sat 20 Dec 2025 · 20:00 – 23:00');
      // Only the date in another year says it.
      expect(EventTile.dates(at(DateTime(2026, 12, 31, 21), const Duration(hours: 6)), now),
          '31 Dec 21:00 – 1 Jan 2027 03:00');
    });
  });
}
