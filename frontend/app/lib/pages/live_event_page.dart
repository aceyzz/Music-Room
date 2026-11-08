import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/busy_state.dart';
import 'package:app/core/widgets/load_failed_view.dart';
import 'package:app/core/widgets/snack.dart';
import 'package:app/globals/app_router.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';
import 'package:app/features/device/presentation/widgets/speaker_sheet.dart';
import 'package:app/features/event/data/event_audio_output.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/event/presentation/live_event_error_messages.dart';
import 'package:app/features/event/presentation/stores/live_event_store.dart';
import 'package:app/features/event/presentation/widgets/event_info.dart';
import 'package:app/features/event/presentation/widgets/event_tile.dart';
import 'package:app/features/event/presentation/widgets/suggest_song_sheet.dart';
import 'package:app/features/event/presentation/widgets/vote_view.dart';
import 'package:app/features/music/player/song_player.dart';
import 'package:app/features/music/song/data/song_search_source.dart';

/// The screen of an event (`/events/:id`), before it starts as while it
/// runs: guests vote and suggest songs ahead of time, and the host can press
/// play whenever they like. A banner says when it starts, or when it ends.
///
/// One page for everyone ([VoteView]): what plays, and the queue with a
/// ballot button on each song, plus a floating + that opens a Deezer search
/// to add songs to it ([showSuggestSongSheet]). The people in control (the
/// host, and the friends they delegate control to from the app bar) also get
/// the player's buttons in the "Now playing" banner. Only the event's speaker
/// device plays the sound: the host's, from their first play (the store
/// decides).
class LiveEventPage extends StatefulWidget {
  final String publicId;

  /// A parameter for tests: the playhead and the progress bar run on it.
  final DateTime Function() now;

  /// A parameter for tests, which have no audio plugin. Defaults to
  /// [platformAudioOutput]: just_audio.
  final AudioOutput Function()? audio;

  /// A parameter for tests: where the phone is. Defaults to
  /// [platformPositionSource].
  final PositionSource? positions;

  const LiveEventPage({
    super.key,
    required this.publicId,
    this.now = DateTime.now,
    this.audio,
    this.positions,
  });

  @override
  State<LiveEventPage> createState() => _LiveEventPageState();
}

class _LiveEventPageState extends State<LiveEventPage> with BusyState<LiveEventPage> {
  late final LiveEventStore _store;

  @override
  void initState() {
    super.initState();
    // The router only lets a signed-in user reach this page.
    // One sound at a time: the event's speaker takes over from a playlist
    // song playing on this device. Nullable: tests provide no SongPlayer.
    context.read<SongPlayer?>()?.pause();
    _store = LiveEventStore(
      context.read<LiveEventApi>(),
      widget.publicId,
      context.currentUserId,
      audio: widget.audio,
      positions: widget.positions,
      now: widget.now,
      device: context.read<DeviceStore?>()?.deviceId,
    )..start();
    _store.event.addListener(_leaveIfGone);
  }

  bool _left = false;

  /// The server answers "not found" once the user may no longer see the
  /// event: made private while they were on it, or deleted. The page leaves,
  /// and says why.
  void _leaveIfGone() {
    if (_left || _store.event.value.error is! NotFoundError || !mounted) {
      return;
    }
    _left = true;
    // What is open over the page first (the song suggestions, the delegation
    // sheet): a pop would close that, and leave the page open, its music on.
    final page = ModalRoute.of(context);
    Navigator.of(context).popUntil((route) => route == page);
    showSnack(context, "You can't see this event any more.");
    context.canPop() ? context.pop() : context.go(eventsRoute);
  }

  @override
  void dispose() {
    _store.event.removeListener(_leaveIfGone);
    _store.stop();
    super.dispose();
  }

  Future<void> _press(Future<void> Function() action, PlaybackAction kind) =>
      run(action, message: (error) => playbackErrorMessage(error, kind));

  Future<void> _vote(QueueEntry entry) => run(() => _store.vote(entry), message: voteErrorMessage);

