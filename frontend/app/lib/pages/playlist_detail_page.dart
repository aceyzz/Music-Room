import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/confirm_dialog.dart';
import 'package:app/core/widgets/load_failed_view.dart';
import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/core/widgets/snack.dart';
import 'package:app/core/widgets/track_tile.dart';
import 'package:app/core/widgets/user_avatar.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/presentation/widgets/event_info.dart';
import 'package:app/features/music/player/song_player.dart';
import 'package:app/features/music/player/song_player_notices.dart';
import 'package:app/features/music/player/song_player_sheet.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/playlist/presentation/playlist_error_messages.dart';
import 'package:app/features/music/playlist/presentation/stores/playlist_editor_store.dart';
import 'package:app/features/music/song/data/song_search_source.dart';
import 'package:app/features/music/song/presentation/widgets/song_search_sheet.dart';
import 'package:app/globals/app_router.dart';

/// One playlist (`/playlists/:id`): its songs in order, and for those who
/// may edit it, a + that opens a Deezer search to add songs, a handle on each
/// row to drag it elsewhere, and a swipe to remove it.
///
/// Others may be editing it at the same time; the store reads it again every
/// few seconds and after each edit ([PlaylistEditorStore]). A song already in
/// the playlist can be added again (a playlist may hold it twice), but only
/// after the user says so: the server refuses it first, and the page asks.
class PlaylistDetailPage extends StatefulWidget {
  final String publicId;

