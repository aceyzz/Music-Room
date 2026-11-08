import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/pages/profile_page.dart';

import '../auth/fake_auth_api.dart';
import '../auth/fake_linked_accounts_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';

// The page alone, not through the router: reaching it from the tabs is
// covered in test/widget_test.dart.
void main() {
  late FakeAuthApi api;
  late FakeUserApi users;
  late SessionStore session;
  late CurrentUserStore currentUser;

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi()..emailVerified = true;
    users = FakeUserApi()
      ..profile = const UserProfile(
        publicId: 'u-1',
        displayName: 'neo',
        firstName: 'Thomas',
        city: 'Zion',
        visibility: {ProfileField.firstName: ProfileVisibility.friends},
      );
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: api,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
      users: users,
    );
    await session.start();
    await session.login(email: 'neo@example.test', password: 'password1234');
    // Not started: it would load the profile itself, and these tests count
    // the page's calls. The page only pushes into it.
    currentUser = CurrentUserStore(users, session);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<UserApi>.value(value: users),
        Provider<CurrentUserStore>.value(value: currentUser),
        Provider<LinkedAccountsApi>.value(value: FakeLinkedAccountsApi()),
        // No provider configured: linking is covered in widget_test.dart.
        Provider<OAuthBrowserFlow>.value(
          value: OAuthBrowserFlow(const OAuthConfig(
            clientIds: {},
            redirectUri: 'http://localhost:8081/oauth/callback',
            callbackScheme: 'musicroom',
            platformSupported: true,
          )),
        ),
      ],
      child: const MaterialApp(home: ProfilePage()),
    ));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  testWidgets('loads the profile into the form', (tester) async {
    await pumpPage(tester);

    expect(users.calls, ['getProfile']);
    expect(find.text('neo'), findsOneWidget);
    expect(find.text('neo@example.test'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Thomas'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Zion'), findsOneWidget);
  });

  testWidgets('offers to change the password', (tester) async {
    await pumpPage(tester);

    expect(find.widgetWithText(TextButton, 'Change password'), findsOneWidget);
  });

  testWidgets('what the page loads and saves reaches the top bar', (tester) async {
    await pumpPage(tester);
    expect(currentUser.profile.value?.city, 'Zion');

    await tester.enterText(field('City'), 'Mega City');
    await tester.pumpAndSettle(); // the focused field scrolls itself back into view
    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(users.updates, hasLength(1));
    expect(currentUser.profile.value?.city, 'Mega City');
  });

  testWidgets('saving sends the edited details and every visibility scope', (tester) async {
    await pumpPage(tester);

    await tester.enterText(field('Bio'), 'Wake up');
    await tester.enterText(field('Country'), 'fr');
    // Otherwise the focused field scrolls itself back into view, taking the
    // dropdown below off screen.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    // First name: Friends -> Only me.
    final dropdown = find.byType(DropdownButton<ProfileVisibility>).first;
    await tester.ensureVisible(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Only me').last);
    await tester.pumpAndSettle();

    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final (publicId, sent) = users.updates.single;
    expect(publicId, 'u-1');
    expect(sent.bio, 'Wake up');
    expect(sent.countryCode, 'FR');
    expect(sent.firstName, 'Thomas'); // unchanged, sent as is
    expect(sent.visibility[ProfileField.firstName], ProfileVisibility.private);
    expect(sent.visibility.keys, unorderedEquals(ProfileField.values));
    expect(find.text('Profile saved.'), findsOneWidget);
  });

  testWidgets('picking genres saves them as music preferences', (tester) async {
    await pumpPage(tester);

    for (final genre in ['Jazz', 'Rock']) {
      final chip = find.widgetWithText(FilterChip, genre);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }
    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(users.calls, contains('setMusicPreferences'));
    expect(
      users.profile.musicPreferences.map((p) => p.genreName),
      unorderedEquals(['Jazz', 'Rock']),
    );
    expect(find.text('Profile saved.'), findsOneWidget);
  });

  testWidgets('saving without touching the genres does not send them', (tester) async {
    await pumpPage(tester);

    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(users.calls, isNot(contains('setMusicPreferences')));
  });

  testWidgets('emptying a field clears it', (tester) async {
    await pumpPage(tester);

    await tester.enterText(field('City'), '');
    await tester.pumpAndSettle(); // the focused field scrolls itself back into view
    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();

    final (_, sent) = users.updates.single;
    expect(sent.city, isNull);
    expect(sent.clearsBlanks, isTrue);
    expect(users.profile.city, isNull);
    expect(find.widgetWithText(TextFormField, 'Zion'), findsNothing);
    expect(find.text('Profile saved.'), findsOneWidget);
  });

  testWidgets('the avatar menu offers removal only when there is a picture', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.bySemanticsLabel('Change profile picture'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a picture'), findsOneWidget);
    expect(find.text('Remove picture'), findsNothing);
  });

  testWidgets('a failed load offers a retry', (tester) async {
    users.failure = const NetworkError('offline');
    await pumpPage(tester);

    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);

    users.failure = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Thomas'), findsOneWidget);
  });
}
