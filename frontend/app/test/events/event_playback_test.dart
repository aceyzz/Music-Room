import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/gen/music_room/v1/dto/song.pb.dart';
import 'package:fixnum/fixnum.dart';

import 'fake_live_event_api.dart';

void main() {
  final updatedAt = DateTime(2026, 10, 3, 21);

  EventPlayback at(Duration position, {bool paused = false}) => EventPlayback(
        currentEntryId: 1,
        track: track('a'),
        isPaused: paused,
        position: position,
        updatedAt: updatedAt,
      );

  test('a playing song moves on from where the server last saw it', () {
    final playback = at(const Duration(seconds: 10));
    expect(
      playback.positionAt(updatedAt.add(const Duration(seconds: 5))),
      const Duration(seconds: 15),
    );
  });

  test('a paused song stays where it was paused', () {
    final playback = at(const Duration(seconds: 10), paused: true);
    expect(
      playback.positionAt(updatedAt.add(const Duration(minutes: 5))),
      const Duration(seconds: 10),
    );
  });

  test('the playhead stops at the end of the song', () {
    final playback = at(const Duration(seconds: 25));
    expect(
      playback.positionAt(updatedAt.add(const Duration(seconds: 20))),
      const Duration(seconds: 30),
    );
  });

  test('a clock behind the server never shows a negative time', () {
    final playback = at(Duration.zero);
    expect(playback.positionAt(updatedAt.subtract(const Duration(seconds: 2))), Duration.zero);
  });

  test('nothing playing is at zero and not playing', () {
    final idle = EventPlayback.idle(updatedAt);
    expect(idle.positionAt(updatedAt.add(const Duration(seconds: 5))), Duration.zero);
    expect(idle.isPlaying, isFalse);
  });

  test("a song keeps its Deezer id: it is what a suggestion sends", () {
    final song = SongDTO(
      id: Int64(-1), // a search result: not stored yet
      deezerSongId: Int64(3135556),
      title: 'Harder, Better, Faster, Stronger',
      artistName: 'Daft Punk',
      durationSeconds: Int64(30),
    ).toTrack();
    expect(song.deezerId, 3135556);
    expect(song.coverUrl, isNull);
  });
}
