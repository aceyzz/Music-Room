import 'package:go_router/go_router.dart';

import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/pages/forgot_password_page.dart';
import 'package:app/pages/friends_page.dart';
import 'package:app/pages/login_page.dart';
import 'package:app/pages/register_page.dart';
import 'package:app/pages/verify_email_page.dart';
import 'package:app/pages/events_page.dart';
import 'package:app/pages/home_page.dart';
import 'package:app/pages/live_event_page.dart';
import 'package:app/pages/main_shell.dart';
import 'package:app/pages/playlists_page.dart';
import 'package:app/pages/profile_page.dart';
import 'package:app/pages/user_page.dart';
import 'package:app/pages/playlist_detail_page.dart';
import 'package:app/pages/playlist_settings_page.dart';
import 'package:app/pages/event_settings_page.dart';


// Note:
// Where to define stores
// Scenario A: The Store is Global (e.g., AuthStore, SettingsStore)
// If the Store holds data that the entire app needs to survive from launch to close, initialize it 
// above the Router (usually in main.dart alongside your AppNetwork).
//
// Scenario B: The Store is Page-Specific (e.g., PlaylistStore, SearchStore)
// If the Store is only used for one specific feature, initialize it at the Page/Route level.
// 
// If you initialize a PlaylistStore globally, it will stay in memory forever, and the next time 
// the user opens the playlist, they will see the old state! If you 
// initialize it at the page level, it gets properly garbage-collected when the user navigates away.
//
// The tab pages (Home, Playlists, Events) are page-level too: each builds its own stores.
// The one exception is the signed-in user's own profile (CurrentUserStore): every tab's top bar
// shows its picture, so it is global, built in main.dart next to SessionStore.

const loginRoute = '/login';
const registerRoute = '/register';
const forgotPasswordRoute = '/forgot-password';
const verifyEmailRoute = '/verify-email';
const profileRoute = '/profile';
// The reset flow, for the signed-in user's own address: see ForgotPasswordPage.
const changePasswordRoute = '/profile/password';

// The four tabs of MainShell, in bottom-bar order. homeRoute is where the app
// lands at launch and after signing in.
const homeRoute = '/home';
const playlistsRoute = '/playlists';
const eventsRoute = '/events';

// Pages the Home tab links to. An event's screen is built
// (LiveEventPage), and so are someone's
// profile (UserPage), the friends page (FriendsPage) and a playlist
// (PlaylistDetailPage). Top-level,
// so full screen over the tabs like the profile; a page can move under its
// tab's branch later, same URL.
const friendsRoute = '/friends';
/// An event's screen, whatever its phase: the Events tab and the Home
/// carousel both open it.
String eventPath(String publicId) => '/events/$publicId';
String eventSettingsPath(String publicId) => '/events/$publicId/settings';
String playlistPath(String publicId) => '/playlists/$publicId';
String playlistSettingsPath(String publicId) => '/playlists/$publicId/settings';
String userPath(String publicId) => '/users/$publicId';

/// The pages a signed-out user may see.
const _signedOutRoutes = {loginRoute, registerRoute, forgotPasswordRoute};

/// Where the session says the user must be, or null to stay on [location].
///
/// - signed out: only the sign-in, sign-up and password-reset pages;
/// - signed in, email not verified: only the verification page (subject V.1,
///   "the application must demand a mail validation"). The server does not
///   enforce this; the app does;
/// - signed in and verified: anywhere but those two.
///
/// A plain function of the state so it can be tested without a widget tree.
String? authRedirect(SessionState session, String location) {
  return switch (session) {
    SignedOut() => _signedOutRoutes.contains(location) ? null : loginRoute,
    SignedIn(:final user) when !user.emailVerified =>
      location == verifyEmailRoute ? null : verifyEmailRoute,
    SignedIn() =>
      _signedOutRoutes.contains(location) || location == verifyEmailRoute ? homeRoute : null,
  };
}

/// Central application navigation router powered by [GoRouter].
///
/// Handles route matching, initial location setup, and navigation payload parsing.
/// Re-runs [authRedirect] whenever the session changes, so logging in, out,
/// or losing the session to the server moves the user without any page
/// having to navigate itself.
///
/// Build it once (main.dart), after [SessionStore.start]: rebuilding a
/// GoRouter resets the navigation stack.
GoRouter createAppRouter(SessionStore sessionStore) => GoRouter(
  initialLocation: homeRoute,
  refreshListenable: sessionStore.state,
  redirect: (context, state) => authRedirect(sessionStore.state.value, state.matchedLocation),
  routes: [
    // A bare '/' (web, a stale deep link) would otherwise hit go_router's error page.
    GoRoute(path: '/', redirect: (context, state) => homeRoute),
    // The bottom tabs. Each branch has its own navigation stack, and
    // indexedStack keeps all three alive, so switching tabs keeps their state.
    // A page pushed inside a branch (later: /playlists/:id) keeps the tabs.
    // The routes below the shell are full screen over the tabs (profile,
    // settings): back returns to the tab the user came from.
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) => MainShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(routes: [
          GoRoute(path: homeRoute, builder: (context, state) => const HomePage()),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: playlistsRoute,
            // The selected pill: /playlists?filter=public. See PlaylistsPage.
            builder: (context, state) => PlaylistsPage(
              filter: LibraryFilter.fromQuery(state.uri.queryParameters['filter']),
            ),
          ),
        ]),
        StatefulShellBranch(routes: [
          GoRoute(
            path: eventsRoute,
            // The selected pill: /events?filter=upcoming. See EventsPage.
            builder: (context, state) => const EventsPage(),
          ),
        ]),
      ],
    ),
    GoRoute(
      path: loginRoute,
      builder: (context, state) => const LoginPage(),
    ),
    GoRoute(
      path: registerRoute,
      builder: (context, state) => const RegisterPage(),
    ),
    GoRoute(
      path: forgotPasswordRoute,
      builder: (context, state) => const ForgotPasswordPage(),
    ),
    GoRoute(
      path: verifyEmailRoute,
      builder: (context, state) => const VerifyEmailPage(),
    ),
    GoRoute(
      path: profileRoute,
      builder: (context, state) => const ProfilePage(),
    ),
    GoRoute(
      path: changePasswordRoute,
      // Signed in: authRedirect sends anyone else to /login first.
      builder: (context, state) => ForgotPasswordPage(
        email: (sessionStore.state.value as SignedIn).user.email,
      ),
    ),
    GoRoute(
      path: '/events/:id',
      builder: (context, state) => LiveEventPage(publicId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/events/:id/settings',
      builder: (context, state) => EventSettingsPage(publicId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/playlists/:id',
      builder: (context, state) => PlaylistDetailPage(publicId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/playlists/:id/settings',
      builder: (context, state) => PlaylistSettingsPage(publicId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: friendsRoute,
      builder: (context, state) => const FriendsPage(),
    ),
    GoRoute(
      path: '/users/:id',
      builder: (context, state) => UserPage(publicId: state.pathParameters['id']!),
    ),
  ],
);