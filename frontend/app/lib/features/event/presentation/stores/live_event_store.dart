import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/sources/live_stream.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/features/event/data/event_audio_output.dart';
import 'package:app/features/event/data/event_source.dart';

/// The live event screen: the event, what it plays, its queue, the votes and
/// suggestions, and the playback buttons for the people in control: the host,
/// and the friends they delegated control to (subject V.2.2).
///
/// Page-level (built and stopped by LiveEventPage, see the note in
/// globals/app_router.dart).
///
/// The server pushes the whole state after every change (EventService.
/// WatchEvent): the other guests' votes, the host's pause, the next song
/// starting on its own when one ends. Each button's answer is shown too, at
/// once; the push that follows it agrees.
class LiveEventStore {
  final LiveEventApi _api;
  final String _eventPublicId;
  final String _userPublicId;
  final AudioOutput Function() _newAudio;
  final DateTime Function() _now;
  final PositionSource _positions;

  /// This app's device (DeviceStore.deviceId), compared with the event's
  /// speaker: only the speaker plays the sound. Null until registered.
  final ValueListenable<int?> _device;

  final ValueNotifier<ItemState<EventSummary>> event = ValueNotifier(ItemState.initial());
  final ValueNotifier<ItemState<EventPlayback>> playback = ValueNotifier(ItemState.initial());
  final ValueNotifier<ListState<QueueEntry>> queue = ValueNotifier(ListState.initial());

  /// Whether the signed-in user may press the buttons: the host, or a friend
  /// holding a licence on the event's speaker device.
  final ValueNotifier<bool> canControl = ValueNotifier(false);

  /// Whether this app plays the sound: it runs on the event's speaker
  /// ([_isSpeaker]). A friend in control has the buttons, not the sound.
  final ValueNotifier<bool> playsHere = ValueNotifier(false);

  /// Whether the signed-in user may vote and suggest songs (the licence,
  /// and for a place-and-time event its hours): the page shows the ballots
  /// and the + only then. The venue radius is checked on the vote itself.
  final ValueNotifier<bool> canVote = ValueNotifier(false);

  /// Who hosts it, for "Waiting for Sarah to press play"; null until read,
  /// or when the read failed (the page then just says "the host").
  final ValueNotifier<EventMember?> host = ValueNotifier(null);

  /// The sound, created the first time there is something to play and this
  /// app is the event's speaker ([_isSpeaker]).
  AudioOutput? _audio;

  late final LiveStream<LiveEventView> _live;

  /// Bumped by every write to [queue]. A read answers with the queue as it
  /// was when it started, so one that started before a vote's or a
  /// suggestion's answer arrived is dropped: it would hide what was just
  /// sent.
  int _queueGeneration = 0;

  /// Set by [stop]. A request can outlive the page, and writing to a disposed
  /// notifier throws.
  bool _stopped = false;

  LiveEventStore(
    this._api,
    this._eventPublicId,
    this._userPublicId, {
    AudioOutput Function()? audio,
    DateTime Function() now = DateTime.now,
    List<Duration> retryDelays = LiveStream.defaultRetryDelays,
    PositionSource? positions,
    ValueListenable<int?>? device,
  })  : _newAudio = audio ?? (() => platformAudioOutput(now: now)),
        _now = now,
        _positions = positions ?? platformPositionSource(),
        _device = device ?? ValueNotifier(null) {
    // Registration can finish after the page opened: the sound may be ours.
    _device.addListener(_onDevice);
    _live = LiveStream(
      () => _api.watch(_eventPublicId, _userPublicId),
      onState: (state) {
        _set(event, ItemState.success(state.event));
        _set(canControl, state.canControl);
        _set(canVote, state.canVote);
        _showPlayback(state.playback);
        _showQueue(state.queue);
      },
      // A dropped connection keeps what is shown: only a screen with nothing
      // yet, or an event that is gone, shows it.
      onError: (error) {
        if (event.value.data == null || error is NotFoundError) {
          _set(event, ItemState.error(error, event.value.data));
          _set(playback, ItemState.error(error, playback.value.data));
          _set(queue, ListState.error(error, queue.value.data));
        }
      },
      retryDelays: retryDelays,
    );
  }

  /// Opens the stream. Completes once the first state is shown, or the first
  /// attempt failed.
  Future<void> start() {
    _set(event, ItemState.loading(event.value.data));
    _set(playback, ItemState.loading(playback.value.data));
    _set(queue, ListState.loading(queue.value.data));
    unawaited(_loadHost());
    return _live.start();
  }

  Future<void> _loadHost() async {
    try {
      final members = await _api.members(_eventPublicId, _userPublicId);
      _set(host, members.where((m) => m.isHost).firstOrNull);
    } on AppError {
      // Not worth an error on the page: it says "the host" instead.
    }
  }

  void stop() {
    _stopped = true;
    _device.removeListener(_onDevice);
    _live.stop();
    _audio?.dispose();
    event.dispose();
    playback.dispose();
    queue.dispose();
    canControl.dispose();
    canVote.dispose();
    playsHere.dispose();
    host.dispose();
  }

  /// Reads what is playing and the queue again, and opens the stream again
  /// if it had ended for good.
  Future<void> refresh() async {
    await Future.wait([_loadPlayback(), _loadQueue()]);
    _live.resume();
  }

  // --- The buttons. Each throws the server's AppError for the page to show,
  // --- leaving the state as it was.