  Future<void> _openSuggest([String query = '']) => showSuggestSongSheet(
        context,
        search: context.read<SongSearchApi>(),
        suggest: _store.suggest,
        queue: _store.queue,
        playback: _store.playback,
        initialQuery: query,
      );

  /// The player's buttons, for the people in control (LiveEventStore.
  /// canControl); null for everyone else. One command at a time.
  /// Ended (by the host, or by the server once it went quiet past its end):
  /// the page stays, read-only, with its banner saying so. The stream says
  /// it like any other change.
  bool get _ended => _store.event.value.data?.status == 'ended';

  /// Why the user may not vote or suggest, or null when they may (the
  /// server's event#can_vote, LiveEventStore.canVote).
  String? get _cannotVote {
    if (_ended) {
      return 'This event has ended.';
    }
    if (_store.canVote.value) {
      return null;
    }
    return switch (_store.event.value.data?.voteLicense) {
      'invited_only' => 'Only invited people can vote and suggest songs.',
      'location_time' => 'Only people at the venue, during its hours, can vote and suggest songs.',
      _ => "You can't vote or suggest songs in this event.",
    };
  }

  PlayerActions? get _controls {
    if (!_store.canControl.value || _ended) {
      return null;
    }
    return PlayerActions(
      restart: busy ? null : () => _press(_store.previous, PlaybackAction.seek),
      playPause: busy ? null : () => _press(_store.togglePlay, PlaybackAction.playPause),
      next: busy ? null : () => _press(_store.next, PlaybackAction.next),
      seek: busy ? null : (to) => _press(() => _store.seek(to), PlaybackAction.seek),
    );
  }

  /// Who can find it, who can vote, its people. Closes this page too when the
  /// event was ended there.
  Future<void> _openSettings() async {
    final ended = await context.push<bool>(eventSettingsPath(widget.publicId));
    if ((ended ?? false) && mounted) {
      context.pop();
    }
  }

