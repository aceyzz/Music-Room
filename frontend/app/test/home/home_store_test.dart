import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/features/home/presentation/stores/home_store.dart';

import '../auth/fake_auth_api.dart';
import 'fake_home_apis.dart';

void main() {
  late FakeEventApi events;
  late FakeUserApi users;
  late FakePlaylistApi playlists;
  late HomeStore store;
  final now = DateTime.utc(2026, 10, 3, 20);

  setUp(() {
    events = FakeEventApi()..events = [event('live', status: 'live'), event('next')];
    users = FakeUserApi()..friends = const [FriendSummary(publicId: 'u-2', displayName: 'trinity')];
    playlists = FakePlaylistApi()
      ..playlists = [
        for (var i = 0; i < 8; i++) PlaylistSummary(publicId: 'p-$i', name: 'P$i', songCount: i),
      ];
    store = HomeStore(events, users, playlists, 'u-1', now: () => now);
  });

  test('start loads the three sections', () async {
    await store.start();

    expect(store.events.value.data?.current.single.publicId, 'live');
    expect(store.events.value.data?.upcoming.single.publicId, 'next');
    expect(store.friends.value.data?.single.displayName, 'trinity');
    expect(store.playlists.value.data, hasLength(HomeStore.playlistCount));
  });

  test('a failing section does not stop the others, and its retry recovers', () async {
    users.failure = const NetworkError('offline');
    await store.start();

    expect(store.friends.value.error, isA<NetworkError>());
    expect(store.events.value.hasData, isTrue);
    expect(store.playlists.value.hasData, isTrue);

    users.failure = null;
    await store.reloadFriends();
    expect(store.friends.value.hasError, isFalse);
    expect(store.friends.value.data, hasLength(1));
  });

  test('a request finishing after stop does not touch the disposed state', () async {
    final pending = store.start();
    store.stop();
    await pending; // would throw "used after being disposed"
  });
}
