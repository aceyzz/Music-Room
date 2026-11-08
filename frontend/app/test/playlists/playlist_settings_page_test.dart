import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/pages/playlist_settings_page.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';
import '../user/fake_social_api.dart';
import 'fake_playlist_editor_api.dart';
import 'fake_playlist_settings_api.dart';

void main() {
  late FakePlaylistEditorApi playlist;
  late FakePlaylistSettingsApi settings;
  late FakeSocialApi social;
  late SessionStore session;

  // The signed-in user is u-1 (FakeAuthApi).
  PlaylistMember member(String id, PlaylistRole role) =>
      PlaylistMember(publicId: id, displayName: 'Name $id', role: role);

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
    playlist = FakePlaylistEditorApi();
    settings = FakePlaylistSettingsApi(playlist);
    social = FakeSocialApi();
  });

  Future<void> pumpPage(WidgetTester tester, List<PlaylistMember> people) async {
    settings.people = people;
    tester.view
      ..physicalSize = const Size(412, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/playlists/p1/settings',
      routes: [
        GoRoute(
          path: '/playlists/:id/settings',
          builder: (context, state) => PlaylistSettingsPage(publicId: state.pathParameters['id']!),
        ),
        GoRoute(
          path: '/users/:id',
          builder: (context, state) => Text('profile ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<PlaylistEditorApi>.value(value: playlist),
        Provider<PlaylistSettingsApi>.value(value: settings),
        Provider<SocialApi>.value(value: social),
      ],
      // The app's theme: its full-width filled buttons broke rows before.
      child: MaterialApp.router(theme: AppTheme.lightTheme(), routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the name, the settings and the people, owner first', (tester) async {
    await pumpPage(tester, [member('u-1', PlaylistRole.owner), member('u-2', PlaylistRole.editor)]);

    expect(find.text('Road trip'), findsOneWidget);
    expect(find.text('Invited people (2)'), findsOneWidget);
    expect(find.text('Name u-1 (you)'), findsOneWidget);
    expect(find.text('Name u-2'), findsOneWidget);
  });

  testWidgets('the owner switches visibility and licence, and the page shows it', (tester) async {
    await pumpPage(tester, [member('u-1', PlaylistRole.owner)]);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(EditLicense.invitedOnly.label));
    await tester.pumpAndSettle();

    expect(settings.calls, ['visibility private', 'license invited_only']);
    expect(find.text(PlaylistVisibility.private.description), findsOneWidget);
  });

  testWidgets('the owner renames it', (tester) async {
    await pumpPage(tester, [member('u-1', PlaylistRole.owner)]);

    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Summer');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(settings.calls, ['rename Summer']);
    expect(find.text('Summer'), findsOneWidget);
  });

  testWidgets('the list says Owner or Invited, as the subject does', (tester) async {
    await pumpPage(tester, [
      member('u-1', PlaylistRole.owner),
      member('u-2', PlaylistRole.editor),
      member('u-3', PlaylistRole.admin),
    ]);

    expect(find.text('Invited people (3)'), findsOneWidget);
    expect(find.text('Owner'), findsOneWidget);
    // An admin (set by no screen) reads as invited, like everyone else.
    expect(find.text('Invited'), findsNWidgets(2));
  });

  testWidgets('a viewer sees everything but changes nothing', (tester) async {
    await pumpPage(tester, [member('u-9', PlaylistRole.owner), member('u-1', PlaylistRole.viewer)]);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(settings.calls, isEmpty);
    expect(find.text('Only its owner can change these.'), findsOneWidget);
    expect(find.text('Invite'), findsNothing);
    expect(find.text('Delete playlist'), findsNothing);
  });

  testWidgets('invite lists the friends not in it yet, and adds the one picked', (tester) async {
    social.friendList = const [
      FriendSummary(publicId: 'u-2', displayName: 'Already in'),
      FriendSummary(publicId: 'u-3', displayName: 'Trinity'),
    ];
    await pumpPage(tester, [member('u-1', PlaylistRole.owner), member('u-2', PlaylistRole.editor)]);

    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    expect(find.text('Already in'), findsNothing);
    await tester.tap(find.text('Trinity'));
    await tester.pumpAndSettle();

    expect(settings.calls, ['invite u-3']);
    expect(find.text('Invited people (3)'), findsOneWidget);
  });

  testWidgets('a refused change says why', (tester) async {
    await pumpPage(tester, [member('u-1', PlaylistRole.owner)]);
    settings.failure = const UnauthorizedError('permission denied');

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(find.text("You can't change this playlist."), findsOneWidget);
  });

  testWidgets('the owner deletes it after saying yes', (tester) async {
    await pumpPage(tester, [member('u-1', PlaylistRole.owner)]);

    await tester.tap(find.text('Delete playlist'));
    await tester.pumpAndSettle();
    expect(settings.deleted, isFalse, reason: 'asks first');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(settings.deleted, isTrue);
  });

  testWidgets('a member opens their profile', (tester) async {
    await pumpPage(tester, [member('u-1', PlaylistRole.owner), member('u-2', PlaylistRole.editor)]);

    await tester.tap(find.text('Name u-2'));
    await tester.pumpAndSettle();

    expect(find.text('profile u-2'), findsOneWidget);
  });

  testWidgets('the licence says, in words, who edits', (tester) async {
    playlist.editLicense = EditLicense.invitedOnly;
    await pumpPage(tester, [member('u-1', PlaylistRole.owner)]);
    expect(find.text(EditLicense.invitedOnly.description), findsOneWidget);

    await tester.tap(find.text(EditLicense.everyone.label));
    await tester.pumpAndSettle();
    expect(find.text(EditLicense.everyone.description), findsOneWidget);
  });
}
