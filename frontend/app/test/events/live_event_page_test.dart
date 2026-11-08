import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';
import 'package:app/features/device/presentation/widgets/speaker_sheet.dart';
import 'package:app/core/device/device_info.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/event/presentation/widgets/suggest_song_sheet.dart';
import 'package:app/features/music/song/data/song_search_source.dart';
import 'package:app/pages/live_event_page.dart';

import '../auth/fake_auth_api.dart';
import '../device/fake_delegation_api.dart';
import '../device/fake_device_api.dart';
import '../user/fake_social_api.dart';
import '../home/fake_home_apis.dart' as home;
import '../mocks/mock_flutter_secure_storage.dart';
import '../music/fake_song_search_api.dart';
import 'fake_live_event_api.dart';

void main() {
  late FakeLiveEventApi api;
  late FakeSongSearchApi search;
  late SessionStore session;

  /// Provided only by the delegation tests: this device, once registered,
  /// and the licence API behind the host's "Where the music plays" button.
  DeviceStore? device;
  late FakeDelegationApi delegation;

  final updatedAt = DateTime(2026, 10, 3, 21);
  // Five seconds after the server's last answer; a test may move it.
  late DateTime now;

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final auth = FakeAuthApi()..emailVerified = true;
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: auth,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    await session.login(email: 'neo@example.test', password: 'password1234');
    device = null;
    delegation = FakeDelegationApi();

    now = updatedAt.add(const Duration(seconds: 5));
    api = FakeLiveEventApi()
      ..current = EventPlayback(
        currentEntryId: 1,
        track: track('Midnight City'),
        isPaused: false,
        position: const Duration(seconds: 10),
        updatedAt: updatedAt,
      )
      ..queued = [entry('q1', votes: 4)];
    search = FakeSongSearchApi()
      ..catalogue = [
        found(42, 'One More Time', artist: 'Daft Punk'),
        found(43, 'Aerodynamic', artist: 'Daft Punk'),
      ];
    api.catalogue = search.catalogue;
  });

  // pump, not pumpAndSettle: the progress bar repaints on a timer while the
  // song plays, so the tree never settles.
  Future<void> pumpPage(WidgetTester tester) async {
    // A phone-height screen: the default 800x600 puts the controls and the
    // queue below the fold, where the list does not build them.
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<LiveEventApi>.value(value: api),
        Provider<SongSearchApi>.value(value: search),
        if (device case final device?) ...[
          Provider<DeviceStore>.value(value: device),
          Provider<DelegationApi>.value(value: delegation),
          Provider<SocialApi>.value(
            value: FakeSocialApi()
              ..friendList = [const FriendSummary(publicId: 'sarah', displayName: 'Sarah')],
          ),
        ],
      ],
      child: MaterialApp(
        home: LiveEventPage(
          publicId: 'e1',
          now: () => now,
          audio: () => FakeAudioOutput(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  /// The ballot button of the row showing [title].
  Finder ballotOf(String title) => find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
        matching: find.byType(IconButton),
      );

  testWidgets('a member sees the vote page, without the player', (tester) async {
    api.queued = [entry('q1', votes: 4), entry('q2', votes: 1)];
    await pumpPage(tester);

    expect(find.text('Event e1'), findsOneWidget);
    expect(find.text('Player'), findsNothing);
    expect(find.byTooltip('Pause'), findsNothing);

    // The banner: what plays, and where, read-only.
    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.text('Midnight City'), findsOneWidget);
    expect(find.text('0:15'), findsOneWidget); // 10 s + the 5 since the server's answer
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(Slider), findsNothing);
    // The sound is not here: the host's app plays it, with their face.
    expect(find.text("Playing on Hostie's device"), findsOneWidget);
    expect(find.byType(UserAvatar), findsOneWidget);

    // The songs, each with its votes and a ballot button that says nothing.
    expect(find.text('Song q1'), findsOneWidget);
    expect(find.text('Artist of Song q1'), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
    expect(find.byIcon(Icons.how_to_vote_outlined), findsNWidgets(2));
    expect(find.textContaining('Vote'), findsNothing);
  });

  group('the start banner', () {
    testWidgets('before the start, it says when, and voting already works', (tester) async {
      api.eventSummary = home.event(
        'e1',
        startsAt: now.add(const Duration(hours: 3)),
        endsAt: now.add(const Duration(hours: 6)),
      );
      api.current = EventPlayback.idle(updatedAt);
      await pumpPage(tester);

      expect(find.text('Starts in 3 h'), findsOneWidget);
      await tester.tap(ballotOf('Song q1'));
      await tester.pump();
      expect(api.votes, ['q1']);
    });

    testWidgets('while it runs, it says when it ends', (tester) async {
      api.eventSummary = home.event(
        'e1',
        status: 'live',
        startsAt: now.subtract(const Duration(hours: 1)),
        endsAt: now.add(const Duration(hours: 2)),
      );
      await pumpPage(tester);
      expect(find.text('Ends in 2 h'), findsOneWidget);
      expect(find.textContaining('Starts in'), findsNothing);

      // Still playing after its end: it goes on until the host ends it.
      await tester.pumpWidget(const SizedBox());
      api.eventSummary = home.event(
        'e1',
        status: 'live',
        startsAt: now.subtract(const Duration(hours: 3)),
        endsAt: now.subtract(const Duration(minutes: 5)),
      );
      await pumpPage(tester);
      expect(find.text('Past its end time'), findsOneWidget);
      // The warning colour: it runs past its end.
      Color bannerOf(String title) => tester
          .widget<Material>(
              find.ancestor(of: find.text(title), matching: find.byType(Material)).first)
          .color!;
      final scheme = Theme.of(tester.element(find.text('Past its end time'))).colorScheme;
      expect(bannerOf('Past its end time'), scheme.errorContainer);
      expect(find.textContaining('ends as soon as it stops'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      api.eventSummary = home.event('e1', status: 'live');
      await pumpPage(tester);
      expect(find.text('Happening now'), findsOneWidget);
    });
  });

  testWidgets('a paused song says so, where it plays', (tester) async {
    api.current = EventPlayback(
      currentEntryId: 1,
      track: track('Midnight City'),
      isPaused: true,
      position: const Duration(seconds: 14),
      updatedAt: updatedAt,
    );
    await pumpPage(tester);

    expect(find.text("Paused on Hostie's device"), findsOneWidget);
    expect(find.text('0:14'), findsOneWidget, reason: 'it stays where it stopped');
  });

  testWidgets("tapping the host opens their profile", (tester) async {
    api.current = EventPlayback.idle(updatedAt);
    final router = GoRouter(initialLocation: '/events/e1', routes: [
      GoRoute(
        path: '/events/:id',
        builder: (context, state) => LiveEventPage(
          publicId: 'e1',
          now: () => now,
          audio: () => FakeAudioOutput(),
        ),
      ),
      GoRoute(
          path: '/users/:id',
          builder: (context, state) => Text('profile ${state.pathParameters['id']}')),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<LiveEventApi>.value(value: api),
        Provider<SongSearchApi>.value(value: search),
        if (device case final device?) ...[
          Provider<DeviceStore>.value(value: device),
          Provider<DelegationApi>.value(value: delegation),
          Provider<SocialApi>.value(
            value: FakeSocialApi()
              ..friendList = [const FriendSummary(publicId: 'sarah', displayName: 'Sarah')],
          ),
        ],
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Waiting for Hostie to press play'));
    await tester.pumpAndSettle();
    expect(find.text('profile u-9'), findsOneWidget);
  });

  /// The page opened from an events list (`/events` under it), for the
  /// tests that make it leave.
  Future<void> pumpFromList(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(initialLocation: '/events', routes: [
      GoRoute(
        path: '/events',
        builder: (context, state) => const Scaffold(body: Text('events list')),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => LiveEventPage(
              publicId: 'e1',
              now: () => now,
              audio: () => FakeAudioOutput(),
            ),
          ),
        ],
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<LiveEventApi>.value(value: api),
        Provider<SongSearchApi>.value(value: search),
        if (device case final device?) ...[
          Provider<DeviceStore>.value(value: device),
          Provider<DelegationApi>.value(value: delegation),
          Provider<SocialApi>.value(
            value: FakeSocialApi()
              ..friendList = [const FriendSummary(publicId: 'sarah', displayName: 'Sarah')],
          ),
        ],
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    router.push('/events/e1');
    await tester.pump();
    await tester.pump();
  }

  testWidgets('made private under them, the page leaves and says why', (tester) async {
    await pumpFromList(tester);
    expect(find.text('Song q1'), findsOneWidget);

    api.failWatches(const NotFoundError('event not found'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('events list'), findsOneWidget);
    expect(find.text("You can't see this event any more."), findsOneWidget);
  });

  testWidgets('without the guest list, the host is just "the host"', (tester) async {
    api.people = const [];
    api.current = EventPlayback.idle(updatedAt);
    await pumpPage(tester);

    expect(find.text('Waiting for the host to press play'), findsOneWidget);
    expect(find.byType(UserAvatar), findsNothing);
  });

  testWidgets('the description shows under the dates, when there is one', (tester) async {
    api.eventSummary = EventSummary(
      publicId: 'e1',
      name: 'Event e1',
      status: 'live',
      createdAt: updatedAt,
      description: 'Bring your own vinyl.',
    );
    await pumpPage(tester);
    expect(find.text('Bring your own vinyl.'), findsOneWidget);
  });

  testWidgets("the banner's bar follows the song; with nothing playing it says so", (tester) async {
    await pumpPage(tester);
    expect(find.text('0:15'), findsOneWidget);

    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('0:18'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, closeTo(18 / 30, 0.001));

    // The song ended and nothing was queued.
    await tester.pumpWidget(const SizedBox());
    api.current = EventPlayback.idle(updatedAt);
    await pumpPage(tester);
    expect(find.text('Nothing is playing yet'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('a vote counts once, moves the song up, and fills the ballot', (tester) async {
    api.queued = [entry('q1', votes: 2), entry('q2', votes: 2)];
    await pumpPage(tester);
    expect(
      tester.getTopLeft(find.text('Song q1')).dy,
      lessThan(tester.getTopLeft(find.text('Song q2')).dy),
    );

    await tester.tap(ballotOf('Song q2'));
    await tester.pump();
    await tester.pump();

    expect(api.votes, ['q2']);
    expect(find.text('3'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Song q2')).dy,
      lessThan(tester.getTopLeft(find.text('Song q1')).dy),
      reason: 'the most-voted song comes first',
    );
    expect(find.byIcon(Icons.how_to_vote), findsOneWidget);
    expect(tester.widget<IconButton>(ballotOf('Song q2')).onPressed, isNull,
        reason: 'there is no un-vote');

    await tester.tap(ballotOf('Song q2'));
    await tester.pump();
    expect(api.votes, ['q2']);
  });

  testWidgets('a song already voted for comes filled and disabled', (tester) async {
    api.queued = [entry('q1', votes: 1, voted: true)];
    await pumpPage(tester);

    expect(find.byIcon(Icons.how_to_vote), findsOneWidget);
    expect(tester.widget<IconButton>(ballotOf('Song q1')).onPressed, isNull);
  });

  testWidgets('a refused vote says why', (tester) async {
    api.voteFailure = const UnauthorizedError('Permission denied: permission denied');
    await pumpPage(tester);

    await tester.tap(ballotOf('Song q1'));
    await tester.pump();
    await tester.pump();
    expect(find.text("You can't vote in this event."), findsOneWidget);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('a vote refused for the place or the time says which', (tester) async {
    api.voteFailure =
        const UnauthorizedError("Permission denied: outside this event's venue radius");
    await pumpPage(tester);

    await tester.tap(ballotOf('Song q1'));
    await tester.pump();
    await tester.pump();
    expect(find.text("You are not at this event's venue: only people there can vote."),
        findsOneWidget);
  });

  testWidgets('a vote for a song that started playing says so', (tester) async {
    await pumpPage(tester);

    // Meanwhile it was played.
    api.queued = [];
    await tester.tap(ballotOf('Song q1'));
    await tester.pump();
    await tester.pump();

    expect(find.text('That song has already left the queue.'), findsOneWidget);
    expect(find.text('Song q1'), findsNothing);
  });

  testWidgets('the search filters the queue by title or artist', (tester) async {
    api.queued = [
      entry('q1', artist: 'Daft Punk'),
      entry('q2', artist: 'M83'),
      entry('q3', artist: 'Justice'),
    ];
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'daft');
    await tester.pump();
    expect(find.text('Song q1'), findsOneWidget);
    expect(find.text('Song q2'), findsNothing);

    await tester.enterText(find.byType(TextField), 'song q3');
    await tester.pump();
    expect(find.text('Song q3'), findsOneWidget);
    expect(find.text('Song q1'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text('No song matches "zzz".'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(find.text('Song q1'), findsOneWidget);
    expect(find.text('Song q2'), findsOneWidget);
    expect(find.text('Song q3'), findsOneWidget);
    expect((api.watches, api.queueReads), (1, 0), reason: 'searching sends nothing');
  });

  testWidgets('the search scrolls away, and comes back on scrolling up', (tester) async {
    // Paused, so the bar does not tick and the tree can settle.
    api
      ..current = EventPlayback(
        currentEntryId: 1,
        track: track('Midnight City'),
        isPaused: true,
        position: const Duration(seconds: 10),
        updatedAt: updatedAt,
      )
      ..queued = [for (var i = 0; i < 40; i++) entry('q$i')];
    await pumpPage(tester);
    final search = find.byType(TextField).hitTestable();
    expect(search, findsOneWidget);

    await tester.drag(find.text('Song q3'), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(search, findsNothing);
    expect(find.text('NOW PLAYING'), findsOneWidget, reason: 'the banner stays');

    await tester.drag(find.text('Song q12'), const Offset(0, 80));
    await tester.pumpAndSettle();
    expect(search, findsOneWidget);
    expect(find.text('Song q0'), findsNothing, reason: 'still mid-list');
  });

  testWidgets("others' votes show up as the server pushes them", (tester) async {
    await pumpPage(tester);
    expect(find.text('4'), findsOneWidget);

    api.queued = [entry('q1', votes: 9)];
    api.push();
    await tester.pump(); // the push arrives
    await tester.pump(); // the queue rebuilds
    expect(find.text('9'), findsOneWidget);

    // Closed: the stream is let go.
    await tester.pumpWidget(const SizedBox());
    expect(api.openWatches, 0);
  });

  // --- Suggesting. Paused, so the banner's bar does not tick and the sheet's
  // --- animations can settle.

  EventPlayback pausedOn(EventTrack playing) => EventPlayback(
        currentEntryId: 1,
        track: playing,
        isPaused: true,
        position: const Duration(seconds: 10),
        updatedAt: updatedAt,
      );

  /// The sheet's search box, not the queue's.
  Finder sheetField() =>
      find.descendant(of: find.byType(SuggestSongSheet), matching: find.byType(TextField));

  /// The + of the search result showing [title].
  Finder plusOf(String title) => find.descendant(
        of: find.ancestor(of: find.text(title), matching: find.byType(ListTile)),
        matching: find.byTooltip('Suggest'),
      );

  Future<void> openSheetAndSearch(WidgetTester tester, String query) async {
    await tester.tap(find.byTooltip('Suggest a song'));
    await tester.pumpAndSettle();
    await tester.enterText(sheetField(), query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  Future<void> closeSheet(WidgetTester tester) async {
    // The barrier above the sheet, which takes 90% of the height.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
  }

  testWidgets('made private under the suggestion sheet: the sheet closes and the page leaves',
      (tester) async {
    // Paused: the banner's bar does not tick, and the sheet settles.
    api.current = pausedOn(track('Midnight City'));
    await pumpFromList(tester);
    // The page's way in: its transition over the list, done.
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Suggest a song'));
    await tester.pumpAndSettle();
    expect(find.byType(SuggestSongSheet), findsOneWidget);

    api.failWatches(const NotFoundError('event not found'));
    await tester.pumpAndSettle();

    expect(find.byType(SuggestSongSheet), findsNothing);
    expect(find.byType(LiveEventPage), findsNothing);
    expect(find.text('events list'), findsOneWidget);
    expect(find.text("You can't see this event any more."), findsOneWidget);
  });

  testWidgets('+ searches Deezer, and a suggestion joins the queue with no votes', (tester) async {
    api.current = pausedOn(track('Midnight City'));
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Suggest a song'));
    await tester.pumpAndSettle();
    expect(find.text('Search Deezer for a song to add to the queue.'), findsOneWidget);
    expect(find.text('New songs start with no votes.'), findsOneWidget);

    await tester.enterText(sheetField(), 'daft');
    await tester.pump(const Duration(milliseconds: 299));
    expect(search.searches, isEmpty, reason: 'typing has not paused for 300 ms yet');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(search.searches, ['daft']);
    expect(find.text('One More Time'), findsOneWidget);
    expect(find.text('Aerodynamic'), findsOneWidget);

    await tester.tap(plusOf('One More Time'));
    await tester.pumpAndSettle();
    expect(api.suggested, [42]);
    expect(find.text('In the queue'), findsOneWidget, reason: 'the sheet stays open');
    expect(plusOf('One More Time'), findsNothing);
    expect(plusOf('Aerodynamic'), findsOneWidget);

    await closeSheet(tester);
    expect(find.byType(SuggestSongSheet), findsNothing);
    expect(find.text('One More Time'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Song q1')).dy,
      lessThan(tester.getTopLeft(find.text('One More Time')).dy),
      reason: 'no votes: after the voted song',
    );
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('a result already queued or playing has no +', (tester) async {
    api
      ..current = pausedOn(found(43, 'Aerodynamic', artist: 'Daft Punk'))
      ..queued = [entry('q1', deezerId: 42)];
    search.catalogue = [...search.catalogue, found(44, 'Digital Love', artist: 'Daft Punk')];
    await pumpPage(tester);

    await openSheetAndSearch(tester, 'daft');
    expect(find.text('In the queue'), findsOneWidget);
    expect(find.text('Playing now'), findsOneWidget);
    expect(find.byTooltip('Suggest'), findsOneWidget);
    expect(plusOf('Digital Love'), findsOneWidget);
  });

  testWidgets('a refused suggestion says why, in the sheet', (tester) async {
    api.current = pausedOn(track('Midnight City'));
    await pumpPage(tester);
    await openSheetAndSearch(tester, 'daft');

    // Meanwhile someone else suggested it.
    api.queued = [...api.queued, entry('q9', deezerId: 42)];
    await tester.tap(plusOf('One More Time'));
    await tester.pumpAndSettle();
    expect(find.text('That song is already in the queue.'), findsOneWidget);

    // Typing clears it.
    await tester.enterText(sheetField(), 'aero');
    await tester.pump();
    expect(find.text('That song is already in the queue.'), findsNothing);

    api.suggestFailure = const UnauthorizedError('Permission denied: permission denied');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(plusOf('Aerodynamic'));
    await tester.pumpAndSettle();
    expect(find.text("You can't suggest songs in this event."), findsOneWidget);
  });

  testWidgets('a queue search with no match offers to search Deezer', (tester) async {
    api.current = pausedOn(track('Midnight City'));
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'one more');
    await tester.pumpAndSettle();
    expect(find.text('No song matches "one more".'), findsOneWidget);

    await tester.tap(find.text('Search Deezer for "one more"'));
    await tester.pumpAndSettle();
    expect(search.searches, ['one more'], reason: 'already typed: no pause to wait for');
    expect(tester.widget<TextField>(sheetField()).controller!.text, 'one more');
    expect(find.text('One More Time'), findsOneWidget);
  });

  testWidgets('a suggestion into a silent event joins the queue, and nothing starts',
      (tester) async {
    api
      ..current = EventPlayback.idle(updatedAt)
      ..queued = [];
    await pumpPage(tester);
    expect(find.text('Nothing queued yet. Add a song with +.'), findsOneWidget);

    await openSheetAndSearch(tester, 'daft');
    await tester.tap(plusOf('One More Time'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Playing now'), findsNothing);

    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.byType(SuggestSongSheet), findsNothing);
    expect(find.text('One More Time'), findsOneWidget, reason: 'in the queue');
    expect(find.text('Nothing is playing yet'), findsOneWidget);
    expect(find.text('Waiting for Hostie to press play'), findsOneWidget);
  });

  testWidgets('without the right to vote, the ballots are greyed out and there is no +',
      (tester) async {
    api.canVote = false;
    api.eventSummary = EventSummary(
      publicId: 'e1',
      name: 'Event e1',
      status: 'live',
      createdAt: updatedAt,
      voteLicense: 'invited_only',
    );
    await pumpPage(tester);

    expect(find.text('Only invited people can vote and suggest songs.'), findsOneWidget);
    expect(tester.widget<IconButton>(ballotOf('Song q1')).onPressed, isNull);
    expect(find.byTooltip('Suggest a song'), findsNothing);
    expect(find.text('4'), findsOneWidget, reason: 'the votes still show');
  });

  testWidgets('once ended, the page is read-only, even for the host', (tester) async {
    api.canControl = true;
    api.eventSummary = home.event('e1', status: 'ended');
    await pumpPage(tester);

    expect(find.text('This event has ended'), findsOneWidget);
    final scheme = Theme.of(tester.element(find.text('This event has ended'))).colorScheme;
    final banner = tester.widget<Material>(find
        .ancestor(of: find.text('This event has ended'), matching: find.byType(Material))
        .first);
    expect(banner.color, scheme.surfaceContainerHighest, reason: 'grey once over');
    expect(find.byTooltip('Pause'), findsNothing);
    expect(find.byTooltip('Next'), findsNothing);
    expect(find.byTooltip('Suggest a song'), findsNothing);
    // The queue as it was, its ballots disabled.
    expect(find.text('Song q1'), findsOneWidget);
    expect(tester.widget<IconButton>(ballotOf('Song q1')).onPressed, isNull);
  });

  testWidgets('the person in control gets the same page, with the buttons in the banner',
      (tester) async {
    api.canControl = true;
    await pumpPage(tester);

    // One page: no Vote / Player switch.
    expect(find.text('Player'), findsNothing);
    expect(find.text('NOW PLAYING'), findsOneWidget);
    expect(find.text('Midnight City'), findsOneWidget);
    expect(find.text('0:15'), findsOneWidget); // 10 s + the 5 since the server's answer
    expect(find.byTooltip('Restart'), findsOneWidget);
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.byTooltip('Next'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget, reason: 'they can move the song');

    // And they vote and suggest like everyone.
    expect(ballotOf('Song q1'), findsOneWidget);
    expect(find.byTooltip('Suggest a song'), findsOneWidget);
    // This app is the speaker: nothing to explain.
    expect(find.textContaining("'s device"), findsNothing);
  });

  testWidgets('with nothing playing, the host presses play from the banner', (tester) async {
    api.canControl = true;
    api.current = EventPlayback.idle(updatedAt);
    api.afterNext = EventPlayback(
      currentEntryId: 2,
      track: track('Song q1'),
      isPaused: false,
      position: Duration.zero,
      updatedAt: now,
    );
    await pumpPage(tester);

    expect(find.text('Press play to start the most-voted song'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    await tester.pump();

    expect(api.nextCalls, 1, reason: 'play with nothing playing starts the most-voted song');
    expect(find.text('Song q1'), findsOneWidget, reason: 'now in the banner');
    expect(find.byTooltip('Pause'), findsOneWidget);
  });

  testWidgets('pause sends the live position', (tester) async {
    api.canControl = true;
    await pumpPage(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.pump();

    expect(api.sent.single, (isPaused: true, position: const Duration(seconds: 15)));
    expect(find.byTooltip('Play'), findsOneWidget);
  });

  group('Where the music plays', () {
    void withDevice() {
      final store = DeviceStore(FakeDeviceApi(), session, () async => 'install-1', DeviceInfo.fallback())
        ..start();
      addTearDown(store.stop);
      // Registers on the next pumps (pumpPage): no pumpEventQueue in a
      // widget test, whose timers only run when pumped.
      device = store;
    }

    /// The host's two devices: this one (device-1, id 1, FakeDeviceApi's)
    /// and a laptop. [speaker] is the event's.
    void hostWithTwoDevices({required int speaker}) {
      withDevice();
      delegation.devices = const [
        UserDevice(id: 1, publicId: 'device-1', name: 'Pixel', platform: 'android'),
        UserDevice(id: 2, publicId: 'device-2', name: 'Laptop', platform: 'desktop'),
      ];
      api
        ..eventSummary = home.event('e1', status: 'live', host: true)
        ..canControl = true
        ..current = EventPlayback(
          currentEntryId: 1,
          track: track('Midnight City'),
          isPaused: false,
          position: const Duration(seconds: 10),
          updatedAt: updatedAt,
          speakerDeviceId: speaker,
        );
    }

    Future<void> openSheet(WidgetTester tester) async {
      // pump, not pumpAndSettle: the song plays (see pumpPage).
      await tester.tap(find.byTooltip('Where the music plays'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // the sheet slides up
    }

    testWidgets("the host's devices, the one that plays ticked; another one takes over",
        (tester) async {
      hostWithTwoDevices(speaker: 1);
      await pumpPage(tester);
      await openSheet(tester);

      expect(find.text('Pixel (this device)'), findsOneWidget);
      expect(find.text('Laptop'), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(of: find.text('Pixel (this device)'), matching: find.byType(ListTile)),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Laptop'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // the sheet slides down

      expect(delegation.calls, contains('speaker e1 device-2'));
      expect(find.byType(SpeakerSheet), findsNothing);
    });

    testWidgets('a guest has no such button', (tester) async {
      withDevice();
      await pumpPage(tester);

      expect(find.byTooltip('Where the music plays'), findsNothing);
    });
  });
}