  const PlaylistDetailPage({super.key, required this.publicId});

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  late final PlaylistEditorStore _store;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    final myId = context.currentUserId;
    _me = myId;
    _store = PlaylistEditorStore(
      context.read<PlaylistEditorApi>(),
      widget.publicId,
      myId,
    )..start();
    _store.details.addListener(_leaveIfGone);
    _loadOwner();
  }

  bool _left = false;

  /// The server answers "not found" once the user may no longer see the
  /// playlist: made private while they were on it, or deleted. The page
  /// leaves, and says why.
  void _leaveIfGone() {
    if (_left || _store.details.value.error is! NotFoundError || !mounted) {
      return;
    }
    _left = true;
    // Its songs may not play on either.
    context.read<SongPlayer>().drop(widget.publicId);
    // What is open over the page first (the full player, the song search, a
    // question): a pop would close that, and leave the page open.
    final page = ModalRoute.of(context);
    Navigator.of(context).popUntil((route) => route == page);
    showSnack(context, lostPlaylistMessage);
    context.canPop() ? context.pop() : context.go(playlistsRoute);
  }

  late final String _me;

  /// Whose playlist it is, for the header: the owner in its member list.
  /// Null until read, or when the read failed (the header then says nothing).
  PlaylistMember? _owner;

  Future<void> _loadOwner() async {
    final api = context.read<PlaylistSettingsApi?>();
    if (api == null) {
      return;
    }
    try {
      final members = await api.members(widget.publicId, _me);
      final owner = members.where((m) => m.role == PlaylistRole.owner).firstOrNull;
      if (mounted) {
        setState(() => _owner = owner);
      }
    } on AppError {
      // Not worth an error on the page: the header leaves the owner out.
    }
  }

  @override
  void dispose() {
    _store.details.removeListener(_leaveIfGone);
    _store.stop();
    super.dispose();
  }

  /// Plays the playlist from song [index]. The player opens the playlist's
  /// live stream itself: edits reach it, and so does losing access, whatever
  /// page the user is on by then.
  void _play(List<PlaylistEntry> songs, int index) {
    final api = context.read<PlaylistEditorApi>();
    context.read<SongPlayer>().playAll(
          [for (final e in songs) e.track],
          index,
          source: widget.publicId,
          keys: [for (final e in songs) e.id],
          updates: () => api.watchPlaylist(widget.publicId, _me).map((view) => (
                tracks: [for (final e in view.songs) e.track],
                keys: [for (final e in view.songs) e.id],
              )),
        );
  }

  void _showMessage(String text, {bool error = false}) {
    if (!mounted) {
      return;
    }
    showSnack(context, text, error: error, replace: true);
  }

  /// Runs a remove or a move. Not through BusyState: a swiped row has already
  /// left the screen, so the edit must run even while another one is in
  /// flight.
  Future<void> _edit(Future<void> Function() action, PlaylistEdit kind) async {
    try {
      await action();
    } on AppError catch (error) {
      _showMessage(playlistEditErrorMessage(error, kind), error: true);
    }
  }

  /// Its name, visibility, licence and people. Closes this page too when the
  /// playlist was deleted there.
  Future<void> _openSettings() async {
    final deleted = await context.push<bool>(playlistSettingsPath(widget.publicId));
    if ((deleted ?? false) && mounted) {
      context.pop();
    }
  }

  void _remove(PlaylistEntry entry) {
    _showMessage('Removed ${entry.track.title}');
    _edit(() => _store.remove(entry), PlaylistEdit.remove);
  }

  // --- Adding: the search sheet, and the question about duplicates.

  Future<void> _openAdd() => showSongSearchSheet(
        context,
        search: context.read<SongSearchApi>(),
        add: _add,
        title: 'Add songs',
        prompt: 'Search Deezer for a song to add to this playlist.',
        errorMessage: (error) => playlistEditErrorMessage(error, PlaylistEdit.add),
        footnote: 'Songs are added at the end.',
        marksChange: _store.songs,
        markOf: _markOf,
      );

  /// "In playlist" on a result already there. A hint, not a refusal: the +
  /// stays, and pressing it asks whether to add it again.
  SongMark? _markOf(EventTrack track) {
    final count = (_store.songs.value.data ?? const [])
        .where((e) => e.track.deezerId == track.deezerId)
        .length;
    return switch (count) {
      0 => null,
      1 => (label: 'In playlist', blocksAdd: false),
      _ => (label: 'In playlist ×$count', blocksAdd: false),
    };
  }

  /// Adds [track]; if the server answers that it is already there, asks first
  /// and adds it again only on yes. The server checks under the playlist's
  /// lock, so the question also comes when someone else added the same song
  /// since the last read, or at the same moment. Any other failure is thrown
  /// for the sheet to show.
  Future<void> _add(EventTrack track) async {
    try {
      await _store.add(track);
    } on ConflictError {
      if (!mounted) {
        return;
      }
      if (await _confirmDuplicate(track)) {
        await _store.add(track, allowDuplicate: true);
      }
    }
  }

  Future<bool> _confirmDuplicate(EventTrack track) {
    // On the root navigator (showDialog's default), so above the sheet.
    return showConfirmDialog(
      context,
      title: track.title,
      content: 'Song already present in the playlist. Add it still?',
      confirmLabel: 'Add it',
      // Adding a song again harms nothing: not the red of a delete.
      isDestructive: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder(
          valueListenable: _store.details,
          builder: (context, state, _) => Text(state.data?.name ?? 'Playlist'),
        ),
        actions: [
          IconButton(
            tooltip: 'Playlist settings',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      // The song tapped below, playing (song_player_sheet.dart).
      bottomNavigationBar: const MiniPlayerBar(),
      floatingActionButton: ListenableBuilder(
        listenable: Listenable.merge([_store.canEdit, _store.details]),
        builder: (context, _) => _store.canEdit.value && _store.details.value.hasData
            ? FloatingActionButton(
                tooltip: 'Add songs',
                onPressed: _openAdd,
                child: const Icon(Icons.add),
              )
            : const SizedBox.shrink(),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_store.details, _store.songs, _store.canEdit]),
        builder: (context, _) {
          final details = _store.details.value;
          final playlist = details.data;
          if (playlist == null) {
            return details.hasError
                ? LoadFailedView(
                    message: "Couldn't load this playlist.",
                    onRetry: _store.refresh,
                  )
                : const Center(child: CircularProgressIndicator());
          }
          return _songList(playlist, _store.songs.value.data ?? const [], _store.canEdit.value);
        },
      ),
    );
  }

  Widget _songList(PlaylistDetails playlist, List<PlaylistEntry> songs, bool canEdit) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return RefreshIndicator(
      onRefresh: _store.refresh,
      child: ReorderableListView.builder(
        // The drag handle starts a drag at once; the default long press
        // would also make every row draggable for viewers.
        buildDefaultDragHandles: false,
        // Room under the last row for the + button.
        padding: AppDimens.listWithFabBottomPadding,
        header: _Header(
          playlist: playlist,
          songs: songs,
          canEdit: canEdit,
          owner: _owner,
          isMe: _owner?.publicId == _me,
        ),
        footer: songs.isEmpty
            ? Padding(
                padding: const EdgeInsets.all(AppDimens.spacingXL),
                child: Text(
                  canEdit ? 'No songs yet. Add one with +.' : 'No songs yet.',
                  textAlign: TextAlign.center,
                  style: muted,
                ),
              )
            : null,
        itemCount: songs.length,
        onReorderItem: (from, to) => _edit(() => _store.move(from, to), PlaylistEdit.move),
        itemBuilder: (context, i) {
          final entry = songs[i];
          final tile = _SongTile(
            entry: entry,
            index: i,
            canEdit: canEdit,
            onPlay: () => _play(songs, i),
          );
          if (!canEdit) {
            return KeyedSubtree(key: ValueKey(entry.id), child: tile);
          }
          return Dismissible(
            key: ValueKey(entry.id),
            direction: DismissDirection.endToStart,
            background: const _RemoveBackground(),
            onDismissed: (_) => _remove(entry),
            child: tile,
          );
        },
      ),
    );
  }
}

