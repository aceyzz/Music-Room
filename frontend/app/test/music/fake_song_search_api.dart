import 'dart:async';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/features/music/song/data/song_search_source.dart';

/// A Deezer search result: a 30-second song called [title], with the Deezer
/// id [deezerId].
EventTrack found(int deezerId, String title, {String? artist}) => EventTrack(
      deezerId: deezerId,
      title: title,
      artist: artist ?? 'Artist of $title',
      duration: const Duration(seconds: 30),
    );

/// In-memory [SongSearchApi]: every song of [catalogue] whose title or artist
/// contains the query, ignoring case. Records the queries; throws [failure]
/// while it is set. While [hold] is set, an answer waits for it.
class FakeSongSearchApi implements SongSearchApi {
  List<EventTrack> catalogue = const [];
  AppError? failure;
  Completer<void>? hold;
  final List<String> searches = [];

  @override
  Future<EventTrack> getSong(int deezerId) async =>
      catalogue.firstWhere((song) => song.deezerId == deezerId);

  @override
  Future<List<EventTrack>> searchSongs(String query) async {
    searches.add(query);
    final asked = query.toLowerCase();
    final answer = [
      for (final song in catalogue)
        if (song.title.toLowerCase().contains(asked) || song.artist.toLowerCase().contains(asked))
          song,
    ];
    await hold?.future;
    if (failure != null) {
      throw failure!;
    }
    return answer;
  }
}
