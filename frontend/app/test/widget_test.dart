import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/device/device_info.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/core/models/user/user_profile.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:app/features/user/presentation/widgets/profile_button.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/main.dart';
import 'package:app/pages/events_page.dart';
import 'package:app/pages/forgot_password_page.dart';
import 'package:app/pages/home_page.dart';
import 'package:app/pages/login_page.dart';
import 'package:app/pages/playlists_page.dart';
import 'package:app/pages/profile_page.dart';
import 'package:app/pages/register_page.dart';
import 'package:app/pages/verify_email_page.dart';

import 'auth/fake_auth_api.dart';
import 'auth/fake_linked_accounts_api.dart';
import 'device/fake_delegation_api.dart';
import 'device/fake_device_api.dart';
import 'events/fake_event_info_api.dart';
import 'events/fake_live_event_api.dart';
import 'home/fake_home_apis.dart';
import 'mocks/mock_flutter_secure_storage.dart';
import 'music/fake_song_search_api.dart';
import 'playlists/fake_playlist_editor_api.dart';
import 'playlists/fake_playlist_settings_api.dart';
import 'events/fake_event_settings_api.dart';
import 'user/fake_social_api.dart';

void main() {
  late FakeAuthApi api;
  late AppNetwork appNetwork;
  late FakeUserApi users;
  late SessionStore store;
  late FakePlaylistApi playlists;
  late FakeLinkedAccountsApi linkedAccounts;

  /// The login window behind Profile, Linked accounts: Google only, and it
  /// always comes back with a code.
  final linkFlow = OAuthBrowserFlow(
    const OAuthConfig(
      clientIds: {OAuthProvider.google: 'google-id'},
      redirectUri: 'http://localhost:8081/oauth/callback',
      callbackScheme: 'musicroom',
      platformSupported: true,
    ),
    authenticate: ({required url, required callbackUrlScheme, options}) async =>
        'musicroom://oauth?code=link-code&state=${Uri.parse(url).queryParameters['state']}',
  );

  // Nothing here uses the network (the fakes replace it), only its
  // SessionCredentials.
  setUpAll(() async {
    appNetwork = await AppNetwork.connect();
  });

  SessionStore newStore({OAuthBrowserFlow? oauth}) => SessionStore(
        SessionRepository(
          api: api,
          storage: TokenStorageService(),
          credentials: appNetwork.credentials,
          devSessionToken: '',
        ),
        appNetwork.credentials,
        users: users,
        oauth: oauth,
      );

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    api = FakeAuthApi();
    users = FakeUserApi(api.calls);
    linkedAccounts = FakeLinkedAccountsApi();
    appNetwork.credentials.clear();
    store = SessionStore(
      SessionRepository(
        api: api,
        storage: TokenStorageService(),
        credentials: appNetwork.credentials,
        devSessionToken: '',
      ),
      appNetwork.credentials,
      users: users,
    );
    await store.start();
  });

  Future<void> pumpApp(WidgetTester tester) async {
    playlists = FakePlaylistApi()..libraryPlaylists = [libraryPlaylist('mine')];
    // Built here, not in setUp: some tests replace [store].
    final currentUser = CurrentUserStore(users, store)..start();
    addTearDown(currentUser.stop);
    final device = DeviceStore(
      FakeDeviceApi(),
      store,
      () async => 'install-1',
      DeviceInfo.fallback(),
    )..start();
    addTearDown(device.stop);
    await tester.pumpWidget(
      MyApp(
        appNetwork: appNetwork,
        sessionStore: store,
        currentUserStore: currentUser,
        deviceStore: device,
        userApi: users,
        socialApi: FakeSocialApi(),
        eventApi: FakeEventApi(),
        liveEventApi: FakeLiveEventApi(),
        eventInfoApi: FakeEventInfoApi(),
        eventSettingsApi: FakeEventSettingsApi(event('e1')),
        playlistApi: playlists,
        playlistEditorApi: FakePlaylistEditorApi(),
        playlistSettingsApi: FakePlaylistSettingsApi(FakePlaylistEditorApi()),
        songSearchApi: FakeSongSearchApi(),
        linkedAccountsApi: linkedAccounts,
        oauthFlow: linkFlow,
        delegationApi: FakeDelegationApi(),
        router: createAppRouter(store),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a signed-out launch lands on the login page', (tester) async {
    await pumpApp(tester);

    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('logging in with an unverified email opens the verification page',
      (tester) async {
    await pumpApp(tester);

    await tester.enterText(find.byType(TextFormField).at(0), 'neo@example.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'password1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(api.calls, ['login']);
    expect(find.byType(VerifyEmailPage), findsOneWidget);
  });

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).at(0), 'neo@example.test');
    await tester.enterText(find.byType(TextFormField).at(1), 'password1234');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
  }

  group('signed in, the tabs', () {
    setUp(() => api.emailVerified = true);

    Finder profileButton() => find.byType(ProfileButton);

    testWidgets('a verified login lands on Home, with the user in the top bar', (tester) async {
      await pumpApp(tester);
      await signIn(tester);

      expect(find.byType(HomePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.descendant(of: profileButton(), matching: find.text('neo')), findsOneWidget);
      // getProfile: the top bar's picture. getFriends: the Home friends row.
      expect(api.calls, containsAll(['login', 'getProfile', 'getFriends']));
    });

    testWidgets('each tab shows its page', (tester) async {
      await pumpApp(tester);
      await signIn(tester);

      for (final (label, page) in [
        ('Playlists', PlaylistsPage),
        ('Events', EventsPage),
        ('Home', HomePage),
      ]) {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
        await tester.pumpAndSettle();
        expect(find.byType(page), findsOneWidget, reason: label);
        expect(profileButton(), findsOneWidget, reason: label);
      }
      expect(find.byType(PlaylistsPage), findsNothing); // kept alive, but offstage
    });

    testWidgets('the Playlists tab always opens on the Library, keeping what it loaded', (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      Future<void> tapTab(String label) async {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
        await tester.pumpAndSettle();
      }

      bool selected(String label) =>
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label)).selected;

      await tapTab('Playlists');
      expect(selected('Library'), isTrue);

      await tester.tap(find.widgetWithText(ChoiceChip, 'Public'));
      await tester.pumpAndSettle();
      expect(selected('Public'), isTrue);

      await tapTab('Home');
      await tapTab('Playlists');
      expect(selected('Library'), isTrue);
      // Loaded on first opening, then again on coming back: what changed in
      // another tab shows.
      expect(playlists.calls.where((c) => c == 'library'), hasLength(2));
    });

    testWidgets('back on Home, it reloads: what changed in another tab shows', (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      Future<void> tapTab(String label) async {
        await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
        await tester.pumpAndSettle();
      }

      int homeLoads() => playlists.calls.where((c) => c == 'recentPlaylists').length;
      final first = homeLoads();
      await tapTab('Events');
      expect(homeLoads(), first, reason: 'leaving Home loads nothing');
      await tapTab('Home');
      expect(homeLoads(), first + 1);
    });

    testWidgets('the Events tab has two pills, Current selected', (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Events')));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Create event'), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNWidgets(2));
      expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Current')).selected, isTrue);
    });

    testWidgets('the profile button opens the profile full screen; back returns to the tab',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('Events')));
      await tester.pumpAndSettle();

      await tester.tap(profileButton());
      await tester.pumpAndSettle();
      expect(find.byType(ProfilePage), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EventsPage), findsOneWidget);
    });

    testWidgets('the profile links a Google account, and unlinks it', (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      await tester.tap(profileButton());
      await tester.pumpAndSettle();

      Finder inRow(String provider, String text) => find.descendant(
            of: find.widgetWithText(ListTile, provider),
            matching: find.text(text),
          );
      expect(inRow('Google', 'Not linked'), findsOneWidget);
      // Facebook is hidden (no Meta app was registered): no row at all.
      expect(find.widgetWithText(ListTile, 'Facebook'), findsNothing);

      await tester.ensureVisible(inRow('Google', 'Link'));
      await tester.pumpAndSettle();
      await tester.tap(inRow('Google', 'Link'));
      await tester.pumpAndSettle();

      expect(linkedAccounts.lastLink?.code, 'link-code');
      expect(inRow('Google', 'google@example.test'), findsOneWidget);

      await tester.tap(inRow('Google', 'Unlink'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Unlink')));
      await tester.pumpAndSettle();

      expect(linkedAccounts.linked, isEmpty);
      expect(inRow('Google', 'Not linked'), findsOneWidget);
    });

    testWidgets('a picture changed since sign-in shows once the profile page has loaded it',
        (tester) async {
      await pumpApp(tester);
      await signIn(tester);
      String? avatarUrl() => tester
          .widget<UserAvatar>(find.descendant(of: profileButton(), matching: find.byType(UserAvatar)))
          .url;
      expect(avatarUrl(), isNull);

      users.profile = const UserProfile(
        publicId: 'u-1',
        displayName: 'neo',
        avatarUrl: 'http://media.test/avatars/1.png',
        visibility: {},
      );
      await tester.tap(profileButton());
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(avatarUrl(), 'http://media.test/avatars/1.png');
    });
  });

  Future<void> tapText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle(); // lay out the scroll before tapping
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> fill(WidgetTester tester, String label, String text) async {
    final finder = find.widgetWithText(TextFormField, label);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.enterText(finder, text);
  }

  testWidgets('the login page links to sign-up and password reset, and back', (tester) async {
    await pumpApp(tester);

    await tapText(tester, 'Sign up');
    expect(find.byType(RegisterPage), findsOneWidget);

    await tapText(tester, 'Already have an account? Sign in');
    await tapText(tester, 'Forgot your password?');
    expect(find.byType(ForgotPasswordPage), findsOneWidget);

    await tapText(tester, 'Back to sign in');
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('signing up with profile details saves them, then asks for the code',
      (tester) async {
    await pumpApp(tester);
    await tapText(tester, 'Sign up');

    await fill(tester, 'Email', 'neo@example.test');
    await fill(tester, 'Display name', 'neo');
    await fill(tester, 'Password', 'password1234');
    await fill(tester, 'Confirm password', 'password1234');
    await fill(tester, 'First name', 'Thomas');
    await fill(tester, 'Country', 'fr');
    await tapText(tester, 'Create account');

    expect(api.calls, ['register', 'login', 'updateProfile']);
    final (publicId, profile) = users.updates.single;
    expect(publicId, 'u-1');
    expect(profile.firstName, 'Thomas');
    expect(profile.countryCode, 'FR');
    expect(find.byType(VerifyEmailPage), findsOneWidget);
  });

  testWidgets('sign-up rejects mismatched passwords without calling the server',
      (tester) async {
    await pumpApp(tester);
    await tapText(tester, 'Sign up');

    await fill(tester, 'Email', 'neo@example.test');
    await fill(tester, 'Display name', 'neo');
    await fill(tester, 'Password', 'password1234');
    await fill(tester, 'Confirm password', 'password9999');
    await tapText(tester, 'Create account');

    expect(api.calls, isEmpty);
    expect(find.text('Passwords do not match'), findsOneWidget);
  });

  testWidgets('password reset: send a code, then set a new password and get in',
      (tester) async {
    await pumpApp(tester);
    await tapText(tester, 'Forgot your password?');

    await fill(tester, 'Email', 'neo@example.test');
    await tapText(tester, 'Send code');
    await fill(tester, 'Code', '123456');
    await fill(tester, 'New password', 'new-password');
    await fill(tester, 'Confirm new password', 'new-password');
    await tapText(tester, 'Reset password');

    expect(api.calls, ['requestPasswordReset', 'resetPassword', 'login']);
    expect(find.byType(VerifyEmailPage), findsOneWidget); // the fake account is unverified
  });

  group('OAuth buttons', () {
    /// Only Google has a client ID, as if just that app were registered.
    OAuthBrowserFlow googleOnly(BrowserAuthenticate authenticate) => OAuthBrowserFlow(
          const OAuthConfig(
            clientIds: {OAuthProvider.google: 'google-id'},
            redirectUri: 'http://localhost:8081/oauth/callback',
            callbackScheme: 'musicroom',
            platformSupported: true,
          ),
          authenticate: authenticate,
        );

    Finder button(String label) => find.ancestor(
          of: find.textContaining(label),
          matching: find.byType(OutlinedButton),
        );

    testWidgets('only providers with a client ID are enabled; the others say why', (tester) async {
      store = newStore(oauth: googleOnly(({required url, required callbackUrlScheme, options}) async => ''));
      await store.start();
      await pumpApp(tester);

      expect(tester.widget<OutlinedButton>(button('Continue with Google')).onPressed, isNotNull);
      expect(find.text('Continue with 42 (not configured)'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(button('Continue with 42')).onPressed, isNull);
      // Hidden, not just disabled: no Meta app was registered.
      expect(find.textContaining('Facebook'), findsNothing);
    });

    testWidgets('Continue with Google opens the login window and signs in', (tester) async {
      Uri? opened;
      store = newStore(oauth: googleOnly(({required url, required callbackUrlScheme, options}) async {
        opened = Uri.parse(url);
        return 'musicroom://oauth?code=g-code&state=${opened!.queryParameters['state']}';
      }));
      await store.start();
      await pumpApp(tester);

      await tapText(tester, 'Continue with Google');

      expect(opened?.host, 'accounts.google.com');
      expect(api.lastOAuth?.code, 'g-code');
      expect(find.byType(VerifyEmailPage), findsOneWidget); // the fake account is unverified
    });

    testWidgets('closing the login window stays on the page, with no error', (tester) async {
      store = newStore(oauth: googleOnly(({required url, required callbackUrlScheme, options}) =>
          throw PlatformException(code: 'CANCELED')));
      await store.start();
      await pumpApp(tester);

      await tapText(tester, 'Continue with Google');

      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(api.calls, isEmpty);
    });

    testWidgets('a server refusal after the window is reported', (tester) async {
      api.failures['oauthLogin'] = const UnauthorizedError('oauth login failed');
      store = newStore(oauth: googleOnly(({required url, required callbackUrlScheme, options}) async =>
          'musicroom://oauth?code=x&state=${Uri.parse(url).queryParameters['state']}'));
      await store.start();
      await pumpApp(tester);

      await tapText(tester, 'Continue with Google');

      expect(find.text('Sign-in with that provider failed. Try again.'), findsOneWidget);
      expect(find.byType(LoginPage), findsOneWidget);
    });
  });
}
