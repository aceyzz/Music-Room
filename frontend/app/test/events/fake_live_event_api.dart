import 'dart:async';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/features/event/data/event_audio_output.dart';
import 'package:app/features/event/data/event_source.dart';

import '../home/fake_home_apis.dart' as home;

/// A 30-second song called [title].
EventTrack track(String title) =>
    EventTrack(title: title, artist: 'Artist of $title', duration: const Duration(seconds: 30));

QueueEntry entry(String id,
        {int votes = 0, bool voted = false, String? artist, int deezerId = 0}) =>
    QueueEntry(
      publicId: id,
      voteCount: votes,
      track: EventTrack(
        deezerId: deezerId,
        title: 'Song $id',
        artist: artist ?? 'Artist of Song $id',
        duration: const Duration(seconds: 30),
      ),
      viewerHasVoted: voted,
    );

/// In-memory [LiveEventApi]. Answers with [eventSummary], [current],
/// [canControl] and [queued]; throws [failure] from every call, or
/// [nextFailure] from playNext only, or [voteFailure] from castVote only, or
/// [suggestFailure] from suggestSong only. Records what the buttons sent. A
/// vote counts once, like the server's, and re-sorts [queued]. A suggestion
/// joins [queued] with no votes, and is refused like the server's when the
/// song is queued or playing. Nothing starts playing on its own.
///
/// watch ([watches] counts them) sends the state when listened to, then again
/// on each [push]: someone else's change reaches the screen only when a test
/// pushes it. [endWatches] drops every open stream (a server restart).
class FakeLiveEventApi implements LiveEventApi {
  /// What [members] answers: the host only, by default.
  List<EventMember> people = const [
    EventMember(displayName: 'Hostie', role: 'owner', publicId: 'u-9'),
  ];

  EventSummary eventSummary = home.event('e1');
  EventPlayback current = EventPlayback.idle(DateTime(2026, 10, 3, 21));
  bool canControl = false;

  /// What the server says of event#can_vote: on by default, the case most
  /// tests are about.
  bool canVote = true;
  List<QueueEntry> queued = const [];

  /// What playNext answers with; the current playback if null.
  EventPlayback? afterNext;
  AppError? failure;
  AppError? nextFailure;
  AppError? voteFailure;
  AppError? suggestFailure;

  /// The position each vote and suggestion carried, in order.
  final List<Position?> positionsSent = [];

  int playbackReads = 0;
  int queueReads = 0;
  int watches = 0;
  final List<StreamController<LiveEventView>> _open = [];

  /// The streams still listened to.
  int get openWatches => _open.length;

  /// What the server would push now to every open stream.
  void push() {
    for (final watch in [..._open]) {
      watch.add(_view());
    }
  }

  /// Ends every open stream with [error], as the server does when the viewer
  /// loses access (NotFoundError).
  void failWatches(AppError error) {
    for (final watch in [..._open]) {
      watch.addError(error);
      watch.close();
    }
  }

  void endWatches() {
    for (final watch in [..._open]) {
      watch.close();
    }
  }

  LiveEventView _view() =>
      (event: eventSummary, playback: current, canControl: canControl, queue: queued, canVote: canVote);

  /// While set, queue reads wait for it, then answer with the queue as it
  /// was when they were asked: a slow read.
  Completer<void>? holdQueue;
  final List<String> votes = [];
  final List<int> suggested = [];

  /// The songs a suggestion can name, as Deezer has them; any other id gets
  /// a made-up song.
  List<EventTrack> catalogue = const [];
  int nextCalls = 0;
  final List<({bool isPaused, Duration position})> sent = [];

  void _fail() {
    if (failure != null) {
      throw failure!;
    }
  }

  @override
  Future<List<EventMember>> members(String eventPublicId, String viewerPublicId) async => people;

  @override
  Future<EventSummary> event(String eventPublicId, String viewerPublicId) async {
    _fail();
    return eventSummary;
  }

  @override
  Stream<LiveEventView> watch(String eventPublicId, String viewerPublicId) {
    watches++;
    late final StreamController<LiveEventView> watch;
    watch = StreamController(
      onListen: () {
        final error = failure;
        if (error != null) {
          watch.addError(error);
          watch.close();
          return;
        }
        _open.add(watch);
        watch.add(_view());
      },
      onCancel: () => _open.remove(watch),
    );
    return watch.stream;
  }

