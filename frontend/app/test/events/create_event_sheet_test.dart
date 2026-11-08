import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/event/presentation/widgets/create_event_sheet.dart';

import 'fake_live_event_api.dart' show FakePositionSource;

void main() {
  late FakePositionSource positions;
  ({
    String name,
    VoteLicense voteLicense,
    DateTime startsAt,
    DateTime endsAt,
    EventVenue? venue
  })? sent;

  setUp(() {
    positions = FakePositionSource();
    sent = null;
  });

  Future<EventSummary> create({
    required String name,
    required String description,
    required EventVisibility visibility,
    required VoteLicense voteLicense,
    required DateTime startsAt,
    required DateTime endsAt,
    EventVenue? venue,
  }) async {
    sent = (name: name, voteLicense: voteLicense, startsAt: startsAt, endsAt: endsAt, venue: venue);
    return EventSummary(publicId: 'new', name: name, status: 'scheduled', createdAt: startsAt);
  }

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(412, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.lightTheme(),
      home: Scaffold(
        body: CreateEventSheet(
          create: create,
          now: () => DateTime(2026, 10, 17, 19, 10),
          positions: positions,
          showMap: false,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'At 42');
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Place & time asks where on the same page, and the event is created there',
      (tester) async {
    positions.position = (latitude: 46.5374, longitude: 6.589);
    await pumpSheet(tester);

    await tap(tester, find.text('Place & time'));
    expect(find.text('New event'), findsOneWidget, reason: 'no other page');
    await tap(tester, find.text('Use my position'));
    await tap(tester, find.text('100 m'));
    expect(find.textContaining('within 100 m of the venue'), findsOneWidget);

    await tap(tester, find.text('Create'));

    expect(sent!.venue, (latitude: 46.5374, longitude: 6.589, radiusMeters: 100));
    // The window is the form's own times (voteWindowFor).
    expect(sent!.endsAt.difference(sent!.startsAt), const Duration(hours: 3));
  });

  testWidgets('Place & time starts from a default venue; leaving it sends none', (tester) async {
    await pumpSheet(tester);

    await tap(tester, find.text('Place & time'));
    expect(find.text('Latitude'), findsOneWidget);
    await tap(tester, find.text('Everyone'));
    expect(find.text('Latitude'), findsNothing);
    await tap(tester, find.text('Create'));

    expect(sent!.venue, isNull);
    expect(sent!.voteLicense, VoteLicense.everyone);
  });

  testWidgets('nonsense coordinates hold the creation back', (tester) async {
    await pumpSheet(tester);

    await tap(tester, find.text('Place & time'));
    await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '95');
    await tester.pump();
    await tap(tester, find.text('Create'));

    expect(sent, isNull);
    expect(find.text('Fix the coordinates of the venue.'), findsOneWidget);
  });

  testWidgets('Invited sends the invited-only licence and no place', (tester) async {
    await pumpSheet(tester);

    await tap(tester, find.text('Invited'));
    expect(find.text(VoteLicense.invitedOnly.description), findsOneWidget);
    await tap(tester, find.text('Create'));

    expect(sent!.voteLicense, VoteLicense.invitedOnly);
    expect(sent!.venue, isNull);
  });
}
