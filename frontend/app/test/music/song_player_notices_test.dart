import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/features/music/player/song_player.dart';
import 'package:app/features/music/player/song_player_notices.dart';

void main() {
  testWidgets('a playlist that goes private while the user is elsewhere: the music stops, and says why',
      (tester) async {
    // No audio plugin under `flutter test`: its channel answers empty maps,
    // and the songs stay silent.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.just_audio.methods'), (_) async => <String, dynamic>{});
    const song = EventTrack(title: 'a', artist: 'x', duration: Duration(seconds: 30), deezerId: 1, previewUrl: 'u1');
    final live = StreamController<PlaylistSongs>.broadcast();
    final player = SongPlayer();
    await tester.pumpWidget(ChangeNotifierProvider<SongPlayer>.value(
      value: player,
      child: MaterialApp(
        builder: (context, page) => SongPlayerNotices(child: page!),
        home: const Scaffold(body: Text('Home')),
      ),
    ));
    await tester.runAsync(
        () => player.playAll([song], 0, source: 'p1', keys: [10], updates: () => live.stream));
    expect(player.current, song);

    // In real time too: the player listens from runAsync's zone.
    await tester.runAsync(() async {
      live.addError(const NotFoundError('playlist not found'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pumpAndSettle();

    expect(player.current, isNull);
    expect(find.text(lostPlaylistMessage), findsOneWidget);
  });
}
