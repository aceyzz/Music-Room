import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/event/presentation/widgets/event_voting_section.dart';
import 'fake_live_event_api.dart' show FakePositionSource;

void main() {
  final now = DateTime(2026, 10, 19, 12);
  final event = EventSummary(
    publicId: 'e-1',
    name: 'Test Event',
    status: 'active',
    createdAt: now,
    startsAt: now,
    endsAt: now.add(const Duration(hours: 3)),
  );

  testWidgets('EventVotingSection renders voting choices and invokes onVoteChanged',
      (tester) async {
    VoteChoice? selected;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme(),
        home: Scaffold(
          body: EventVotingSection(
            event: event,
            canManage: true,
            busy: false,
            placing: false,
            draft: null,
            positions: FakePositionSource(),
            showMap: false,
            onVoteChanged: (choice) => selected = choice,
            onDraftChanged: (_) {},
            onSavePlace: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Who can vote'), findsOneWidget);
    expect(find.text('Everyone'), findsOneWidget);
    expect(find.text('Invited'), findsOneWidget);
    expect(find.text('Place & time'), findsOneWidget);

    await tester.tap(find.text('Invited'));
    await tester.pumpAndSettle();

    expect(selected, equals(VoteChoice.invited));
  });

  /// The section for [event], the host's unless [canManage] is false.
  Widget section(EventSummary event, {bool canManage = true, bool busy = false, bool placing = false}) =>
      MaterialApp(
        theme: AppTheme.lightTheme(),
        home: Scaffold(
          body: EventVotingSection(
            event: event,
            canManage: canManage,
            busy: busy,
            placing: placing,
            draft: null,
            positions: FakePositionSource(),
            showMap: false,
            onVoteChanged: (_) {},
            onDraftChanged: (_) {},
            onSavePlace: (_) {},
          ),
        ),
      );

  SegmentedButton<VoteChoice> buttons(WidgetTester tester) =>
      tester.widget<SegmentedButton<VoteChoice>>(find.byType(SegmentedButton<VoteChoice>));

  testWidgets('while a change is saved, the choices wait', (tester) async {
    await tester.pumpWidget(section(event, busy: true));
    expect(buttons(tester).onSelectionChanged, isNull);
  });

  testWidgets('an event with no times cannot use Place & time, and says why', (tester) async {
    final untimed = EventSummary(publicId: 'e-2', name: 'Untimed', status: 'active', createdAt: now);
    await tester.pumpWidget(section(untimed));

    expect(buttons(tester).segments.last.enabled, isFalse);
    expect(find.text("Place & time needs the event's start and end times."), findsOneWidget);
  });

  testWidgets('placing: Place & time shows as chosen before it is saved', (tester) async {
    await tester.pumpWidget(section(event, placing: true));
    expect(buttons(tester).selected, {VoteChoice.placeAndTime});
  });
}