  Widget _buildFab() {
    return ListenableBuilder(
      listenable: Listenable.merge([_store.playback, _store.event, _store.canVote]),
      builder: (context, _) => _store.playback.value.hasData && _cannotVote == null
          ? FloatingActionButton(
              tooltip: 'Suggest a song',
              onPressed: _openSuggest,
              child: const Icon(Icons.add),
            )
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder(
          valueListenable: _store.event,
          builder: (context, state, _) => Text(state.data?.name ?? 'Live event'),
        ),
        actions: [
          _SpeakerButton(store: _store, eventPublicId: widget.publicId),
          IconButton(
            tooltip: 'Event settings',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      floatingActionButton: _buildFab(),
      body: Column(
        children: [
          ValueListenableBuilder(
            valueListenable: _store.event,
            builder: (context, state, _) => _LiveEventHeader(
              event: state.data,
              now: widget.now,
            ),
          ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  Widget _content() {
    return ListenableBuilder(
      listenable:
          Listenable.merge(
              [_store.canControl, _store.playback, _store.event, _store.canVote, _store.playsHere]),
      builder: (context, _) {
        final playback = _store.playback.value;
        // Until the first answer, it is not known whether this user gets the
        // player's buttons.
        if (!playback.hasData) {
          return playback.hasError
              ? LoadFailedView(
                  message: 'This event could not be loaded.',
                  onRetry: _store.refresh,
                  buttonType: RetryButtonType.tonal,
                )
              : const Center(child: CircularProgressIndicator());
        }
        return VoteView(
          playback: _store.playback,
          queue: _store.queue,
          // No more votes once it has ended: the ballots stay, disabled.
          busy: busy || _ended,
          onVote: _vote,
          onRefresh: _store.refresh,
          onSuggest: _openSuggest,
          controls: _controls,
          playsHere: _store.playsHere.value,
          cannotVote: _cannotVote,
          host: _store.host,
          now: widget.now,
        );
      },
    );
  }
}

class _LiveEventHeader extends StatelessWidget {
  final EventSummary? event;
  final DateTime Function() now;

  const _LiveEventHeader({
    required this.event,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final currentEvent = event;
    if (currentEvent == null) {
      return const SizedBox.shrink();
    }
    final description = currentEvent.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StartsBanner(event: currentEvent, now: now),
        // What the host wrote about it, when they did.
        if (description != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppDimens.spacingM,
              10,
              AppDimens.spacingM,
              0,
            ),
            child: Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}

/// When the event starts, while it has not; when it ends, while it runs;
/// that it is over, once it is. Ticks every minute so the countdown moves on.
/// The host's "Where the music plays" button (subject V.2.2: a licence is
/// specific to each device): which of their devices plays the sound. Who may
/// control it is in the event's settings. Shown once this device is
/// registered, and not on an ended event.
class _SpeakerButton extends StatelessWidget {
  final LiveEventStore store;
  final String eventPublicId;

  const _SpeakerButton({required this.store, required this.eventPublicId});

  @override
  Widget build(BuildContext context) {
    final devices = context.read<DeviceStore?>();
    final device = devices?.devicePublicId ?? ValueNotifier(null);
    return ListenableBuilder(
      listenable: Listenable.merge([store.event, device]),
      builder: (context, _) {
        final event = store.event.value.data;
        final devicePublicId = device.value;
        if (event == null || !event.viewerIsHost || event.status == 'ended' ||
            devicePublicId == null) {
          return const SizedBox.shrink();
        }
        final userPublicId = (context.read<SessionStore>().state.value as SignedIn).user.publicId;
        final delegation = context.read<DelegationApi>();
        return IconButton(
          tooltip: 'Where the music plays',
          icon: const Icon(Icons.speaker_group_outlined),
          onPressed: () => showSpeakerSheet(
            context,
            delegation: delegation,
            eventPublicId: eventPublicId,
            userPublicId: userPublicId,
            speakerId: store.playback.value.data?.speakerDeviceId,
            thisDeviceId: devices?.deviceId.value,
          ),
        );
      },
    );
  }
}

class _StartsBanner extends StatefulWidget {
  final EventSummary event;
  final DateTime Function() now;

  const _StartsBanner({required this.event, required this.now});

  @override
  State<_StartsBanner> createState() => _StartsBannerState();
}

class _StartsBannerState extends State<_StartsBanner> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final now = widget.now();
    final starts = event.startsAt;
    final ends = event.endsAt;
    final scheme = Theme.of(context).colorScheme;
    final String title;
    // Blue while it is to come or on time; the warning colour once it runs
    // past its end; grey once over.
    var (background, foreground) = (scheme.primaryContainer, scheme.onPrimaryContainer);
    String? note;
    switch (event.phaseAt(now)) {
      case EventPhase.current:
        title = switch (ends) {
          null => 'Happening now',
          // Still playing: a party goes on until the host ends it.
          _ when !ends.isAfter(now) => 'Past its end time',
          _ => 'Ends in ${formatCountdown(ends.difference(now))}',
        };
        if (ends != null && !ends.isAfter(now)) {
          (background, foreground) = (scheme.errorContainer, scheme.onErrorContainer);
          // What happens next (EndOverdueEvents in the backend).
          note = 'It goes on while music plays, and ends as soon as it stops.';
        }
      case EventPhase.upcoming:
        // Every event has times (CreateEvent requires them).
        if (starts == null) {
          return const SizedBox.shrink();
        }
        title = 'Starts in ${formatCountdown(starts.difference(now))}';
      case EventPhase.past:
        title = 'This event has ended';
        (background, foreground) = (scheme.surfaceContainerHighest, scheme.onSurfaceVariant);
    }
    return Material(
      color: background,
      child: ListTile(
        leading: Icon(Icons.schedule, color: foreground),
        title: Text(title, style: TextStyle(color: foreground)),
        subtitle: Text(
          [EventTile.dates(event, now), if (note != null) note].join('\n'),
          style: TextStyle(color: foreground),
        ),
      ),
    );
  }
}

