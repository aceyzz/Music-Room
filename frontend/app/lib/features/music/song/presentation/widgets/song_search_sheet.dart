import 'package:flutter/material.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/inline_spinner.dart';
import 'package:app/core/widgets/search_field.dart';
import 'package:app/core/widgets/track_tile.dart';
import 'package:app/features/music/song/data/song_search_source.dart';
import 'package:app/features/music/song/presentation/stores/song_search_store.dart';

/// What adds a result where the sheet was opened from: the event's queue
/// (LiveEventStore.suggest) or a playlist (PlaylistEditorStore.add). Throws
/// [AppError], which the sheet shows under its search field.
typedef AddTrack = Future<void> Function(EventTrack track);

/// Why a result is marked ("In the queue", "In playlist"), and whether that
/// takes its + away. A playlist may hold a song twice, an event's queue may
/// not.
typedef SongMark = ({String label, bool blocksAdd});

/// Opens a Deezer search from the bottom of the screen, with a + on each
/// result that calls [add]. Already searching [initialQuery] when there is
/// one.
///
/// [markOf] marks the results that are already where they would go; it is
/// asked again whenever [marksChange] notifies, so a result turns marked as
/// soon as its own add lands, or someone else's shows up.
Future<void> showSongSearchSheet(
  BuildContext context, {
  required SongSearchApi search,
  required AddTrack add,
  required String title,
  required String prompt,
  required String Function(AppError error) errorMessage,
  String addTooltip = 'Add',
  String? footnote,
  Listenable? marksChange,
  SongMark? Function(EventTrack track)? markOf,
  String initialQuery = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Tall, and above the keyboard: the results need the room.
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SongSearchSheet(
      search: search,
      add: add,
      title: title,
      prompt: prompt,
      errorMessage: errorMessage,
      addTooltip: addTooltip,
      footnote: footnote,
      marksChange: marksChange,
      markOf: markOf,
      initialQuery: initialQuery,
    ),
  );
}

/// A Deezer search with a + on each result.
///
/// Stays open after an add, so several songs can be added in a row. A
/// failure shows as a line under the search field rather than a snack bar:
/// the page's snack bar would sit behind the sheet.
class SongSearchSheet extends StatefulWidget {
  final SongSearchApi search;
  final AddTrack add;
  final String title;

  /// Shown before anything is typed.
  final String prompt;
  final String Function(AppError error) errorMessage;

  /// The + button's tooltip, what a screen reader says for it.
  final String addTooltip;

  /// A line at the bottom, for the rule the user should know ("New songs
  /// start with no votes.").
  final String? footnote;
  final Listenable? marksChange;
  final SongMark? Function(EventTrack track)? markOf;
  final String initialQuery;

  const SongSearchSheet({
    super.key,
    required this.search,
    required this.add,
    required this.title,
    required this.prompt,
    required this.errorMessage,
    this.addTooltip = 'Add',
    this.footnote,
    this.marksChange,
    this.markOf,
    this.initialQuery = '',
  });

  @override
  State<SongSearchSheet> createState() => _SongSearchSheetState();
}

class _SongSearchSheetState extends State<SongSearchSheet> {
  late final SongSearchStore _store = SongSearchStore(widget.search);
  final _field = TextEditingController();

  /// The song being sent; every + waits for it.
  int? _sending;
  String? _error;

  @override
  void initState() {
    super.initState();
    final query = widget.initialQuery.trim();
    if (query.isNotEmpty) {
      _field.text = query;
      // Typed already, on the page that opened the sheet: no pause to wait for.
      _store
        ..search(query)
        ..retry();
    }
  }

  @override
  void dispose() {
    _store.stop();
    _field.dispose();
    super.dispose();
  }

  void _typed(String text) {
    if (_error != null) {
      setState(() => _error = null);
    }
    _store.search(text);
  }

