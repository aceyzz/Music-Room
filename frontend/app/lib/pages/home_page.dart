import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/home/presentation/stores/home_store.dart';
import 'package:app/features/home/presentation/widgets/event_carousel.dart';
import 'package:app/features/home/presentation/widgets/friends_bar.dart';
import 'package:app/features/home/presentation/widgets/home_section.dart';
import 'package:app/features/home/presentation/widgets/recent_playlists.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/pages/main_app_bar.dart';
import 'package:app/pages/main_shell.dart';

/// The first tab, where the app lands at launch and after signing in: the
/// user's events, friends and recent playlists. Pull down to refresh.
class HomePage extends StatefulWidget {
  /// Where "now" is for the events carousel. A parameter for tests.
  final DateTime Function() now;

  const HomePage({super.key, this.now = DateTime.now});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with ReloadWhenShown<HomePage> {
  late final HomeStore _store;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach the tabs.
    _store = HomeStore(
      context.read<EventApi>(),
      context.read<UserApi>(),
      context.read<PlaylistApi>(),
      context.currentUserId,
      now: widget.now,
    )..start();
    // Kept alive by the tabs: back on Home, what changed elsewhere (an event
    // created, a playlist shared) shows.
    watchTab();
  }

  @override
  int get tabIndex => 0;

  @override
  void onShownAgain() => _store.reload();

  @override
  void dispose() {
    _store.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const MainAppBar(),
      body: RefreshIndicator(
        onRefresh: _store.reload,
        child: ListView(
          padding: AppDimens.listBottomPadding,
          children: [
            AsyncHomeSection<EventTimeline>(
              title: 'Your events',
              onSeeAll: () => context.go(eventsRoute),
              listenable: _store.events,
              height: EventCarousel.height,
              onRetry: _store.reloadEvents,
              builder: (context, timeline) {
                if (timeline.current.isEmpty && timeline.upcoming.isEmpty) {
                  return const SectionPlaceholder.message(
                    'No events yet. Find one in Events, or create your own.',
                    height: EventCarousel.height,
                  );
                }
                return EventCarousel(
                  timeline: timeline,
                  now: widget.now,
                  onReturn: _store.reloadEvents,
                );
              },
            ),
            AsyncHomeSection<List<FriendSummary>>(
              title: 'Friends',
              listenable: _store.friends,
              height: FriendsBar.height,
              onRetry: _store.reloadFriends,
              builder: (context, friends) => FriendsBar(
                friends: friends,
                onReturn: _store.reloadFriends,
              ),
            ),
            AsyncHomeSection<List<PlaylistSummary>>(
              title: 'Your playlists',
              onSeeAll: () => context.go(playlistsRoute),
              listenable: _store.playlists,
              height: RecentPlaylists.height,
              onRetry: _store.reloadPlaylists,
              builder: (context, playlists) {
                if (playlists.isNotEmpty) {
                  return RecentPlaylists(
                    playlists: playlists,
                    onReturn: _store.reloadPlaylists,
                  );
                }
                return const SectionPlaceholder.message(
                  'Create a playlist in the Playlists tab.',
                  height: 80,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
