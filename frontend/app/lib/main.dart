import 'package:app/core/network/app_network.dart';
import 'package:app/core/network/backend_address.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/core/device/device_info.dart';
import 'package:app/core/storage/secure_token_storage.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/song/data/song_search_source.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/features/user/presentation/stores/current_user_store.dart';
import 'package:go_router/go_router.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:app/features/music/player/song_player.dart';
import 'package:app/features/music/player/song_player_notices.dart';
import 'package:app/globals/app_state.dart';
import 'package:app/globals/app_router.dart';


Future<void> main() async {
  // 1. Required when calling async code before runApp
  WidgetsFlutterBinding.ensureInitialized();
  // just_audio has no Linux half of its own: media_kit (libmpv) is it. The
  // Linux build is the demo phone (frontend/Dockerfile, target phone).
  JustAudioMediaKit.ensureInitialized(linux: true, windows: false);

  // 2. Await network initialization. The device is read first: every call
  //    reports its model (subject V.6), and the headers are fixed here.
  //    The backend's address first: the one saved on the sign-in page
  //    ("Server") wins over the build's.
  final device = await DeviceInfo.load();
  await BackendAddress.load();
  final appNetwork = await AppNetwork.connect(device: device);

  final userApi = UserGrpcSource.from(appNetwork);
  final eventApi = EventGrpcSource.from(appNetwork);
  final playlistApi = PlaylistGrpcSource.from(appNetwork);
  final songSearchApi = MusicProviderGrpcSource.from(appNetwork);
  final authApi = AuthGrpcSource.from(appNetwork);
  // Registers this install (DeviceStore) and manages its licences (the event
  // player's Delegate controls sheet).
  final deviceApi = DeviceGrpcSource.from(appNetwork);
  // Shared by sign-in (SessionStore) and linking (Profile, Linked accounts).
  final oauthFlow = OAuthBrowserFlow(OAuthConfig.fromEnvironment());

  // 3. Restore the session before the router exists, so its first redirect
  //    already knows whether someone is signed in (no flash of the login page).
  final sessionStore = SessionStore(
    SessionRepository(
      api: authApi,
      storage: TokenStorageService(),
      credentials: appNetwork.credentials,
    ),
    appNetwork.credentials,
    users: userApi,
    oauth: oauthFlow,
  );
  await sessionStore.start();

  // 4. The signed-in user's profile, for the picture in every tab's top bar.
  //    Follows the session: loads on sign-in, clears on sign-out.
  final currentUserStore = CurrentUserStore(userApi, sessionStore)..start();

  // 5. This install's device: registered once per session, which binds the
  //    session to it on the backend (activity logs, control delegation).
  final deviceStore = DeviceStore(
    deviceApi,
    sessionStore,
    () => DeviceInfo.identifier(SecureTokenStorage()),
    device,
  )..start();

  // 6. Pass instances into MyApp
  runApp(MyApp(
    appNetwork: appNetwork,
    sessionStore: sessionStore,
    currentUserStore: currentUserStore,
    deviceStore: deviceStore,
    userApi: userApi,
    socialApi: userApi,
    eventApi: eventApi,
    liveEventApi: eventApi,
    eventInfoApi: eventApi,
    eventSettingsApi: eventApi,
    playlistApi: playlistApi,
    playlistEditorApi: playlistApi,
    playlistSettingsApi: playlistApi,
    songSearchApi: songSearchApi,
    linkedAccountsApi: authApi,
    oauthFlow: oauthFlow,
    delegationApi: deviceApi,
    router: createAppRouter(sessionStore),
  ));
}

class MyApp extends StatelessWidget {

  final AppNetwork appNetwork;
  final SessionStore sessionStore;
  final CurrentUserStore currentUserStore;
  final DeviceStore deviceStore;
  final UserApi userApi;
  final SocialApi socialApi;
  final EventApi eventApi;
  final LiveEventApi liveEventApi;
  final EventInfoApi eventInfoApi;
  final EventSettingsApi eventSettingsApi;
  final PlaylistApi playlistApi;
  final PlaylistEditorApi playlistEditorApi;
  final PlaylistSettingsApi playlistSettingsApi;
  final SongSearchApi songSearchApi;
  final LinkedAccountsApi linkedAccountsApi;
  final OAuthBrowserFlow oauthFlow;
  final DelegationApi delegationApi;
  final GoRouter router;

  const MyApp({
    super.key,
    required this.appNetwork,
    required this.sessionStore,
    required this.currentUserStore,
    required this.deviceStore,
    required this.userApi,
    required this.socialApi,
    required this.eventApi,
    required this.liveEventApi,
    required this.eventInfoApi,
    required this.eventSettingsApi,
    required this.playlistApi,
    required this.playlistEditorApi,
    required this.playlistSettingsApi,
    required this.songSearchApi,
    required this.linkedAccountsApi,
    required this.oauthFlow,
    required this.delegationApi,
    required this.router,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Provide AppNetwork to the rest of the widget tree
        Provider<AppNetwork>.value(value: appNetwork),
        Provider<SessionStore>.value(value: sessionStore),
        Provider<CurrentUserStore>.value(value: currentUserStore),
        Provider<DeviceStore>.value(value: deviceStore),
        // Transports, not state: page-level stores (ProfileStore, HomeStore) take them.
        Provider<UserApi>.value(value: userApi),
        Provider<SocialApi>.value(value: socialApi),
        Provider<EventApi>.value(value: eventApi),
        Provider<LiveEventApi>.value(value: liveEventApi),
        Provider<EventInfoApi>.value(value: eventInfoApi),
        Provider<EventSettingsApi>.value(value: eventSettingsApi),
        Provider<PlaylistApi>.value(value: playlistApi),
        Provider<PlaylistEditorApi>.value(value: playlistEditorApi),
        Provider<PlaylistSettingsApi>.value(value: playlistSettingsApi),
        Provider<SongSearchApi>.value(value: songSearchApi),
        Provider<LinkedAccountsApi>.value(value: linkedAccountsApi),
        Provider<OAuthBrowserFlow>.value(value: oauthFlow),
        Provider<DelegationApi>.value(value: delegationApi),

        // Later we will have to pass the State Class that can fetch friends for example.
        // For now I will just use FutureBuilder to test the frontend backend connection.
        ChangeNotifierProvider<AppState>(create: (context) => AppState()),
        // The song tapped in a playlist, shown in the Player tab: one for the
        // app so it keeps playing across tabs.
        ChangeNotifierProvider<SongPlayer>(
          create: (context) => SongPlayer(refetch: songSearchApi.getSong),
        ),
      ],
      builder: (context, child) => MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme(),
        darkTheme: AppTheme.darkTheme(),
        themeMode: ThemeMode.system,
        routerConfig: router,
        builder: (context, page) => SongPlayerNotices(child: page!),
      ),
    );
  }
}
