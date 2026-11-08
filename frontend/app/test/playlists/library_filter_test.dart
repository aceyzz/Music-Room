import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/playlist/library_playlist.dart';

import '../home/fake_home_apis.dart';

void main() {
  final shared = libraryPlaylist('s', relation: PlaylistRelation.shared, owner: 'trinity');
  final friend = libraryPlaylist('f',
      relation: PlaylistRelation.friend, owner: 'morpheus', ownerIsFriend: true);
  test('the filter round-trips through the address; anything else is the Library', () {
    for (final filter in LibraryFilter.values) {
      expect(LibraryFilter.fromQuery(filter.queryValue), filter);
    }
    expect(LibraryFilter.library.queryValue, isNull);
    expect(LibraryFilter.fromQuery('mine'), LibraryFilter.library); // a link from before
    expect(LibraryFilter.fromQuery('nope'), LibraryFilter.library);
    expect(LibraryFilter.fromQuery(null), LibraryFilter.library);
  });

  test('the subtitle says editors and songs: whose it is, the star and the page say', () {
    expect(libraryPlaylist('a', editors: 1, songs: 1).subtitle, '1 editor · 1 song');
    expect(libraryPlaylist('a', editors: 3, songs: 24).subtitle, '3 editors · 24 songs');
    expect(shared.subtitle, friend.subtitle.replaceFirst('1 song', '0 songs'),
        reason: 'no "Shared by" or "morpheus\'s playlist" any more');
  });
}
