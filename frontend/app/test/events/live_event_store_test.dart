import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/location/position_source.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/features/event/presentation/stores/live_event_store.dart';

import 'fake_live_event_api.dart';

void main() {
  late FakeLiveEventApi api;
  late FakeAudioOutput audio;
  late int audiosCreated;
  late LiveEventStore store;

  final updatedAt = DateTime(2026, 10, 3, 21);
  // Five seconds after the server's last answer.
  final now = updatedAt.add(const Duration(seconds: 5));

  EventPlayback playing(Duration position, {bool paused = false, String title = 'a'}) =>
      EventPlayback(
        currentEntryId: 1,
        track: track(title),
        isPaused: paused,
        position: position,
        updatedAt: updatedAt,
      );

  setUp(() {
    api = FakeLiveEventApi()..queued = [entry('q1', votes: 3), entry('q2')];
    audio = FakeAudioOutput();
    audiosCreated = 0;
    store = LiveEventStore(api, 'e1', 'u1',
        audio: () {
          audiosCreated++;
          return audio;
        },
        now: () => now,
        // Retried at once, so a test sees the stream come back without waiting.
        retryDelays: const [Duration.zero]);
  });

  tearDown(() => store.stop());

  test('start loads the event, what plays, who controls it and the queue', () async {
    api
      ..current = playing(const Duration(seconds: 10))
      ..canControl = true;
    await store.start();

    expect(store.event.value.data!.publicId, 'e1');
    expect(store.playback.value.data!.track!.title, 'a');
    expect(store.canControl.value, isTrue);
    expect(store.queue.value.data!.map((e) => e.publicId), ['q1', 'q2']);
  });

  test('pause sends where the song is now, not where it was last read', () async {
    api
      ..current = playing(const Duration(seconds: 10))
      ..canControl = true;
    await store.start();
    await store.togglePlay();

    expect(api.sent.single, (isPaused: true, position: const Duration(seconds: 15)));
    expect(store.playback.value.data!.isPaused, isTrue);
  });

  test('resume starts from where it was paused', () async {
    api
      ..current = playing(const Duration(seconds: 12), paused: true)
      ..canControl = true;
    await store.start();
    await store.togglePlay();

    expect(api.sent.single, (isPaused: false, position: const Duration(seconds: 12)));
  });

  test('play with nothing playing starts the most-voted song', () async {
    api
      ..canControl = true
      ..afterNext = playing(Duration.zero, title: 'Song q1');
    await store.start();
    await store.togglePlay();

    expect(api.nextCalls, 1);
    expect(api.sent, isEmpty);
    expect(store.playback.value.data!.track!.title, 'Song q1');
    expect(store.queue.value.data!.map((e) => e.publicId), ['q2']);
  });

  test('previous restarts the song, keeping it paused or playing', () async {
    api
      ..current = playing(const Duration(seconds: 20), paused: true)
      ..canControl = true;
    await store.start();
    await store.previous();

    expect(api.sent.single, (isPaused: true, position: Duration.zero));
  });

  test('seek moves the playhead', () async {
    api
      ..current = playing(const Duration(seconds: 3))
      ..canControl = true;
    await store.start();
    await store.seek(const Duration(seconds: 22));

    expect(api.sent.single, (isPaused: false, position: const Duration(seconds: 22)));
  });

  test('next on an empty queue throws and reads the playback back', () async {
    api
      ..current = playing(const Duration(seconds: 3))
      ..canControl = true
      ..nextFailure = const PreconditionFailedError('the queue is empty');
    await store.start();
    final readsBefore = api.playbackReads;

    await expectLater(store.next(), throwsA(isA<PreconditionFailedError>()));
    await pumpEventQueue();
    expect(api.playbackReads, readsBefore + 1);
  });

  test('the person in control plays the sound', () async {
    api
      ..current = playing(const Duration(seconds: 10))
      ..canControl = true;
    await store.start();
    await store.togglePlay();

    expect(audiosCreated, 1);
    expect(audio.followed.map((p) => p.isPaused), [false, true]);

    store.stop();
    expect(audio.disposed, isTrue);
    store = LiveEventStore(api, 'e1', 'u1', audio: () => FakeAudioOutput()); // for tearDown
  });

  test('everyone else stays silent', () async {
    api.current = playing(const Duration(seconds: 10));
    await store.start();

    expect(store.canControl.value, isFalse);
    expect(audiosCreated, 0);
  });

  group('the sound plays on the speaker device only', () {
    final device = ValueNotifier<int?>(null);
    setUp(() {
      device.value = null;
      store.stop();
      store = LiveEventStore(api, 'e1', 'u1',
          audio: () {
            audiosCreated++;
            return audio;
          },
          now: () => now,
          device: device);
    });

    EventPlayback onSpeaker(int speaker) => EventPlayback(
          currentEntryId: 1,
          track: track('a'),
          isPaused: false,
          position: const Duration(seconds: 10),
          updatedAt: updatedAt,
          speakerDeviceId: speaker,
        );

    test('a delegate in control stays silent: another device plays it', () async {
      device.value = 8;
      api
        ..current = onSpeaker(7)
        ..canControl = true;
      await store.start();
      await store.togglePlay();

      expect(store.canControl.value, isTrue);
      expect(api.sent, hasLength(1), reason: 'the button still works');
      expect(audiosCreated, 0);
      expect(store.playsHere.value, isFalse, reason: 'the banner says where it plays');
    });

    test('the speaker device plays it', () async {
      device.value = 7;
      api
        ..current = onSpeaker(7)
        ..canControl = true;
      await store.start();

      expect(audiosCreated, 1);
      expect(audio.followed.single.isPlaying, isTrue);
      expect(store.playsHere.value, isTrue);
    });

    test('a device registered after the page opened takes up the sound', () async {
      api
        ..current = onSpeaker(7)
        ..canControl = true;
      await store.start();
      expect(audiosCreated, 0);

      device.value = 7;
      expect(audiosCreated, 1);
    });
  });

  test('a failed load is reported, and refresh recovers', () async {
    api.failure = const NetworkError('offline');
    await store.start();
    expect(store.playback.value.error, isA<NetworkError>());

    api.failure = null;
    await store.refresh();
    expect(store.playback.value.error, isNull);
    expect(store.playback.value.data, isNotNull);
  });

  test('a vote shows the queue it answers with, re-sorted', () async {
    await store.start();
    await store.vote(store.queue.value.data![1]);

    expect(api.votes, ['q2']);
    final queue = store.queue.value.data!;
    expect(queue.map((e) => (e.publicId, e.voteCount, e.viewerHasVoted)), [
      ('q1', 3, false),
      ('q2', 1, true),
    ]);
  });

  test('a read that started before a vote does not hide it', () async {
    await store.start();
    api.holdQueue = Completer();
    final slowRead = store.refresh();
    await store.vote(store.queue.value.data![1]);
    api.holdQueue!.complete();
    await slowRead;

    final q2 = store.queue.value.data!.firstWhere((e) => e.publicId == 'q2');
    expect((q2.voteCount, q2.viewerHasVoted), (1, true));
  });

  test('a vote for a song that left the queue throws NotFoundError', () async {
    await store.start();
    final gone = store.queue.value.data!.first;
    api.queued = [entry('q2')];

    await expectLater(store.vote(gone), throwsA(isA<NotFoundError>()));
    expect(store.queue.value.data!.map((e) => e.publicId), ['q2']);
  });

  test('a second vote for the same song is not an error', () async {
    api.queued = [entry('q1', votes: 3, voted: true)];
    await store.start();

    await store.vote(store.queue.value.data!.single);
    expect(store.queue.value.data!.single.voteCount, 3);
  });

  test('a suggestion joins the queue with no votes, after the voted songs', () async {
    api.current = playing(const Duration(seconds: 10));
    await store.start();
    await store.suggest(const EventTrack(
      deezerId: 42,
      title: 'Around the World',
      artist: 'Daft Punk',
      duration: Duration(seconds: 30),
    ));

    expect(api.suggested, [42]);
    expect(store.queue.value.data!.map((e) => (e.publicId, e.voteCount)), [
      ('q1', 3),
      ('q2', 0),
      ('s42', 0),
    ]);
    expect(store.playback.value.data!.track!.title, 'a', reason: 'something was playing');
  });

  test('a suggestion into a silent event queues it, and nothing starts', () async {
    await store.start();
    expect(store.playback.value.data!.track, isNull);

    await store
        .suggest(const EventTrack(title: 'x', artist: 'y', duration: Duration.zero, deezerId: 7));
    expect(store.playback.value.data!.track, isNull);
    expect(store.queue.value.data!.map((e) => e.track.deezerId), contains(7));
  });

  test('a song already queued is refused with ConflictError', () async {
    api.queued = [entry('q1', deezerId: 42)];
    await store.start();

    await expectLater(
      store.suggest(
          const EventTrack(title: 'x', artist: 'y', duration: Duration.zero, deezerId: 42)),
      throwsA(isA<ConflictError>()),
    );
    expect(store.queue.value.data!.map((e) => e.publicId), ['q1']);
  });

  test('a read that started before a suggestion does not hide it', () async {
    api.current = playing(const Duration(seconds: 10));
    await store.start();
    api.holdQueue = Completer();
    final slowRead = store.refresh();
    await store
        .suggest(const EventTrack(title: 'x', artist: 'y', duration: Duration.zero, deezerId: 5));
    api.holdQueue!.complete();
    await slowRead;

    expect(store.queue.value.data!.map((e) => e.publicId), contains('s5'));
  });

  test("a push shows the others' votes and the host's pause", () async {
    api.current = playing(const Duration(seconds: 3));
    await store.start();

    api
      ..queued = [entry('q2', votes: 5), entry('q1', votes: 3)]
      ..current = playing(const Duration(seconds: 8), paused: true);
    api.push();
    await pumpEventQueue();

    expect(store.queue.value.data!.map((e) => e.publicId), ['q2', 'q1']);
    expect(store.playback.value.data!.isPaused, isTrue);
  });

  test('the next song arrives by push when the server moves on', () async {
    api.current = playing(const Duration(seconds: 29));
    await store.start();

    api.current = playing(Duration.zero, title: 'b');
    api.push();
    await pumpEventQueue();

    expect(store.playback.value.data!.track!.title, 'b');
    expect(api.playbackReads, 0, reason: 'no timer reads it back');
  });

  test('the stream reopens after it drops, and shows what changed meanwhile', () async {
    await store.start();
    api.endWatches();
    api.queued = [entry('q3')];

    await pumpEventQueue();
    expect(api.watches, 2);
    expect(store.queue.value.data!.map((e) => e.publicId), ['q3']);
  });

  test('an event that is gone ends the stream for good', () async {
    await store.start();
    api.failure = const NotFoundError('event not found');
    api.endWatches();

    await pumpEventQueue();
    expect(store.event.value.error, isA<NotFoundError>());
    await pumpEventQueue();
    expect(api.watches, 2, reason: 'no third attempt');
  });

  group('an event that only counts people at its venue (location_time)', () {
    late FakePositionSource positions;

    setUp(() {
      store.stop();
      positions = FakePositionSource((latitude: 48.85, longitude: 2.35));
      api
        ..eventSummary = EventSummary(
          publicId: 'e1',
          name: 'At the venue',
          status: 'live',
          createdAt: DateTime(2026),
          voteLicense: 'location_time',
        )
        ..queued = [entry('q1')];
      store =
          LiveEventStore(api, 'e1', 'u1', audio: () => audio, now: () => now, positions: positions);
    });

    test('a vote and a suggestion carry where the phone is', () async {
      await store.start();
      await store.vote(store.queue.value.data!.first);
      await store.suggest(
          const EventTrack(title: 'new', artist: 'a', duration: Duration.zero, deezerId: 7));

      expect(api.positionsSent, [
        (latitude: 48.85, longitude: 2.35),
        (latitude: 48.85, longitude: 2.35),
      ]);
    });

    test('with no position, nothing is sent and the reason is given', () async {
      positions.position = null;
      await store.start();

      await expectLater(
        store.vote(store.queue.value.data!.first),
        throwsA(isA<PositionUnavailableError>()),
      );
      expect(api.votes, isEmpty);
    });
  });

  test('any other event does not ask where the phone is', () async {
    final positions = FakePositionSource((latitude: 1, longitude: 1));
    store.stop();
    store =
        LiveEventStore(api, 'e1', 'u1', audio: () => audio, now: () => now, positions: positions);
    await store.start();
    await store.vote(store.queue.value.data!.first);

    expect(positions.asked, 0);
    expect(api.positionsSent, [null]);
  });

  test('nothing is written after stop', () async {
    final loading = store.start();
    store.stop();
    await loading; // would throw if it wrote to a disposed notifier
    store = LiveEventStore(api, 'e1', 'u1', audio: () => FakeAudioOutput()); // for tearDown
  });
}
