import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/features/music/player/song_player_sheet.dart';

/// The signed-in layout: the current tab, with the bottom bar to switch tabs
/// and, above it, the song playing ([MiniPlayerBar]).
///
/// [navigationShell] is go_router's StatefulShellRoute (globals/app_router.dart):
/// it holds one navigation stack per tab, so a tab keeps its state and its
/// pushed pages while another is shown. The destinations below are in the
/// same order as its branches.
///
/// Kept alive, a tab does not reload on its own when shown again: the shell
/// gives its pages the tab shown ([ShownTab]), and each tab reloads on it
/// ([ReloadWhenShown]).
class MainShell extends StatefulWidget {
  final StatefulNavigationShell navigationShell;

  const MainShell({super.key, required this.navigationShell});

  @override
  State<MainShell> createState() => _MainShellState();
}

/// The tab on screen, for a page to notice it is shown again. A class around
/// the notifier: provider does not hand out a bare Listenable.
class ShownTab {
  final ValueListenable<int> index;

  const ShownTab(this.index);
}

/// For a tab's first page: [onShownAgain] runs each time its tab, number
/// [tabIndex] in the bar, comes back on screen. Call [watchTab] from
/// initState. Does nothing without the shell (tests of the page alone).
mixin ReloadWhenShown<T extends StatefulWidget> on State<T> {
  int get tabIndex;
  void onShownAgain();

  ValueListenable<int>? _shownTab;

  /// A page built when its tab is first opened hears that same opening a
  /// moment later (the shell says it after the frame): not a "shown again",
  /// it has just loaded.
  bool _skipNext = false;

  void watchTab() {
    final shown = context.read<ShownTab?>()?.index;
    _shownTab = shown?..addListener(_onTabShown);
    _skipNext = shown != null && shown.value != tabIndex;
  }

  void _onTabShown() {
    if (_shownTab?.value != tabIndex) {
      return;
    }
    if (_skipNext) {
      _skipNext = false;
      return;
    }
    onShownAgain();
  }

  @override
  void dispose() {
    _shownTab?.removeListener(_onTabShown);
    super.dispose();
  }
}

class _MainShellState extends State<MainShell> {
  late final _shown = ValueNotifier(widget.navigationShell.currentIndex);
  late final _tab = ShownTab(_shown);

  /// Every way to change tab lands here (the bar, "See all", a link): the
  /// router builds the shell again with the new branch.
  @override
  void didUpdateWidget(MainShell old) {
    super.didUpdateWidget(old);
    final index = widget.navigationShell.currentIndex;
    // After the frame: listeners may rebuild, and this runs during a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _shown.value = index;
      }
    });
  }

  @override
  void dispose() {
    _shown.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final navigationShell = widget.navigationShell;
    return Scaffold(
      body: Provider<ShownTab>.value(value: _tab, child: navigationShell),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const MiniPlayerBar(),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            // A tab always opens on its first page, at its plain address: the
            // Playlists tab on All rather than on the last pill picked (the pill
            // is part of the address, see PlaylistsPage). What a page has loaded
            // is kept either way, since the shell keeps each tab's page alive.
            onDestinationSelected: (index) =>
                navigationShell.goBranch(index, initialLocation: true),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home),
                label: 'Home',
              ),
              NavigationDestination(
                icon: Icon(Icons.queue_music_outlined),
                selectedIcon: Icon(Icons.queue_music),
                label: 'Playlists',
              ),
              NavigationDestination(
                icon: Icon(Icons.event_outlined),
                selectedIcon: Icon(Icons.event),
                label: 'Events',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
