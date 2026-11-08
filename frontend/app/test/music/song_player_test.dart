import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/features/music/player/song_player.dart';

void main() {
  test('previewUsable: a link with at least a minute left', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000);
    expect(previewUsable(null, now), isFalse);
    expect(previewUsable('', now), isFalse);
    expect(previewUsable('https://cdn/x.mp3?hdnea=exp=1760000600~acl=/x', now), isTrue);
    expect(previewUsable('https://cdn/x.mp3?hdnea=exp=1759999000~acl=/x', now), isFalse);
    expect(previewUsable('https://cdn/x.mp3?hdnea=exp=1760000030~acl=/x', now), isFalse);
    expect(previewUsable('https://cdn/x.mp3', now), isTrue);
  });

  test('a song with no preview still plays if it has a Deezer id', () {
    const track = EventTrack(title: 't', artist: 'a', duration: Duration(seconds: 30), deezerId: 3);
    expect(canPlay(track), isTrue);
    expect(canPlay(const EventTrack(title: 't', artist: 'a', duration: Duration(seconds: 30))), isFalse);
  });

  test('sameSong ignores the preview link', () {
    const a = EventTrack(title: 't', artist: 'a', duration: Duration(seconds: 30), deezerId: 3, previewUrl: 'old');
    const b = EventTrack(title: 't', artist: 'a', duration: Duration(seconds: 30), deezerId: 3, previewUrl: 'new');
    expect(sameSong(a, b), isTrue);
    expect(sameSong(null, b), isFalse);
  });

  group('followedIndex: the queue follows a playlist edited while it plays', () {
    // Songs 10, 20, 30, 40; 20 plays (index 1).
    const old = [10, 20, 30, 40];

    test('a song added after it plays next', () {
      expect(followedIndex(old, 1, 20, [10, 20, 50, 30, 40]), 1);
    });

    test('a song moved before it: it stays current, at its new place', () {
      expect(followedIndex(old, 1, 20, [10, 40, 20, 30]), 2);
    });

    test('removed while playing: the next song is the one that came after it', () {
      final at = followedIndex(old, 1, 20, [10, 30, 40]);
      expect(at, 0);
      expect([10, 30, 40][at + 1], 30);
    });

    test('removed with the song after it: the next one still there', () {
      final at = followedIndex(old, 1, 20, [10, 40]);
      expect([10, 40][at + 1], 40);
    });

    test('removed again before it ended: still the song after it', () {
      // 20 was removed: index 0, so that 30 plays next. Then 30 goes too.
      final at = followedIndex([10, 30, 40], 0, 20, [10, 40]);
      expect([10, 40][at + 1], 40);
    });

    test('the last one removed: the next song is the first', () {
      final at = followedIndex(old, 3, 40, [10, 20, 30]);
      expect([10, 20, 30][(at + 1) % 3], 10);
    });

    test('everything replaced: the first new song', () {
      expect(followedIndex(old, 1, 20, [60, 70]), -1);
    });
  });

  group('previousIndex: back from the song playing', () {
    test('the song before it, the last one before the first', () {
      expect(previousIndex([10, 20, 30], 1, 20), 0);
      expect(previousIndex([10, 20, 30], 0, 10), 2);
    });

    test('removed while playing: the song that was before it, not the one before that', () {
      // 10, 20, 30, 40, 30 playing, then removed: followedIndex leaves index 1 (20).
      final keys = [10, 20, 40];
      final at = followedIndex([10, 20, 30, 40], 2, 30, keys);
      expect(keys[previousIndex(keys, at, 30)], 20);
    });

    test('the first one removed while playing: back to the last', () {
      final keys = [20, 30];
      final at = followedIndex([10, 20, 30], 0, 10, keys);
      expect(keys[previousIndex(keys, at, 10)], 30);
    });
  });

  group('drop: a playlist the user may no longer see stops playing', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    // No audio plugin under `flutter test`: its global channel answers
    // empty maps, so just_audio's own start-up call does not fail the test. The
    // songs stay silent (SongPlayer logs it), which is all these need.
    setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), (_) async => <String, dynamic>{}));
    const songs = [
      EventTrack(title: 'a', artist: 'x', duration: Duration(seconds: 30), deezerId: 1, previewUrl: 'u1'),
      EventTrack(title: 'b', artist: 'x', duration: Duration(seconds: 30), deezerId: 2, previewUrl: 'u2'),
    ];

    test('its own playlist: the player empties', () async {
      final player = SongPlayer();
      await player.playAll(songs, 0, source: 'p1', keys: [10, 20]);
      expect(player.current, songs[0]);
      await player.drop('p1');
      expect(player.current, isNull);
    });

    test('another playlist: nothing changes', () async {
      final player = SongPlayer();
      await player.playAll(songs, 1, source: 'p1', keys: [10, 20]);
      await player.drop('p2');
      expect(player.current, songs[1]);
    });
  });

  group("the player follows the playlist's live stream itself, whatever page is open", () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUp(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.ryanheise.just_audio.methods'), (_) async => <String, dynamic>{}));
    EventTrack song(String title, int id) =>
        EventTrack(title: title, artist: 'x', duration: const Duration(seconds: 30), deezerId: id, previewUrl: 'u$id');
    final a = song('a', 1), b = song('b', 2), c = song('c', 3);

    test("a song someone adds after the current one plays next", () async {
      final live = StreamController<PlaylistSongs>.broadcast();
      final player = SongPlayer();
      await player.playAll([a, b], 0, source: 'p1', keys: [10, 20], updates: () => live.stream);

      live.add((tracks: [a, c, b], keys: [10, 30, 20]));
      await pumpEventQueue();
      await player.next();
      expect(player.current, c);
    });

    test('losing access to it (NotFound) stops the music', () async {
      final live = StreamController<PlaylistSongs>.broadcast();
      final player = SongPlayer();
      await player.playAll([a, b], 0, source: 'p1', keys: [10, 20], updates: () => live.stream);

      live.addError(const NotFoundError('playlist not found'));
      await pumpEventQueue();
      expect(player.current, isNull);
    });

    test('a dropped connection keeps the music on', () async {
      final live = StreamController<PlaylistSongs>.broadcast();
      final player = SongPlayer();
      await player.playAll([a, b], 0, source: 'p1', keys: [10, 20], updates: () => live.stream);

      live.addError(const NetworkError('connection reset'));
      await pumpEventQueue();
      expect(player.current, a);
      player.dispose();
    });

    test('another playlist playing closes the first one\'s stream', () async {
      final live = StreamController<PlaylistSongs>.broadcast();
      final player = SongPlayer();
      await player.playAll([a, b], 0, source: 'p1', keys: [10, 20], updates: () => live.stream);
      expect(live.hasListener, isTrue);

      await player.playAll([c], 0, source: 'p2', keys: [30]);
      expect(live.hasListener, isFalse);
    });
  });
}
