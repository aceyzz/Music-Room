import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/event/presentation/widgets/event_tile.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/pages/events_page.dart';

import '../auth/fake_auth_api.dart';
import '../home/fake_home_apis.dart';
import '../mocks/mock_flutter_secure_storage.dart';

// The page under a small router: an event's screens only say where they are.
void main() {
  late FakeEventApi events;
  late SessionStore session;

  // Thursday 15 October 2026, 20:30.
  final now = DateTime(2026, 10, 15, 20, 30);
  DateTime at(int day, int hour) => DateTime(2026, 10, day, hour);

  final all = [
    event('live', status: 'live', startsAt: at(15, 19), endsAt: at(15, 23)),
    event('undated-live', status: 'live', visibility: EventVisibility.private, host: true),
    event('later', startsAt: at(20, 18), endsAt: at(21, 2)),
    event('next', startsAt: at(16, 20), endsAt: at(16, 23)),
    event('past', startsAt: at(14, 20), endsAt: at(14, 23)),
  ];

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final api = FakeAuthApi()..emailVerified = true;
    events = FakeEventApi()..events = all;
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: api,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    await session.login(email: 'neo@example.test', password: 'password1234');
  });

  Future<void> pumpPage(WidgetTester tester, {String location = '/events'}) async {
    Widget opened(BuildContext context, GoRouterState state) =>
        Scaffold(body: Text('opened ${state.uri.path}'));
    final router = GoRouter(initialLocation: location, routes: [
      GoRoute(
        path: '/events',
        builder: (context, state) => EventsPage(now: () => now),
      ),
      GoRoute(path: '/events/:id', builder: opened),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<CurrentUserStore>.value(value: CurrentUserStore(FakeUserApi(), session)),
        Provider<EventApi>.value(value: events),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  List<String> shown(WidgetTester tester) =>
      tester.widgetList<EventTile>(find.byType(EventTile)).map((t) => t.event.publicId).toList();

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('Current shows what runs now; Upcoming what is coming; ended events are left out',
      (tester) async {
    await pumpPage(tester);

    expect(shown(tester), ['undated-live', 'live']);
    // No status: when it runs until, that's all.
    expect(find.text('Until 23:00'), findsOneWidget);
    expect(find.text('Now'), findsOneWidget); // no end time
    expect(find.textContaining('Paused'), findsNothing);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget); // on the private one only
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget); // on the one they host

    await tap(tester, find.text('Upcoming'));
    expect(shown(tester), ['next', 'later']);
    // The leaf has the day: the row says the hours, and how soon.
    expect(find.text('20:00 – 23:00 · in 23 h'), findsOneWidget);
    expect(find.text('18:00 – 21 Oct 02:00'), findsOneWidget);
    expect(events.calls, 1, reason: 'a pill does not reload');
  });

  testWidgets('an empty pill says so', (tester) async {
    events.events = const [];
    await pumpPage(tester);
    expect(find.text('Nothing is happening right now.'), findsOneWidget);

    await tap(tester, find.text('Upcoming'));
    expect(find.text('No upcoming events. Create one!'), findsOneWidget);
  });

  testWidgets('a failed load says so, and Try again recovers', (tester) async {
    events.failure = const NetworkError('offline');
    await pumpPage(tester);

    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);

    events.failure = null;
    await tap(tester, find.text('Try again'));
    expect(shown(tester), ['undated-live', 'live']);
  });

  testWidgets('the top bar\'s Refresh reloads the list', (tester) async {
    await pumpPage(tester);
    expect(events.calls, 1);

    events.events = [
      ...all,
      event('new', status: 'live', startsAt: at(15, 20), endsAt: at(15, 22)),
    ];
    await tap(tester, find.byTooltip('Refresh'));
    expect(events.calls, 2);
    expect(shown(tester), contains('new'));
  });

  group('tapping an event opens its one screen, whatever its phase', () {
    testWidgets('current', (tester) async {
      await pumpPage(tester);
      await tap(tester, find.text('Event live'));
      expect(find.text('opened /events/live'), findsOneWidget);
    });

    testWidgets('upcoming: the same screen, to vote ahead', (tester) async {
      await pumpPage(tester);
      await tap(tester, find.text('Upcoming'));
      await tap(tester, find.text('Event next'));
      expect(find.text('opened /events/next'), findsOneWidget);
    });
  });

  group('create event', () {
    Finder createButton() => find.widgetWithText(FilledButton, 'Create event');
    Finder submit() => find.widgetWithText(FilledButton, 'Create');
    Finder nameField() => find.widgetWithText(TextFormField, 'Name');
    Finder button(String key, String label) =>
        find.descendant(of: find.byKey(Key(key)), matching: find.text(label));

    // In the picker: a leaf in the list behind it shows a day number too.
    Future<void> pickDay(WidgetTester tester, String day) async {
      Finder inPicker(String text) =>
          find.descendant(of: find.byType(DatePickerDialog), matching: find.text(text));
      await tap(tester, inPicker(day));
      await tap(tester, inPicker('OK'));
    }

    Future<void> openSheet(WidgetTester tester) async {
      await tap(tester, createButton());
      expect(find.text('New event'), findsOneWidget);
    }

    testWidgets('the button sits under the pills, above the list', (tester) async {
      await pumpPage(tester);

      final rect = tester.getRect(createButton());
      expect(rect.top, greaterThanOrEqualTo(tester.getRect(find.text('Upcoming')).bottom));
      expect(rect.bottom, lessThanOrEqualTo(tester.getRect(find.text('Event undated-live')).top));
    });

    testWidgets('it starts at the next full hour and lasts 3 hours', (tester) async {
      await pumpPage(tester);
      await openSheet(tester);

      expect(button('starts-date', 'Thu 15 Oct 2026'), findsOneWidget);
      expect(button('starts-time', '21:00'), findsOneWidget);
      expect(button('ends-date', 'Fri 16 Oct 2026'), findsOneWidget);
      expect(button('ends-time', '00:00'), findsOneWidget);
    });

    testWidgets('a name is required', (tester) async {
      await pumpPage(tester);
      await openSheet(tester);

      await tap(tester, submit());
      expect(find.text('Give your event a name.'), findsOneWidget);
      expect(events.created, isEmpty);
    });

    testWidgets('moving the start moves the end; an end before the start is refused',
        (tester) async {
      await pumpPage(tester);
      await openSheet(tester);
      await tester.enterText(nameField(), 'Rooftop');

      // The start to the 17th: the end follows, still 3 hours later.
      await tap(tester, find.byKey(const Key('starts-date')));
      await pickDay(tester, '17');
      expect(button('starts-date', 'Sat 17 Oct 2026'), findsOneWidget);
      expect(button('ends-date', 'Sun 18 Oct 2026'), findsOneWidget);

      // The end back to the 15th, before the start.
      await tap(tester, find.byKey(const Key('ends-date')));
      await pickDay(tester, '15');
      await tap(tester, submit());

      expect(find.text('The event must end after it starts.'), findsOneWidget);
      expect(events.created, isEmpty);
    });

    testWidgets('creating sends the choices, opens the event, and lists it', (tester) async {
      await pumpPage(tester);
      await openSheet(tester);

      await tester.enterText(nameField(), '  Rooftop ');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Description (optional)'), 'Bring snacks');
      await tap(tester, find.text('Private'));
      expect(find.text(EventVisibility.private.description), findsOneWidget);
      await tap(tester, find.text(VoteChoice.invited.label));
      await tap(tester, submit());

      expect(events.created.single, (
        host: 'u-1',
        name: 'Rooftop',
        description: 'Bring snacks',
        visibility: EventVisibility.private,
        voteLicense: VoteLicense.invitedOnly,
        startsAt: at(15, 21),
        endsAt: at(16, 0),
        venue: null,
      ));
      // It starts in half an hour: its info page.
      expect(find.text('opened /events/new-1'), findsOneWidget);

      GoRouter.of(tester.element(find.text('opened /events/new-1'))).pop();
      await tester.pumpAndSettle();
      await tap(tester, find.text('Upcoming'));
      expect(shown(tester), ['new-1', 'next', 'later']);
      expect(find.text('21:00 – 16 Oct 00:00 · in 30 min'), findsOneWidget);
    });

    testWidgets('a refusal keeps the form open with the message and what was typed',
        (tester) async {
      await pumpPage(tester);
      await openSheet(tester);
      events.failure = const NetworkError('offline');

      await tester.enterText(nameField(), 'Rooftop');
      await tap(tester, submit());

      expect(find.text('New event'), findsOneWidget);
      expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Rooftop'), findsOneWidget);
    });
  });
}
