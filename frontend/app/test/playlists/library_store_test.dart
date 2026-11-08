import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/features/music/playlist/presentation/stores/library_store.dart';

import '../home/fake_home_apis.dart';

List<LibraryPlaylist> publicList(String prefix, int count) => [
      for (var i = 0; i < count; i++)
        libraryPlaylist('$prefix$i', relation: PlaylistRelation.public, owner: 'smith'),
    ];

void main() {
  late FakePlaylistApi api;
  late LibraryStore store;

  setUp(() {
    api = FakePlaylistApi()
      ..libraryPlaylists = [libraryPlaylist('m')]
      ..publicPlaylistsByQuery = {
        '': publicList('p', 3),
        'rock': publicList('rock', 1),
      };
    store = LibraryStore(api, 'u-1', 'neo');
  });

  List<String>? ids(List<LibraryPlaylist>? list) => list?.map((p) => p.publicId).toList();

  test('start loads the library only', () async {
    await store.start();

    expect(api.calls, ['library']);
    expect(ids(store.library.value.data), ['m']);
  });

  test('public playlists load the first time they are asked for, once', () async {
    await store.ensurePublicLoaded();
    await store.ensurePublicLoaded();

    expect(api.calls, ['publicPlaylists()']);
    expect(ids(store.publicResults.value.data), ['p0', 'p1', 'p2']);
    expect(store.publicResults.value.hasReachedEnd, isTrue);
  });

  // Real waits rather than fake time: fake_async is not a dependency.
  Future<void> wait(Duration d) => Future<void>.delayed(d);
  final afterDelay = LibraryStore.searchDelay + const Duration(milliseconds: 50);

  test('a search is sent once typing pauses', () async {
    store.search('r');
    await wait(const Duration(milliseconds: 100));
    store.search('roc');
    await wait(const Duration(milliseconds: 100));
    store.search('rock ');
    expect(api.calls, isEmpty);
    await wait(afterDelay);

    expect(api.calls, ['publicPlaylists(rock)']);
    expect(ids(store.publicResults.value.data), ['rock0']);
    expect(store.resultsQuery, 'rock');
  });

  test('a slow answer to an older search is dropped', () async {
    final slow = Completer<void>();
    api.beforePublicAnswer = (query) => query == 'ro' ? slow.future : Future.value();

    store.search('ro');
    final older = store.reloadPublic(); // what the timer would run
    store.search('rock');
    await store.reloadPublic();
    slow.complete();
    await older;

    expect(ids(store.publicResults.value.data), ['rock0']);
    expect(store.resultsQuery, 'rock');
  });

  test('a new search clears the results of the previous one while it loads', () async {
    await store.ensurePublicLoaded();
    final slow = Completer<void>();
    api.beforePublicAnswer = (_) => slow.future;

    store.search('rock');
    final pending = store.reloadPublic();
    expect(store.publicResults.value.isLoading, isTrue);
    expect(store.publicResults.value.data, isNull);

    slow.complete();
    await pending;
    expect(ids(store.publicResults.value.data), ['rock0']);
  });

  test('loadMorePublic appends the next page and stops at the end', () async {
    api.publicPlaylistsByQuery = {'': publicList('p', LibraryStore.pageSize + 5)};
    await store.ensurePublicLoaded();
    expect(store.publicResults.value.data, hasLength(LibraryStore.pageSize));
    expect(store.publicResults.value.hasReachedEnd, isFalse);

    await store.loadMorePublic();
    await store.loadMorePublic(); // at the end: no request

    expect(store.publicResults.value.data, hasLength(LibraryStore.pageSize + 5));
    expect(store.publicResults.value.hasReachedEnd, isTrue);
    expect(api.calls, ['publicPlaylists()', 'publicPlaylists(, ${LibraryStore.pageSize})']);
  });

  test('a failed next page keeps the rows, and retry fetches that page', () async {
    api.publicPlaylistsByQuery = {'': publicList('p', LibraryStore.pageSize + 1)};
    await store.ensurePublicLoaded();
    api.failure = const NetworkError('offline');

    await store.loadMorePublic();
    expect(store.publicResults.value.error, isA<NetworkError>());
    expect(store.publicResults.value.data, hasLength(LibraryStore.pageSize));

    api.failure = null;
    await store.retryPublic();
    expect(store.publicResults.value.hasError, isFalse);
    expect(store.publicResults.value.data, hasLength(LibraryStore.pageSize + 1));
  });

  test('a failed library load is reported, and reload recovers', () async {
    api.failure = const NetworkError('offline');
    await store.start();
    expect(store.library.value.error, isA<NetworkError>());

    api.failure = null;
    await store.reloadLibrary();
    expect(ids(store.library.value.data), ['m']);
  });

  test('nothing is written after stop, and a waiting search is cancelled', () async {
    final pending = store.start();
    store.search('rock');
    store.stop();
    await pending; // would throw "used after being disposed"
    await wait(afterDelay);

    expect(api.calls, ['library']);
  });

  test('create puts the new playlist at the top of the library, as yours', () async {
    await store.start();

    final created = await store.create(
      name: 'Road trip',
      visibility: PlaylistVisibility.private,
      editLicense: EditLicense.invitedOnly,
    );

    expect(api.created.single, (
      owner: 'u-1',
      name: 'Road trip',
      visibility: PlaylistVisibility.private,
      editLicense: EditLicense.invitedOnly
    ));
    expect(ids(store.library.value.data), ['new-1', 'm']);
    expect(created.relation, PlaylistRelation.mine);
    expect(created.subtitle, '1 editor · 0 songs');
    expect(created.ownerName, 'neo');
  });

  test('a reload keeps a new playlist until the server lists it, then shows the server\'s',
      () async {
    await store.start();
    await store.create(
      name: 'Road trip',
      visibility: PlaylistVisibility.public,
      editLicense: EditLicense.everyone,
    );

    // Not listed yet (OpenFGA has not caught up): still shown, at the top.
    await store.reloadLibrary();
    expect(ids(store.library.value.data), ['new-1', 'm']);

    // Listed now, with the songs added meanwhile: the server's row wins.
    api.libraryPlaylists = [libraryPlaylist('new-1', songs: 3), libraryPlaylist('m')];
    await store.reloadLibrary();
    expect(ids(store.library.value.data), ['new-1', 'm']);
    expect(store.library.value.data!.first.songCount, 3);
  });

  test('a failed create throws and leaves the library as it was', () async {
    await store.start();
    api.failure = const InvalidInputError('name is required');

    await expectLater(
      store.create(
        name: 'x',
        visibility: PlaylistVisibility.public,
        editLicense: EditLicense.everyone,
      ),
      throwsA(isA<InvalidInputError>()),
    );
    expect(ids(store.library.value.data), ['m']);
  });
}
