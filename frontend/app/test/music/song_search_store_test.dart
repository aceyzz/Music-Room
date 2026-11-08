import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/features/music/song/presentation/stores/song_search_store.dart';

import 'fake_song_search_api.dart';

// testWidgets for its fake clock: the store waits 300 ms of quiet typing.
void main() {
  late FakeSongSearchApi api;
  late SongSearchStore store;

  setUp(() {
    api = FakeSongSearchApi()
      ..catalogue = [
        found(1, 'One More Time', artist: 'Daft Punk'),
        found(2, 'Midnight City', artist: 'M83'),
      ];
    store = SongSearchStore(api);
  });

  tearDown(() => store.stop());

  testWidgets('searches once typing pauses for 300 ms', (tester) async {
    store.search('d');
    await tester.pump(const Duration(milliseconds: 200));
    store.search('daft');
    await tester.pump(const Duration(milliseconds: 299));
    expect(api.searches, isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(api.searches, ['daft'], reason: 'two quick edits are one search');
    expect(store.results.value.data!.map((t) => t.deezerId), [1]);
    expect(store.resultsQuery, 'daft');
  });

  testWidgets('an answer to an older query is dropped', (tester) async {
    final slow = Completer<void>();
    api.hold = slow;
    store.search('m');
    await tester.pump(const Duration(milliseconds: 300));
    expect(api.searches, ['m']);

    // Typed on while "m" was in flight.
    api.hold = null;
    store.search('m83');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(store.results.value.data!.single.title, 'Midnight City');

    // "m" answers late, with both songs: not shown.
    slow.complete();
    await tester.pump();
    expect(store.results.value.data!.single.title, 'Midnight City');
    expect(store.resultsQuery, 'm83');
  });

  testWidgets('clearing drops the results with no request', (tester) async {
    store.search('daft');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(store.results.value.hasData, isTrue);

    store.search('  ');
    await tester.pump(const Duration(seconds: 1));
    expect(api.searches, ['daft']);
    expect(store.results.value.data, isNull);
    expect(store.query, '');
  });

  testWidgets('a failed search can be retried', (tester) async {
    api.failure = const NetworkError('offline');
    store.search('daft');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(store.results.value.hasError, isTrue);

    api.failure = null;
    await store.retry();
    expect(store.results.value.data!.single.title, 'One More Time');
    expect(api.searches, ['daft', 'daft']);
  });
}
