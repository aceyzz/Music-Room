import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/features/music/playlist/presentation/stores/playlist_editor_store.dart';

import 'fake_playlist_editor_api.dart';

void main() {
  late FakePlaylistEditorApi api;
  late PlaylistEditorStore store;

  setUp(() {
    api = FakePlaylistEditorApi()..seed([song(11, 'a'), song(12, 'b'), song(13, 'c')]);
    // Retried at once, so a test sees the stream come back without waiting.
    store = PlaylistEditorStore(api, 'p1', 'u1', retryDelays: const [Duration.zero]);
  });

  tearDown(() => store.stop());

  List<String> shown() => [for (final e in store.songs.value.data!) e.track.title];

  test('start loads the playlist, its songs in order and the edit right', () async {
    api.canEdit = false;
    await store.start();

    expect(store.details.value.data!.name, 'Road trip');
    expect(shown(), ['a', 'b', 'c']);
    expect(store.canEdit.value, isFalse);
  });

  test('a failed load is reported, and refresh recovers', () async {
    api.failure = const NetworkError('offline');
    await store.start();
    expect(store.details.value.error, isA<NetworkError>());

    api.failure = null;
    await store.refresh();
    expect(store.details.value.hasError, isFalse);
    expect(shown(), ['a', 'b', 'c']);
  });

  test('add appends the song, and shows what others added meanwhile', () async {
    await store.start();
    api.othersEdit((rows) => rows.add(rows.first)); // someone added "a" again

    await store.add(song(42, 'One More Time'));
    expect(api.calls.last, 'add 42');
    expect(shown(), ['a', 'b', 'c', 'a', 'Song 42']);
  });

  test('a song already there is refused, until it is allowed', () async {
    await store.start();

    await expectLater(store.add(song(12, 'b')), throwsA(isA<ConflictError>()));
    expect(shown(), ['a', 'b', 'c']);

    await store.add(song(12, 'b'), allowDuplicate: true);
    expect(api.calls.last, 'add 12 again');
    expect(shown(), ['a', 'b', 'c', 'Song 12']);
  });

  test('remove takes the row off at once', () async {
    await store.start();
    final b = store.songs.value.data![1];

    final removing = store.remove(b);
    expect(shown(), ['a', 'c'], reason: 'before the server answers');
    await removing;
    expect(api.calls.last, 'remove 2');
    expect(shown(), ['a', 'c']);
  });

  test('removing a row someone else already removed is not an error', () async {
    await store.start();
    final b = store.songs.value.data![1];
    api.othersEdit((rows) => rows.removeAt(1));

    await store.remove(b); // does not throw
    await pumpEventQueue();
    expect(shown(), ['a', 'c']);
  });

  test('a refused remove puts the row back', () async {
    await store.start();
    final b = store.songs.value.data![1];
    api.failNext = const UnauthorizedError('permission denied');

    await expectLater(store.remove(b), throwsA(isA<UnauthorizedError>()));
    await pumpEventQueue();
    expect(shown(), ['a', 'b', 'c']);
  });

  group('move tells the server which song it now follows', () {
    for (final (name, from, to, anchor, order) in [
      ('to the top', 2, 0, 'move 3 after 0', ['c', 'a', 'b']),
      ('down one', 0, 1, 'move 1 after 2', ['b', 'a', 'c']),
      ('to the end', 0, 2, 'move 1 after 3', ['b', 'c', 'a']),
      ('up into the middle', 2, 1, 'move 3 after 1', ['a', 'c', 'b']),
    ]) {
      test(name, () async {
        await store.start();

        final moving = store.move(from, to);
        expect(shown(), order, reason: 'it lands at once');
        await moving;
        expect(api.calls.last, anchor);
        expect(shown(), order);
      });
    }

    test('not at all when dropped where it was', () async {
      await store.start();
      await store.move(1, 1);
      expect(api.calls, ['watch']);
    });
  });

  test('a move under a song someone else removed is refused, and the list reloads', () async {
    await store.start();
    api.othersEdit((rows) => rows.removeAt(0)); // "a" is gone, the screen still shows it

    // "c" dropped under "a".
    await expectLater(store.move(2, 1), throwsA(isA<NotFoundError>()));
    await pumpEventQueue();
    expect(shown(), ['b', 'c']);
  });

  test("a move keeps others' changes elsewhere in the list", () async {
    await store.start();
    api.othersEdit((rows) => rows.add(PlaylistEntry(id: 50, track: song(14, 'd'))));

    await store.move(2, 0); // "c" to the top, on a list without "d"
    expect(shown(), ['c', 'a', 'b', 'd']);
  });

  test('a read that started before an edit does not undo it', () async {
    await store.start();
    final hold = Completer<void>();
    api.holdOpen = hold;
    final slowRead = store.refresh();
    api.holdOpen = null;
    await store.move(2, 0);
    expect(shown(), ['c', 'a', 'b']);

    // The read answers with the list as it was before the move.
    hold.complete();
    await slowRead;
    expect(shown(), ['c', 'a', 'b']);
  });

  test("a push shows another editor's change", () async {
    await store.start();
    api.othersEdit((rows) => rows.removeAt(1));

    api.push();
    await pumpEventQueue();
    expect(shown(), ['a', 'c']);
  });

  test('a push older than an edit does not undo it', () async {
    await store.start();
    final stale = api.revision;
    await store.move(2, 0);

    api.revision = stale; // what a push sent before the move carries
    api.push();
    await pumpEventQueue();
    expect(shown(), ['c', 'a', 'b']);
  });

  test('the stream reopens after it drops, and shows what changed meanwhile', () async {
    await store.start();
    api.endWatches();
    api.othersEdit((rows) => rows.removeAt(0));

    await pumpEventQueue();
    expect(api.calls.where((c) => c == 'watch'), hasLength(2));
    expect(shown(), ['b', 'c']);
  });

  test('a playlist that is gone ends the stream for good', () async {
    await store.start();
    api.failure = const NotFoundError('playlist not found');
    api.endWatches();

    await pumpEventQueue();
    expect(store.details.value.error, isA<NotFoundError>());
    await pumpEventQueue();
    expect(api.calls.where((c) => c == 'watch'), hasLength(2), reason: 'no third attempt');
  });

  test('nothing is written after stop', () async {
    final loading = store.start();
    store.stop();
    await loading; // would throw if it wrote to a disposed notifier
    store = PlaylistEditorStore(api, 'p1', 'u1'); // for tearDown
  });
}
