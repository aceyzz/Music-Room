import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/async_list_view.dart';
import 'package:app/core/widgets/filter_pills.dart';
import 'package:app/core/widgets/search_field.dart';
import 'package:app/core/widgets/tab_action_button.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/playlist/presentation/stores/library_store.dart';
import 'package:app/features/music/playlist/presentation/widgets/create_playlist_sheet.dart';
import 'package:app/features/music/playlist/presentation/widgets/library_playlist_tile.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/pages/main_app_bar.dart';
import 'package:app/pages/main_shell.dart';

/// The Playlists tab: two pills, the user's Library and every Public
/// playlist (searched), and the list under them.
///
/// The selected pill is the page's address (`/playlists?filter=public`), so
/// tapping a pill is a navigation. Two consequences: another screen can open
/// the page on a given pill, and arriving through the tab bar, which always
/// goes to `/playlists`, shows the Library. Changing the address rebuilds this widget
/// with a new [filter] but keeps its state, so the library is loaded once.
class PlaylistsPage extends StatefulWidget {
  final LibraryFilter filter;

  const PlaylistsPage({super.key, this.filter = LibraryFilter.library});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> with ReloadWhenShown<PlaylistsPage> {
  late final LibraryStore _store;
  final _search = TextEditingController();

  /// The list's pull-to-refresh, which the top bar's button runs: the same
  /// spinner, and the list of the pill shown (only one is built at a time).
  final _refresh = GlobalKey<RefreshIndicatorState>();

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach the tabs.
    final user = context.currentUser;
    _store = LibraryStore(context.read<PlaylistApi>(), user.publicId, user.displayName)..start();
    _onFilter();
    // Back on the tab, what changed elsewhere shows: a playlist deleted from
    // Home, one shared with the user. The pill and the search stay.
    watchTab();
  }

  @override
  int get tabIndex => 1;

  @override
  void onShownAgain() => _store.reloadLibrary();

  @override
  void didUpdateWidget(PlaylistsPage old) {
    super.didUpdateWidget(old);
    if (old.filter != widget.filter) {
      _onFilter();
    }
  }

  void _onFilter() {
    if (widget.filter == LibraryFilter.public) {
      _store.ensurePublicLoaded();
    }
  }

  @override
  void dispose() {
    _store.stop();
    _search.dispose();
    super.dispose();
  }

  void _select(LibraryFilter tapped) {
    final value = tapped.queryValue;
    context.go(Uri(
      path: playlistsRoute,
      queryParameters: value == null ? null : {'filter': value},
    ).toString());
  }

  /// Opens the new playlist once created, as Spotify does; back from it, it
  /// is at the top of the list, with the songs added meanwhile.
  Future<void> _create() async {
    final created = await showCreatePlaylistSheet(context, _store.create);
    if (created != null && mounted) {
      await context.push(playlistPath(created.publicId));
      _store.reloadLibrary();
    }
  }

  @override
  Widget build(BuildContext context) {
    final public = widget.filter == LibraryFilter.public;
    return Scaffold(
      appBar: MainAppBar(onRefresh: () => _refresh.currentState?.show()),
      body: Column(
        children: [
          FilterPills(
            values: LibraryFilter.values,
            selected: widget.filter,
            label: (filter) => filter.label,
            onTap: _select,
          ),
          TabActionButton(
            label: 'Create playlist',
            icon: Icons.add,
            onPressed: _create,
          ),
          if (public) ...[
            SearchField(
              controller: _search,
              onChanged: _store.search,
              hintText: 'Search public playlists',
            ),
            _tasteFilterChip(),
          ],
          Expanded(child: public ? _publicList() : _libraryList()),
        ],
      ),
    );
  }

  Widget _tasteFilterChip() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.spacingM,
        0,
        AppDimens.spacingM,
        AppDimens.spacingXXS,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        // V.2.3: "people with the same musical tastes".
        child: FilterChip(
          avatar: const Icon(Icons.auto_awesome, size: 18),
          // The icon stays: a check over it reads as a grey blot.
          showCheckmark: false,
          label: const Text('My taste'),
          tooltip: 'Only playlists by people who like a genre you like',
          selected: _store.myTaste,
          onSelected: (on) {
            setState(() {}); // the chip and the empty text follow
            _store.setMyTaste(on);
          },
        ),
      ),
    );
  }

  Widget _libraryList() {
    return ValueListenableBuilder(
      valueListenable: _store.library,
      builder: (context, state, _) {
        return AsyncListView<LibraryPlaylist>(
          refreshKey: _refresh,
          state: state,
          items: state.data,
          emptyMessage: 'Your playlists, the ones shared with you and your friends\' show up here.',
          onRefresh: _store.reloadLibrary,
          // Back from the playlist, read the list again: the counts and the
          // cover shown here are from before what was done there.
          itemBuilder: (context, playlist, _) =>
              LibraryPlaylistTile(playlist: playlist, onReturn: _store.reloadLibrary),
        );
      },
    );
  }

  Widget _publicList() {
    return ValueListenableBuilder(
      valueListenable: _store.publicResults,
      builder: (context, state, _) {
        final query = _store.resultsQuery;
        return AsyncListView<LibraryPlaylist>(
          refreshKey: _refresh,
          state: state,
          items: state.data,
          emptyMessage: _emptyPublicMessage(query, _store.myTaste),
          onRefresh: _store.reloadPublic,
          onRetry: _store.retryPublic,
          onNearEnd: _store.loadMorePublic,
          itemBuilder: (context, playlist, _) =>
              LibraryPlaylistTile(playlist: playlist, onReturn: _store.reloadPublic),
        );
      },
    );
  }

  static String _emptyPublicMessage(String query, bool myTaste) =>
      switch ((query.isEmpty, myTaste)) {
        (true, false) => 'No public playlists yet.',
        (false, false) => 'No public playlist matches “$query”.',
        // Also what someone sees who picked no genres: say where to.
        (_, true) => 'No public playlist by someone with your taste'
            '${query.isEmpty ? '' : ' matches “$query”'}. '
            'Your music preferences, in your profile, decide what matches.',
      };
}