  /// Starts the first song when nothing plays, otherwise pauses or resumes.
  Future<void> togglePlay() async {
    final current = playback.value.data;
    if (current == null || current.track == null) {
      return next();
    }
    // Pause where the song is now, not where it was at the last read; resume
    // from exactly where it was paused.
    _showPlayback(await _api.setPlayback(
      _eventPublicId,
      _userPublicId,
      isPaused: !current.isPaused,
      position: current.isPaused ? current.position : current.positionAt(_now()),
    ));
  }

  /// Plays the most-voted song in the queue.
  Future<void> next() async {
    try {
      final result = await _api.playNext(_eventPublicId, _userPublicId);
      _showPlayback(result.playback);
      _showQueue(result.queue);
    } on PreconditionFailedError {
      // The queue was empty. The server has also stopped the song that was
      // playing, if any: read it back so the screen does not keep showing it.
      unawaited(refresh());
      rethrow;
    }
  }

  /// Restarts the current song: a vote queue has no "previous" song, played
  /// entries leave it (docs/todo.md §4, D2).
  Future<void> previous() => seek(Duration.zero);

  /// Moves the playhead, keeping the song paused or playing as it was.
  Future<void> seek(Duration position) async {
    final current = playback.value.data;
    if (current == null || current.track == null) {
      return;
    }
    _showPlayback(await _api.setPlayback(
      _eventPublicId,
      _userPublicId,
      isPaused: current.isPaused,
      position: position,
    ));
  }

  /// Upvotes [entry] and shows the queue the server answers with, re-sorted.
  /// Throws the server's [AppError], or [NotFoundError] when the song has
  /// left the queue (it started playing meanwhile).
  Future<void> vote(QueueEntry entry) async {
    final ({bool accepted, List<QueueEntry> queue}) result;
    try {
      result = await _api.castVote(_eventPublicId, _userPublicId, entry.publicId,
          at: await _whereIfAsked());
    } on NotFoundError {
      // The interceptor no longer finds the entry: read the queue so it
      // leaves the screen too.
      unawaited(_loadQueue());
      rethrow;
    }
    _showQueue(result.queue);
    // Not counted and gone from the queue: it was played. Not counted and
    // still there: already voted, which the queue now shows.
    if (!result.accepted && !result.queue.any((e) => e.publicId == entry.publicId)) {
      throw const NotFoundError('the song left the queue');
    }
  }

  /// Adds [track] (a search result) to the queue and shows the queue the
  /// server answers with; it comes with no votes, so at the bottom of it.
  /// Nothing starts playing: only the host's play does. Throws the server's
  /// [AppError]: [ConflictError] when the song is already queued or playing.
  Future<void> suggest(EventTrack track) async {
    _showQueue(await _api.suggestSong(_eventPublicId, _userPublicId, track.deezerId,
        at: await _whereIfAsked()));
  }

  /// Where the phone is, for an event that only counts votes and suggestions
  /// from its venue (`location_time`); null for any other, which is not
  /// asked. Throws [PositionUnavailableError] when it is asked and unknown:
  /// sending no position would only get a refusal that says less.
  Future<Position?> _whereIfAsked() async {
    if (event.value.data?.voteLicense != 'location_time') {
      return null;
    }
    final at = await _positions.current();
    if (at == null) {
      throw const PositionUnavailableError('position not available');
    }
    return at;
  }

  // --- Loading.

  Future<void> _loadPlayback() async {
    _set(playback, ItemState.loading(playback.value.data));
    try {
      final result = await _api.playback(_eventPublicId, _userPublicId);
      _set(canControl, result.canControl);
      _showPlayback(result.playback);
    } on AppError catch (error) {
      _set(playback, ItemState.error(error, playback.value.data));
    }
  }

  Future<void> _loadQueue() async {
    final generation = ++_queueGeneration;
    _set(queue, ListState.loading(queue.value.data));
    try {
      final entries = await _api.queue(_eventPublicId, _userPublicId);
      if (generation == _queueGeneration) {
        _set(queue, ListState.success(entries, hasReachedEnd: true));
      }
    } on AppError catch (error) {
      if (generation == _queueGeneration) {
        _set(queue, ListState.error(error, queue.value.data));
      }
    }
  }

  /// Shows a queue that came with a button's answer or a push, newer than
  /// any read in flight.
  void _showQueue(List<QueueEntry> entries) {
    _queueGeneration++;
    _set(queue, ListState.success(entries, hasReachedEnd: true));
  }

  /// Shows [next] and makes the speaker follow it.
  void _showPlayback(EventPlayback next) {
    if (_stopped) {
      return;
    }
    playback.value = ItemState.success(next);

    final speaker = _isSpeaker(next);
    playsHere.value = speaker;
    if (speaker) {
      if (next.track != null) {
        _audio ??= _newAudio();
      }
      _audio?.follow(next);
    } else {
      _audio?.dispose();
      _audio = null;
    }
  }

  /// Whether this app plays the sound: it runs on the event's speaker device,
  /// the one the host first pressed play from. A delegate's phone is a
  /// remote, and so is the host's second device. Before any speaker (the
  /// host's app never registered its device), the host's app plays, as the
  /// only one in control then.
  bool _isSpeaker(EventPlayback playback) {
    final speaker = playback.speakerDeviceId;
    return speaker == null ? canControl.value : speaker == _device.value;
  }

  void _onDevice() {
    if (playback.value.data case final current?) {
      _showPlayback(current);
    }
  }

  void _set<T>(ValueNotifier<T> notifier, T value) {
    if (!_stopped) {
      notifier.value = value;
    }
  }
}