/// Cover, name, who may see and edit it, and how long it is.
class _Header extends StatelessWidget {
  final PlaylistDetails playlist;

  /// As shown, so the count follows a swipe before the server answers.
  final List<PlaylistEntry> songs;
  final bool canEdit;

  /// Whose it is: "By Alex Martin", with their face, opening their profile;
  /// "By you" for the user's own. Nothing until known.
  final PlaylistMember? owner;
  final bool isMe;

  const _Header({
    required this.playlist,
    required this.songs,
    required this.canEdit,
    required this.owner,
    required this.isMe,
  });

  String get _editorsText => switch (playlist.editLicense) {
        EditLicense.everyone => 'Anyone who can see it can edit',
        EditLicense.invitedOnly => 'Only invited people can edit',
      };

  String get _statsText {
    final length = songs.fold(Duration.zero, (sum, e) => sum + e.track.duration);
    return songs.isEmpty
        ? plural(0, 'song')
        : '${plural(songs.length, 'song')} · ${formatListeningTime(length)}';
  }

  String get _permissionText => playlist.editLicense == EditLicense.invitedOnly
      ? 'Only invited people can edit it. You can listen.'
      : 'You can listen to this playlist but not edit it.';

  Widget _buildOwner(BuildContext context, PlaylistMember owner, TextStyle? style) {
    return InkWell(
      onTap: isMe ? null : () => context.push(userPath(owner.publicId)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          UserAvatar(url: owner.avatarUrl, name: owner.displayName, radius: 9),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              isMe ? 'By you' : 'By ${owner.displayName}',
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.spacingM,
        AppDimens.spacingM,
        AppDimens.spacingM,
        AppDimens.spacingXS,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppDimens.radiusM),
            // The first song's art, as in the lists (Home, Playlists): the
            // same picture everywhere, and it follows a move to the top.
            child: SizedBox.square(
              dimension: 120,
              child: PlaylistCover(url: songs.firstOrNull?.track.coverUrl),
            ),
          ),
          const SizedBox(width: AppDimens.spacingM),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(playlist.name, style: theme.textTheme.titleLarge),
                if (owner case final owner?) ...[
                  const SizedBox(height: AppDimens.spacingXXS),
                  _buildOwner(context, owner, muted),
                ],
                const SizedBox(height: AppDimens.spacingXXS),
                Text('${playlist.visibility.label} · $_editorsText', style: muted),
                const SizedBox(height: AppDimens.spacingXXS),
                Text(_statsText, style: muted),
                if (!canEdit) ...[
                  const SizedBox(height: AppDimens.spacingXS),
                  // Why there is no + and no drag handle.
                  Text(_permissionText, style: muted),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One song: cover, title, artist and length, and for an editor the handle
/// that drags it.
class _SongTile extends StatelessWidget {
  final PlaylistEntry entry;
  final int index;
  final bool canEdit;

  /// Plays the playlist from this song (the Player tab shows it).
  final VoidCallback onPlay;

  const _SongTile({
    required this.entry,
    required this.index,
    required this.canEdit,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final track = entry.track;
    return TrackTile(
      title: track.title,
      artist: track.artist,
      duration: track.duration,
      coverUrl: track.coverUrl,
      selected: sameSong(context.select<SongPlayer, EventTrack?>((p) => p.current), track),
      onTap: canPlay(track) ? onPlay : null,
      trailing: canEdit
          ? ReorderableDragStartListener(
              index: index,
              child: const Padding(
                padding: EdgeInsets.all(AppDimens.spacingXS),
                child: Icon(Icons.drag_handle, semanticLabel: 'Move'),
              ),
            )
          : null,
    );
  }
}

/// What shows under a row being swiped away.
class _RemoveBackground extends StatelessWidget {
  const _RemoveBackground();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.error,
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: AppDimens.spacingL),
          child: Icon(Icons.delete_outline, color: scheme.onError),
        ),
      ),
    );
  }
}

