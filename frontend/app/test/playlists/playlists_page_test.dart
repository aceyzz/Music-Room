import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/playlist/presentation/stores/library_store.dart';
import 'package:app/features/music/playlist/presentation/widgets/library_playlist_tile.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/pages/playlists_page.dart';

import '../auth/fake_auth_api.dart';
import '../home/fake_home_apis.dart';
import '../mocks/mock_flutter_secure_storage.dart';

// The page under a small router: /playlists reads the pill from the address
// as the app's route does, and /playlists/:id only says where it is.
void main() {
  late FakePlaylistApi playlists;
  late SessionStore session;

  final library = [
    libraryPlaylist('mine', editors: 3, songs: 24),
    libraryPlaylist('shared',
        relation: PlaylistRelation.shared, owner: 'trinity', visibility: PlaylistVisibility.private),
    libraryPlaylist('shared-friend',
        relation: PlaylistRelation.shared, owner: 'morpheus', ownerIsFriend: true),
    libraryPlaylist('friend',
        relation: PlaylistRelation.friend, owner: 'morpheus', ownerIsFriend: true, songs: 1),
  ];

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final api = FakeAuthApi()..emailVerified = true;
    playlists = FakePlaylistApi()
      ..libraryPlaylists = library
      ..publicPlaylistsByQuery = {
        '': [
          for (var i = 0; i < 3; i++)
            libraryPlaylist('pub$i', relation: PlaylistRelation.public, owner: 'smith'),
        ],
        'rock': [libraryPlaylist('rock', relation: PlaylistRelation.public, owner: 'smith')],
      };
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

  Future<void> pumpPage(WidgetTester tester, {String location = '/playlists'}) async {
    final router = GoRouter(initialLocation: location, routes: [
      GoRoute(
        path: '/playlists',
        builder: (context, state) => PlaylistsPage(
          filter: LibraryFilter.fromQuery(state.uri.queryParameters['filter']),
        ),
      ),
      GoRoute(
        path: '/playlists/:id',
        builder: (context, state) => Scaffold(body: Text('opened ${state.uri.path}')),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<CurrentUserStore>.value(value: CurrentUserStore(FakeUserApi(), session)),
        Provider<PlaylistApi>.value(value: playlists),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  Finder pill(String label) => find.widgetWithText(ChoiceChip, label);

  bool selected(WidgetTester tester, String label) =>
      tester.widget<ChoiceChip>(pill(label)).selected;

  List<String> shown(WidgetTester tester) => tester
      .widgetList<LibraryPlaylistTile>(find.byType(LibraryPlaylistTile))
      .map((t) => t.playlist.publicId)
      .toList();

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the Library: all of it, with what each row is', (tester) async {
    await pumpPage(tester);

    expect(selected(tester, 'Library'), isTrue);
    expect(shown(tester), ['mine', 'shared', 'shared-friend', 'friend']);
    expect(find.text('Playlist mine'), findsOneWidget);
    // Whose it is, the star says (and the playlist's page): the row, how
    // many edit it and how long it is.
    expect(find.text('3 editors · 24 songs'), findsOneWidget);
    expect(find.text('1 editor · 1 song'), findsOneWidget);
    expect(find.textContaining('Shared by'), findsNothing);
    // A star on the one they own, a lock on the private one, as on the events.
    expect(find.byIcon(Icons.star_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byType(TextField), findsNothing); // the search is Public's
  });

  testWidgets('back from Public, the Library is as it was loaded', (tester) async {
    await pumpPage(tester);

    await tap(tester, pill('Public'));
    expect(selected(tester, 'Public'), isTrue);
    await tap(tester, pill('Library'));
    expect(selected(tester, 'Library'), isTrue);
    expect(shown(tester), hasLength(4));
    expect(playlists.calls.where((c) => c == 'library'), hasLength(1));
  });

  testWidgets('the top bar\'s Refresh reloads the list of the pill shown', (tester) async {
    await pumpPage(tester);
    await tap(tester, find.byTooltip('Refresh'));
    expect(playlists.calls, ['library', 'library']);

    await tap(tester, pill('Public'));
    playlists.calls.clear();
    await tap(tester, find.byTooltip('Refresh'));
    expect(playlists.calls, ['publicPlaylists()']);
  });

  testWidgets('the address picks the pill; an old one opens the Library', (tester) async {
    await pumpPage(tester, location: '/playlists?filter=public');
    expect(selected(tester, 'Public'), isTrue);
  });

  testWidgets('each pill says what it would hold when empty', (tester) async {
    playlists.libraryPlaylists = const [];
    playlists.publicPlaylistsByQuery = const {};
    await pumpPage(tester);

    expect(find.text("Your playlists, the ones shared with you and your friends' show up here."),
        findsOneWidget);
    await tap(tester, pill('Public'));
    expect(find.text('No public playlists yet.'), findsOneWidget);
  });

  testWidgets('Public lists public playlists and searches them as you type', (tester) async {
    await pumpPage(tester);

    await tap(tester, pill('Public'));
    expect(shown(tester), ['pub0', 'pub1', 'pub2']);
    expect(find.text('1 editor · 0 songs'), findsNWidgets(3));

    await tester.enterText(find.byType(TextField), 'rock');
    await tester.pump(LibraryStore.searchDelay);
    await tester.pumpAndSettle();
    expect(shown(tester), ['rock']);

    await tester.enterText(find.byType(TextField), 'jazz');
    await tester.pump(LibraryStore.searchDelay);
    await tester.pumpAndSettle();
    expect(find.text('No public playlist matches “jazz”.'), findsOneWidget);

    await tap(tester, find.byTooltip('Clear search'));
    await tester.pump(LibraryStore.searchDelay);
    await tester.pumpAndSettle();
    expect(shown(tester), ['pub0', 'pub1', 'pub2']);
    expect(playlists.calls, [
      'library',
      'publicPlaylists()',
      'publicPlaylists(rock)',
      'publicPlaylists(jazz)',
      'publicPlaylists()'
    ]);
  });

  testWidgets('My taste keeps the playlists of people with your taste, and lets go',
      (tester) async {
    playlists.publicPlaylistsByQuery = {
      '': [
        libraryPlaylist('jazz', relation: PlaylistRelation.public, owner: 'smith'),
        libraryPlaylist('rock', relation: PlaylistRelation.public, owner: 'smith'),
      ],
      'taste:': [libraryPlaylist('jazz', relation: PlaylistRelation.public, owner: 'smith')],
    };
    await pumpPage(tester);
    await tap(tester, pill('Public'));
    expect(shown(tester), ['jazz', 'rock']);

    await tap(tester, find.text('My taste'));
    expect(shown(tester), ['jazz']);

    await tap(tester, find.text('My taste'));
    expect(shown(tester), ['jazz', 'rock']);
    expect(playlists.calls.where((c) => c.startsWith('publicPlaylists')), [
      'publicPlaylists()',
      'publicPlaylists(, my taste)',
      'publicPlaylists()',
    ]);
  });

  testWidgets('My taste with nothing to show says where tastes come from', (tester) async {
    playlists.publicPlaylistsByQuery = const {};
    await pumpPage(tester);
    await tap(tester, pill('Public'));

    await tap(tester, find.text('My taste'));
    expect(
      find.text('No public playlist by someone with your taste. '
          'Your music preferences, in your profile, decide what matches.'),
      findsOneWidget,
    );
  });

  testWidgets('Public loads the next page when the list reaches its end', (tester) async {
    playlists.publicPlaylistsByQuery = {
      '': [
        for (var i = 0; i < LibraryStore.pageSize + 2; i++)
          libraryPlaylist('pub$i', relation: PlaylistRelation.public, owner: 'smith'),
      ],
    };
    await pumpPage(tester, location: '/playlists?filter=public');
    expect(playlists.calls, ['library', 'publicPlaylists()']);

    // The list, not the pill row, which scrolls too.
    final list =
        find.descendant(of: find.byType(RefreshIndicator), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('Playlist pub${LibraryStore.pageSize + 1}'), 300,
        scrollable: list);
    await tester.pumpAndSettle();
    expect(playlists.calls, ['library', 'publicPlaylists()', 'publicPlaylists(, 30)']);
  });

  testWidgets('a failed load says so, and Try again recovers', (tester) async {
    playlists.failure = const NetworkError('offline');
    await pumpPage(tester);

    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);

    playlists.failure = null;
    await tap(tester, find.text('Try again'));
    expect(shown(tester), hasLength(4));
  });

  testWidgets('tapping a playlist opens it', (tester) async {
    await pumpPage(tester);

    await tap(tester, find.text('Playlist friend'));
    expect(find.text('opened /playlists/friend'), findsOneWidget);
  });

  group('create playlist', () {
    Finder createButton() => find.widgetWithText(FilledButton, 'Create playlist');
    Finder nameField() => find.widgetWithText(TextFormField, 'Name');

    Future<void> openSheet(WidgetTester tester) async {
      await tap(tester, createButton());
      expect(find.text('New playlist'), findsOneWidget);
    }

    testWidgets('the button sits right below the pills, on every pill', (tester) async {
      await pumpPage(tester);

      final button = tester.getRect(createButton());
      expect(button.top, greaterThanOrEqualTo(tester.getRect(pill('Library')).bottom));
      expect(button.bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(LibraryPlaylistTile).first).top));

      await tap(tester, pill('Public'));
      expect(createButton(), findsOneWidget);
      expect(tester.getRect(createButton()).bottom,
          lessThanOrEqualTo(tester.getRect(find.byType(TextField)).top));
    });

    testWidgets('a name is required', (tester) async {
      await pumpPage(tester);
      await openSheet(tester);

      await tap(tester, find.widgetWithText(FilledButton, 'Create'));
      expect(find.text('Give your playlist a name.'), findsOneWidget);
      expect(playlists.created, isEmpty);
    });

    testWidgets('creating sends the choices, opens the playlist, and lists it first',
        (tester) async {
      await pumpPage(tester);
      await openSheet(tester);

      await tester.enterText(nameField(), '  Road trip ');
      await tap(tester, find.text('Private'));
      expect(find.text(PlaylistVisibility.private.description), findsOneWidget);
      await tap(tester, find.text('Only invited people'));
      await tap(tester, find.widgetWithText(FilledButton, 'Create'));

      expect(playlists.created.single, (
        owner: 'u-1',
        name: 'Road trip',
        visibility: PlaylistVisibility.private,
        editLicense: EditLicense.invitedOnly
      ));
      expect(find.text('opened /playlists/new-1'), findsOneWidget);

      GoRouter.of(tester.element(find.text('opened /playlists/new-1'))).pop();
      await tester.pumpAndSettle();
      expect(shown(tester).first, 'new-1');
      // Theirs, so a star on the new row.
      final row = find.widgetWithText(ListTile, 'Road trip');
      expect(find.descendant(of: row, matching: find.byIcon(Icons.star_outline_rounded)),
          findsOneWidget);
    });

    testWidgets('a refusal keeps the form open with the message and what was typed',
        (tester) async {
      await pumpPage(tester);
      await openSheet(tester);
      playlists.failure = const NetworkError('offline');

      await tester.enterText(nameField(), 'Road trip');
      await tap(tester, find.widgetWithText(FilledButton, 'Create'));

      expect(find.text('New playlist'), findsOneWidget);
      expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Road trip'), findsOneWidget);
      expect(shown(tester), hasLength(4));
    });
  });
}
