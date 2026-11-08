import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/music/player/song_player.dart';
import 'package:app/features/music/player/song_player_sheet.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/song/data/song_search_source.dart';
import 'package:app/features/music/song/presentation/widgets/song_search_sheet.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/pages/playlist_detail_page.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';
import '../music/fake_song_search_api.dart';
import 'fake_playlist_editor_api.dart';
import 'fake_playlist_settings_api.dart';

void main() {
  late FakePlaylistEditorApi api;
  late FakeSongSearchApi search;
  late SessionStore session;
  late FakePlaylistSettingsApi settings;

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

    api = FakePlaylistEditorApi()
      ..seed([song(11, 'Midnight City'), song(12, 'Harder'), song(13, 'Breathe')]);
    search = FakeSongSearchApi()
      ..catalogue = [
        found(42, 'One More Time', artist: 'Daft Punk'),
        found(12, 'Harder', artist: 'Daft Punk'),
      ];
    api.catalogue = {for (final t in search.catalogue) t.deezerId: t};
    settings = FakePlaylistSettingsApi(api, people: const [
      PlaylistMember(publicId: 'u-7', displayName: 'Trinity', role: PlaylistRole.owner),
    ]);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<PlaylistEditorApi>.value(value: api),
        Provider<PlaylistSettingsApi>.value(value: settings),
        Provider<SongSearchApi>.value(value: search),
        ChangeNotifierProvider<SongPlayer>(create: (_) => SongPlayer()),
      ],
      child: const MaterialApp(
        home: PlaylistDetailPage(publicId: 'p1'),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The titles of the rows, top to bottom.
  List<String> rowTitles(WidgetTester tester) {
    final titles = [
      for (final title in ['Midnight City', 'Harder', 'Breathe', 'One More Time'])
        for (final element in find.text(title).evaluate())
          if (find
              .ancestor(of: find.byWidget(element.widget), matching: find.byType(SongSearchSheet))
              .evaluate()
              .isEmpty)
            (title, tester.getTopLeft(find.byWidget(element.widget)).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (title, _) in titles) title];
  }

  Finder sheetField() =>
      find.descendant(of: find.byType(SongSearchSheet), matching: find.byType(TextField));

  /// The + of the search result showing [title].
  Finder plusOf(String title) => find.descendant(
        of: find.ancestor(
          of: find.descendant(of: find.byType(SongSearchSheet), matching: find.text(title)),
          matching: find.byType(ListTile),
        ),
        matching: find.byTooltip('Add'),
      );

  Future<void> openSheetAndSearch(WidgetTester tester, String query) async {
    await tester.tap(find.byTooltip('Add songs'));
    await tester.pumpAndSettle();
    await tester.enterText(sheetField(), query);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  /// Taps the + of [title] when the server will refuse it as a duplicate:
  /// its row keeps a spinner while the question is open, so the tree never
  /// settles until it is answered.
  Future<void> tapPlusExpectingQuestion(WidgetTester tester, String title) async {
    await tester.tap(plusOf(title));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // the dialog's entrance
  }

  Future<void> closeSheet(WidgetTester tester) async {
    // The barrier above the sheet, which takes 90% of the height.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the playlist: header and songs in order, with edit controls', (tester) async {
    await pumpPage(tester);

    expect(find.text('Road trip'), findsNWidgets(2)); // app bar and header
    expect(find.text('Public · Anyone who can see it can edit'), findsOneWidget);
    expect(find.text('3 songs · 1 min'), findsOneWidget);
    expect(find.text('Artist of Harder · 0:30'), findsOneWidget);
    expect(rowTitles(tester), ['Midnight City', 'Harder', 'Breathe']);

    expect(find.byTooltip('Add songs'), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(3));
    expect(find.byType(Dismissible), findsNWidgets(3));
  });

  testWidgets('the header says whose it is, with their face; "By you" for yours', (tester) async {
    await pumpPage(tester);
    expect(find.text('By Trinity'), findsOneWidget);
    expect(find.byType(UserAvatar), findsOneWidget);

    settings.people = const [
      PlaylistMember(publicId: 'u-1', displayName: 'Neo', role: PlaylistRole.owner),
    ];
    await tester.pumpWidget(const SizedBox());
    await pumpPage(tester);
    expect(find.text('By you'), findsOneWidget);
  });

  testWidgets("the header shows the first song's art, as the lists do", (tester) async {
    EventTrack withArt(int id, String title) => EventTrack(
          deezerId: id,
          title: title,
          artist: 'Artist of $title',
          duration: const Duration(seconds: 30),
          coverUrl: 'http://art.test/$id.jpg',
        );
    api.rows = [
      PlaylistEntry(id: 1, track: withArt(11, 'a')),
      PlaylistEntry(id: 2, track: withArt(12, 'b')),
    ];
    await pumpPage(tester);

    String? header() => tester.widget<PlaylistCover>(find.byType(PlaylistCover).first).url;
    expect(header(), 'http://art.test/11.jpg');
  });

  testWidgets('a viewer who may not edit sees the songs, and nothing to change them with',
      (tester) async {
    api
      ..canEdit = false
      ..editLicense = EditLicense.invitedOnly;
    await pumpPage(tester);

    expect(find.text('Public · Only invited people can edit'), findsOneWidget);
    expect(find.text('Only invited people can edit it. You can listen.'), findsOneWidget);
    expect(rowTitles(tester), ['Midnight City', 'Harder', 'Breathe']);
    expect(find.byTooltip('Add songs'), findsNothing);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.byType(Dismissible), findsNothing);
  });

  testWidgets('an empty playlist says how to fill it', (tester) async {
    api.rows = [];
    await pumpPage(tester);

    expect(find.text('No songs yet. Add one with +.'), findsOneWidget);
    expect(find.text('0 songs'), findsOneWidget);
  });

  testWidgets('a failed load offers to retry', (tester) async {
    api.failure = const NetworkError('offline');
    await pumpPage(tester);
    expect(find.text("Couldn't load this playlist."), findsOneWidget);

    api.failure = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(rowTitles(tester), ['Midnight City', 'Harder', 'Breathe']);
  });

  testWidgets('+ searches Deezer, and the song is added at the end', (tester) async {
    await pumpPage(tester);

    await openSheetAndSearch(tester, 'daft');
    expect(search.searches, ['daft']);
    expect(find.text('Songs are added at the end.'), findsOneWidget);
    // Already in the playlist: marked, but still addable.
    expect(find.text('In playlist'), findsOneWidget);
    expect(plusOf('Harder'), findsOneWidget);

    await tester.tap(plusOf('One More Time'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'add 42');
    expect(find.text('In playlist'), findsNWidgets(2), reason: 'the sheet stays open');

    await closeSheet(tester);
    expect(find.byType(SongSearchSheet), findsNothing);
    expect(rowTitles(tester), ['Midnight City', 'Harder', 'Breathe', 'One More Time']);
  });

  testWidgets('a song already there asks first, and "Add it" adds it again', (tester) async {
    await pumpPage(tester);
    await openSheetAndSearch(tester, 'harder');

    await tapPlusExpectingQuestion(tester, 'Harder');
    expect(find.text('Song already present in the playlist. Add it still?'), findsOneWidget);
    expect(api.calls.last, 'add 12');
    // Not a delete's red: adding it again harms nothing.
    expect(tester.widget<ConfirmDialog>(find.byType(ConfirmDialog)).isDestructive, isFalse);

    await tester.tap(find.text('Add it'));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'add 12 again');
    expect(find.text('In playlist ×2'), findsOneWidget);
    await closeSheet(tester);
    expect(find.text('Harder'), findsNWidgets(2));
  });

  testWidgets('"Cancel" leaves the playlist as it was', (tester) async {
    await pumpPage(tester);
    await openSheetAndSearch(tester, 'harder');

    await tapPlusExpectingQuestion(tester, 'Harder');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(api.calls.where((c) => c.startsWith('add')), ['add 12']);
    expect(find.byType(AlertDialog), findsNothing);
    await closeSheet(tester);
    expect(find.text('Harder'), findsOneWidget);
  });

  testWidgets('someone else adding the same song first also asks', (tester) async {
    await pumpPage(tester);
    await openSheetAndSearch(tester, 'one more');
    expect(find.text('In playlist'), findsNothing, reason: 'not there at the last read');

    // Added by someone else since: the server refuses, so the question comes.
    api.othersEdit((rows) => rows.add(PlaylistEntry(id: 60, track: song(42, 'One More Time'))));
    await tapPlusExpectingQuestion(tester, 'One More Time');
    expect(find.text('Song already present in the playlist. Add it still?'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('a refused add shows why, inside the sheet', (tester) async {
    await pumpPage(tester);
    await openSheetAndSearch(tester, 'one more');

    api.failNext = const UnauthorizedError('permission denied');
    await tester.tap(plusOf('One More Time'));
    await tester.pumpAndSettle();
    expect(find.text("You can't edit this playlist."), findsOneWidget);
  });

  testWidgets('dragging a song by its handle moves it, after the song now above it',
      (tester) async {
    await pumpPage(tester);

    // "Breathe" (third) dragged above "Harder" (second).
    final handle = find.byIcon(Icons.drag_handle).at(2);
    final rowHeight = tester.getSize(find.byType(ListTile).first).height;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 100));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(Offset(0, -rowHeight * 0.1));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(api.calls.last, 'move 3 after 1');
    expect(rowTitles(tester), ['Midnight City', 'Breathe', 'Harder']);
  });

  testWidgets('a move under a song someone else removed says so, and shows the list as it is',
      (tester) async {
    await pumpPage(tester);
    api.othersEdit((rows) => rows.removeAt(0)); // "Midnight City", still on screen

    final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
    list.onReorderItem!(2, 1); // "Breathe" under "Midnight City"
    await tester.pumpAndSettle();

    expect(
      find.text('Someone else just changed this part of the playlist. The list is up to date now.'),
      findsOneWidget,
    );
    expect(rowTitles(tester), ['Harder', 'Breathe']);
  });

  testWidgets('swiping a song away removes it', (tester) async {
    await pumpPage(tester);

    await tester.drag(find.text('Harder'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(api.calls.last, 'remove 2');
    expect(find.text('Removed Harder'), findsOneWidget);
    expect(rowTitles(tester), ['Midnight City', 'Breathe']);
    expect(find.text('2 songs · 1 min'), findsOneWidget);
  });

  testWidgets('made private under the open player: the player closes, empty, and the page leaves',
      (tester) async {
    // No audio plugin under `flutter test`: its channel answers empty maps,
    // and the songs stay silent.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.just_audio.methods'), (_) async => <String, dynamic>{});
    tester.view
      ..physicalSize = const Size(800, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = SongPlayer();
    final router = GoRouter(initialLocation: playlistsRoute, routes: [
      GoRoute(path: playlistsRoute, builder: (context, state) => const Scaffold(body: Text('All playlists'))),
      GoRoute(path: '$playlistsRoute/:id', builder: (context, state) => PlaylistDetailPage(publicId: state.pathParameters['id']!)),
    ]);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<PlaylistEditorApi>.value(value: api),
        Provider<PlaylistSettingsApi>.value(value: settings),
        Provider<SongSearchApi>.value(value: search),
        ChangeNotifierProvider<SongPlayer>.value(value: player),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    router.push('$playlistsRoute/p1');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Harder'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiniPlayerBar));
    await tester.pumpAndSettle();
    expect(player.current?.title, 'Harder');

    api.loseAccess();
    await tester.pumpAndSettle();

    expect(player.current, isNull);
    expect(find.text('All playlists'), findsOneWidget);
    expect(find.byType(PlaylistDetailPage), findsNothing);
    expect(find.text("You can't see this playlist any more."), findsOneWidget);
  });
}
