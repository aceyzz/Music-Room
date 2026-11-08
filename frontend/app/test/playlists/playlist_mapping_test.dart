import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/mapping/playlist.mapping.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/gen/music_room/v1/dto/playlist.pb.dart';
import 'package:app/gen/music_room/v1/dto/song.pb.dart';

void main() {
  String media(String key) => 'http://media.test/$key';

  test('a playlist DTO becomes a summary, its cover served from the media URL', () {
    final dto = PlaylistDTO(
      publicId: 'p-1',
      name: 'Road trip',
      songCount: 12,
      coverStorageKey: 'covers/p-1.png',
    );

    final summary = dto.toSummary(mediaUrl: media);
    expect(summary.publicId, 'p-1');
    expect(summary.name, 'Road trip');
    expect(summary.songCount, 12);
    expect(summary.coverUrl, 'http://media.test/covers/p-1.png');
  });

  test('no cover key means no cover', () {
    expect(PlaylistDTO(publicId: 'p-1', name: 'x').toSummary(mediaUrl: media).coverUrl, isNull);
  });

  test("a playlist DTO becomes the page's header, with its settings and revision", () {
    final details = PlaylistDTO(
      publicId: 'p-1',
      name: 'Road trip',
      visibility: 'private',
      editLicense: 'invited_only',
      songCount: 2,
      totalDurationSeconds: 61,
      revision: Int64(7),
    ).toDetails(mediaUrl: media);

    expect(details.visibility, PlaylistVisibility.private);
    expect(details.editLicense, EditLicense.invitedOnly);
    expect(details.totalDuration, const Duration(seconds: 61));
    expect(details.revision, 7);
    expect(details.coverUrl, isNull);
  });

  test('a playlist row keeps its own id and its Deezer song', () {
    final entry = PlaylistSongDTO(
      id: Int64(31),
      song: SongDTO(deezerSongId: Int64(3135556), title: 'Harder', artistName: 'Daft Punk'),
    ).toEntry();

    expect(entry.id, 31);
    expect(entry.track.deezerId, 3135556);
    expect(entry.track.title, 'Harder');
  });
}