  @override
  Future<({EventPlayback playback, bool canControl})> playback(
    String eventPublicId,
    String viewerPublicId,
  ) async {
    _fail();
    playbackReads++;
    return (playback: current, canControl: canControl);
  }

  @override
  Future<List<QueueEntry>> queue(String eventPublicId, String viewerPublicId) async {
    _fail();
    queueReads++;
    final asked = queued;
    await holdQueue?.future;
    return asked;
  }

  @override
  Future<({EventPlayback playback, List<QueueEntry> queue})> playNext(
    String eventPublicId,
    String userPublicId,
  ) async {
    _fail();
    nextCalls++;
    if (nextFailure != null) {
      throw nextFailure!;
    }
    current = afterNext ?? current;
    queued = queued.skip(1).toList();
    return (playback: current, queue: queued);
  }

  @override
  Future<EventPlayback> setPlayback(
    String eventPublicId,
    String userPublicId, {
    required bool isPaused,
    required Duration position,
  }) async {
    _fail();
    sent.add((isPaused: isPaused, position: position));
    current = EventPlayback(
      currentEntryId: current.currentEntryId,
      track: current.track,
      isPaused: isPaused,
      position: position,
      updatedAt: current.updatedAt,
      speakerDeviceId: current.speakerDeviceId,
    );
    return current;
  }

  @override
  Future<({bool accepted, List<QueueEntry> queue})> castVote(
    String eventPublicId,
    String userPublicId,
    String entryPublicId, {
    Position? at,
  }) async {
    positionsSent.add(at);
    _fail();
    if (voteFailure != null) {
      throw voteFailure!;
    }
    votes.add(entryPublicId);
    final accepted = queued.any((e) => e.publicId == entryPublicId && !e.viewerHasVoted);
    queued = _sorted([
      for (final e in queued)
        if (accepted && e.publicId == entryPublicId)
          QueueEntry(
            publicId: e.publicId,
            voteCount: e.voteCount + 1,
            track: e.track,
            viewerHasVoted: true,
          )
        else
          e,
    ]);
    return (accepted: accepted, queue: queued);
  }

  @override
  Future<List<QueueEntry>> suggestSong(
    String eventPublicId,
    String userPublicId,
    int deezerSongId, {
    Position? at,
  }) async {
    positionsSent.add(at);
    _fail();
    suggested.add(deezerSongId);
    if (suggestFailure != null) {
      throw suggestFailure!;
    }
    if (current.track?.deezerId == deezerSongId ||
        queued.any((e) => e.track.deezerId == deezerSongId)) {
      throw const ConflictError('song already queued for this event');
    }
    final added = QueueEntry(
      publicId: 's$deezerSongId',
      voteCount: 0,
      track: catalogue.where((t) => t.deezerId == deezerSongId).firstOrNull ??
          EventTrack(
            deezerId: deezerSongId,
            title: 'Suggested $deezerSongId',
            artist: 'Someone',
            duration: const Duration(seconds: 30),
          ),
    );
    queued = _sorted([...queued, added]);
    return queued;
  }
}

/// Sorted like the server: most votes first, ties in their current order.
List<QueueEntry> _sorted(List<QueueEntry> entries) {
  final indexed = entries.indexed.toList()
    ..sort((a, b) {
      final byVotes = b.$2.voteCount.compareTo(a.$2.voteCount);
      return byVotes != 0 ? byVotes : a.$1.compareTo(b.$1);
    });
  return [for (final (_, entry) in indexed) entry];
}

/// An [AudioOutput] that only remembers what it was told.
class FakeAudioOutput implements AudioOutput {
  final List<EventPlayback> followed = [];
  bool disposed = false;

  @override
  void follow(EventPlayback playback) => followed.add(playback);

  @override
  void dispose() => disposed = true;
}

/// A [PositionSource] answering [position] (null: not available).
class FakePositionSource implements PositionSource {
  Position? position;
  int asked = 0;

  FakePositionSource([this.position]);

  @override
  Future<Position?> current() async {
    asked++;
    return position;
  }
}
