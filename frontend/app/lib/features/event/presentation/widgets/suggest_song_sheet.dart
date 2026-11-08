import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/event/presentation/live_event_error_messages.dart';
import 'package:app/features/music/song/data/song_search_source.dart';
import 'package:app/features/music/song/presentation/widgets/song_search_sheet.dart';

/// What adds a song to the queue: LiveEventStore.suggest, passed in so the
/// sheet does not depend on the store. Throws AppError.
typedef SuggestTrack = AddTrack;

/// Opens the "suggest a song" search from the bottom of the screen, already
/// searching [initialQuery] when there is one (the vote page's "Search Deezer
/// for ..."). [queue] and [playback] are the live screen's: a result already
/// queued or playing is marked, and cannot be sent again.
Future<void> showSuggestSongSheet(
  BuildContext context, {
  required SongSearchApi search,
  required SuggestTrack suggest,
  required ValueListenable<ListState<QueueEntry>> queue,
  required ValueListenable<ItemState<EventPlayback>> playback,
  String initialQuery = '',
}) {
  return showModalBottomSheet<void>(
    context: context,
    // Tall, and above the keyboard: the results need the room.
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SuggestSongSheet(
      search: search,
      suggest: suggest,
      queue: queue,
      playback: playback,
      initialQuery: initialQuery,
    ),
  );
}

/// The event's [SongSearchSheet]: a + on each result suggests it to the
/// queue. A song already queued or playing has no + (the server would refuse
/// it); the added one turns into "In the queue" as the queue comes back.
class SuggestSongSheet extends StatelessWidget {
  final SongSearchApi search;
  final SuggestTrack suggest;
  final ValueListenable<ListState<QueueEntry>> queue;
  final ValueListenable<ItemState<EventPlayback>> playback;
  final String initialQuery;

  const SuggestSongSheet({
    super.key,
    required this.search,
    required this.suggest,
    required this.queue,
    required this.playback,
    this.initialQuery = '',
  });

  /// Read live: a song turns into "In the queue" as soon as its suggestion's
  /// answer lands, and another guest's suggestion shows at the next poll.
  SongMark? _markOf(EventTrack track) {
    if (playback.value.data?.track?.deezerId == track.deezerId) {
      return (label: 'Playing now', blocksAdd: true);
    }
    final queued = queue.value.data ?? const <QueueEntry>[];
    if (queued.any((e) => e.track.deezerId == track.deezerId)) {
      return (label: 'In the queue', blocksAdd: true);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SongSearchSheet(
      search: search,
      add: suggest,
      title: 'Suggest a song',
      prompt: 'Search Deezer for a song to add to the queue.',
      errorMessage: suggestErrorMessage,
      addTooltip: 'Suggest',
      footnote: 'New songs start with no votes.',
      marksChange: Listenable.merge([queue, playback]),
      markOf: _markOf,
      initialQuery: initialQuery,
    );
  }
}
