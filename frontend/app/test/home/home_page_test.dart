import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/home/presentation/widgets/friends_bar.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/pages/home_page.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';
import 'fake_home_apis.dart';

final now = DateTime.utc(2026, 10, 3, 20);
DateTime hours(int h) => now.add(Duration(hours: h));

// The page under a small router whose other routes only say where they are,
// so a tap can be checked by the path it opened.
void main() {
  late FakeEventApi events;
  late FakeUserApi users;
  late FakePlaylistApi playlists;
  late SessionStore session;

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final api = FakeAuthApi()..emailVerified = true;
    events = FakeEventApi()
      ..events = [
        event('past', status: 'ended', endsAt: hours(-24)),
        event('live', status: 'live'),
        event('next', startsAt: hours(24)),
      ];
    users = FakeUserApi()
      ..friends = const [
        FriendSummary(publicId: 'u-2', displayName: 'trinity'),
        FriendSummary(publicId: 'u-3', displayName: 'morpheus'),
      ];
    playlists = FakePlaylistApi();
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

  Future<void> pumpHome(WidgetTester tester) async {
    Widget opened(BuildContext context, GoRouterState state) =>
        Scaffold(body: Text('opened ${state.uri.path}'));
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (context, state) => HomePage(now: () => now)),
      GoRoute(path: '/events/:id', builder: opened),
      GoRoute(path: '/playlists/:id', builder: opened),
      GoRoute(path: '/users/:id', builder: opened),
      GoRoute(path: '/friends', builder: opened),
      GoRoute(path: '/events', builder: opened),
      GoRoute(path: '/playlists', builder: opened),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<CurrentUserStore>.value(value: CurrentUserStore(users, session)),
        Provider<UserApi>.value(value: users),
        Provider<EventApi>.value(value: events),
        Provider<PlaylistApi>.value(value: playlists),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('events carousel', () {
    double page(WidgetTester tester) =>
        tester.widget<PageView>(find.byType(PageView)).controller!.page!;

    testWidgets('opens on the live event; swipe left for upcoming; ended ones are left out',
        (tester) async {
      await pumpHome(tester);
      expect(page(tester), 0); // [live], next
      expect(find.text('Event past'), findsNothing);

      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(page(tester), 1);
    });

    testWidgets('back from an event that went private meanwhile: it is no longer shown',
        (tester) async {
      events.events = [event('live', status: 'live'), event('next', startsAt: hours(24))];
      await pumpHome(tester);
      await tapVisible(tester, find.text('Event live'));
      expect(find.text('opened /events/live'), findsOneWidget);

      // Made private while it was open: the page left, and the server no
      // longer lists it.
      events.events = [event('next', startsAt: hours(24))];
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(find.text('Event live'), findsNothing);
      expect(find.text('Event next'), findsOneWidget);
    });

    testWidgets('a running card says until when, with no status; a private one has a lock',
        (tester) async {
      events.events = [
        event('live', status: 'live', endsAt: hours(2), visibility: EventVisibility.private),
      ];
      await pumpHome(tester);
      expect(find.textContaining('Until '), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('with nothing live, the middle card says so', (tester) async {
      events.events = [event('past', status: 'ended'), event('next')];
      await pumpHome(tester);

      expect(find.text('Nothing live right now'), findsOneWidget);
      expect(page(tester), 0);
    });

    testWidgets("only your events: someone else's public one is left out", (tester) async {
      events.events = [event('mine', status: 'live'), event('theirs', status: 'live', member: false)];
      await pumpHome(tester);

      expect(find.text('Your events'), findsOneWidget);
      expect(find.text('Event mine'), findsOneWidget);
      expect(find.text('Event theirs'), findsNothing);
    });

    testWidgets('with no event of yours, one line says where to find some', (tester) async {
      events.events = [event('theirs', status: 'live', member: false)];
      await pumpHome(tester);

      expect(find.text('No events yet. Find one in Events, or create your own.'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('tapping an event opens its screen, as the Events tab does',
        (tester) async {
      await pumpHome(tester);

      await tester.tap(find.text('Event live'));
      await tester.pumpAndSettle();
      expect(find.text('opened /events/live'), findsOneWidget);
    });
  });

  group('friends bar', () {
    Finder bar() => find.byType(FriendsBar);

    testWidgets('Manage comes first and opens the friends list', (tester) async {
      await pumpHome(tester);

      final manage = find.bySemanticsLabel('Manage friends');
      expect(tester.getTopLeft(manage).dx, lessThan(tester.getTopLeft(find.text('trinity')).dx));
      expect(find.bySemanticsLabel('View all friends'), findsNothing); // only 2 friends

      await tapVisible(tester, manage);
      expect(find.text('opened /friends'), findsOneWidget);
    });

    testWidgets('tapping a friend opens their profile', (tester) async {
      await pumpHome(tester);

      await tapVisible(tester, find.text('morpheus'));
      expect(find.text('opened /users/u-3'), findsOneWidget);
    });

    testWidgets('past 20 friends, the row stops and ends with View all', (tester) async {
      users.friends = [
        for (var i = 0; i < 25; i++) FriendSummary(publicId: 'f-$i', displayName: 'Friend $i'),
      ];
      await pumpHome(tester);

      final viewAll = find.bySemanticsLabel('View all friends');
      await tester.scrollUntilVisible(
        viewAll,
        200,
        scrollable: find.descendant(of: bar(), matching: find.byType(Scrollable)),
      );
      expect(find.text('Friend 19'), findsOneWidget);
      expect(find.text('Friend 20'), findsNothing);

      await tapVisible(tester, viewAll);
      expect(find.text('opened /friends'), findsOneWidget);
    });
  });

  group('recent playlists', () {
    testWidgets('with none yet, says where they will come from', (tester) async {
      await pumpHome(tester);

      expect(find.text('Create a playlist in the Playlists tab.'), findsOneWidget);
    });

    testWidgets('shows the playlists and opens the one tapped', (tester) async {
      playlists.playlists = [
        for (var i = 0; i < 5; i++)
          PlaylistSummary(publicId: 'p-$i', name: 'Mix $i', songCount: 12),
      ];
      await pumpHome(tester);

      expect(find.text('Mix 0'), findsOneWidget);
      await tapVisible(tester, find.text('Mix 0'));
      expect(find.text('opened /playlists/p-0'), findsOneWidget);
    });

    testWidgets('back from a playlist that went private meanwhile: it is no longer shown',
        (tester) async {
      playlists.playlists = const [
        PlaylistSummary(publicId: 'p-0', name: 'Mix 0', songCount: 12),
        PlaylistSummary(publicId: 'p-1', name: 'Mix 1', songCount: 12),
      ];
      await pumpHome(tester);
      await tapVisible(tester, find.text('Mix 0'));

      // Made private while it was open: the page left, and the server no
      // longer lists it.
      playlists.playlists = const [PlaylistSummary(publicId: 'p-1', name: 'Mix 1', songCount: 12)];
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(find.text('Mix 0'), findsNothing);
      expect(find.text('Mix 1'), findsOneWidget);
    });

    testWidgets('a star marks the ones you own, a lock the private ones, as on the events',
        (tester) async {
      playlists.playlists = const [
        PlaylistSummary(publicId: 'mine', name: 'Mine', songCount: 3, viewerIsOwner: true),
        PlaylistSummary(publicId: 'shared', name: 'Shared', songCount: 3, isPrivate: true),
      ];
      events.events = const [];
      await pumpHome(tester);

      expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
      expect(find.bySemanticsLabel('Mine, yours'), findsOneWidget);
      expect(find.bySemanticsLabel('Shared, private'), findsOneWidget);
    });
  });

  testWidgets('a section that fails offers a retry; the others still show', (tester) async {
    users.failure = const NetworkError('offline');
    await pumpHome(tester);

    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);
    expect(find.text('Event live'), findsOneWidget);

    users.failure = null;
    await tapVisible(tester, find.text('Try again'));
    expect(find.text('trinity'), findsOneWidget);
  });

  testWidgets('See all opens the tab that holds the rest', (tester) async {
    await pumpHome(tester);
    await tapVisible(tester, find.text('See all').first);
    expect(find.text('opened /events'), findsOneWidget);

    await pumpHome(tester);
    await tapVisible(tester, find.text('See all').last);
    expect(find.text('opened /playlists'), findsOneWidget);
  });
}