  Future<void> _add(EventTrack track) async {
    if (_sending != null) {
      return;
    }
    setState(() {
      _sending = track.deezerId;
      _error = null;
    });
    try {
      await widget.add(track);
    } on AppError catch (error) {
      if (mounted) {
        setState(() => _error = widget.errorMessage(error));
      }
    } finally {
      if (mounted) {
        setState(() => _sending = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final error = _error;
    final footnote = widget.footnote;
    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Padding(
        // The keyboard covers the bottom of the sheet otherwise.
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppDimens.spacingM,
                0,
                AppDimens.spacingM,
                AppDimens.spacingS,
              ),
              child: Text(widget.title, style: theme.textTheme.titleLarge),
            ),
            SearchField(
              controller: _field,
              onChanged: _typed,
              hintText: 'Search Deezer',
              autofocus: widget.initialQuery.isEmpty,
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.spacingM,
                  0,
                  AppDimens.spacingM,
                  AppDimens.spacingXS,
                ),
                child: Text(error, style: TextStyle(color: theme.colorScheme.error)),
              ),
            Expanded(
              child: ValueListenableBuilder<ListState<EventTrack>>(
                valueListenable: _store.results,
                builder: (context, state, _) => _results(context, state),
              ),
            ),
            if (footnote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppDimens.spacingM,
                  AppDimens.spacingXS,
                  AppDimens.spacingM,
                  AppDimens.spacingM,
                ),
                child: Text(footnote, style: muted, textAlign: TextAlign.center),
              ),
          ],
        ),
      ),
    );
  }

  Widget _results(BuildContext context, ListState<EventTrack> state) {
    if (_store.query.isEmpty) {
      return _Message(widget.prompt);
    }
    final found = state.data;
    if (found == null) {
      if (state.hasError) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('The search failed.'),
              const SizedBox(height: AppDimens.spacingXS),
              TextButton(onPressed: _store.retry, child: const Text('Retry')),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (found.isEmpty) {
      return _Message('No song matches "${_store.resultsQuery}".');
    }
    Widget list(BuildContext context) => ListView.builder(
          itemCount: found.length,
          itemBuilder: (context, i) {
            final track = found[i];
            final id = track.deezerId;
            final mark = id == 0 ? null : widget.markOf?.call(track);
            return _ResultTile(
              track: track,
              mark: mark,
              addTooltip: widget.addTooltip,
              sending: _sending == id,
              onAdd: _sending != null || id == 0 ? null : () => _add(track),
            );
          },
        );
    final marksChange = widget.marksChange;
    return marksChange == null
        ? list(context)
        : ListenableBuilder(listenable: marksChange, builder: (context, _) => list(context));
  }
}

/// One search result: cover, title, artist, and the + or why there is none.
class _ResultTile extends StatelessWidget {
  final EventTrack track;
  final SongMark? mark;
  final String addTooltip;

  /// This song's add is in flight.
  final bool sending;
  final VoidCallback? onAdd;

  const _ResultTile({
    required this.track,
    required this.mark,
    required this.addTooltip,
    required this.sending,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mark = this.mark;
    final label = mark == null
        ? null
        : Text(mark.label,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary));
    final Widget trailing;
    if (mark != null && mark.blocksAdd) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          label!,
          const SizedBox(width: AppDimens.spacingXS),
          Icon(Icons.check_circle, color: theme.colorScheme.primary),
          const SizedBox(width: AppDimens.spacingS),
        ],
      );
    } else if (sending) {
      trailing = const Padding(
        padding: EdgeInsets.all(AppDimens.spacingS),
        child: InlineSpinner(size: 24),
      );
    } else {
      final add = IconButton(
        tooltip: addTooltip,
        onPressed: onAdd,
        icon: const Icon(Icons.add_circle_outline),
      );
      trailing = label == null ? add : Row(mainAxisSize: MainAxisSize.min, children: [label, add]);
    }
    return TrackTile(
      title: track.title,
      artist: track.artist,
      coverUrl: track.coverUrl,
      trailing: trailing,
    );
  }
}

class _Message extends StatelessWidget {
  final String text;

  const _Message(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppDimens.spacingXL),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    );
  }
}
