import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'package:app/core/models/event/event_playback.dart';

/// The speaker: makes the sound match what the server says the event is
/// playing.
///
/// It never decides anything. The server holds the playback state and every
/// button goes there; this only follows the result ([follow]), so the app that
/// plays and the apps that press buttons cannot disagree about what is on
/// (docs/todo.md §4, "one app plays the sound, every other app is a remote").
/// An interface so the live event store can be tested without a player.
abstract interface class AudioOutput {
  /// Plays [playback]'s track from its live position, or stops when nothing
  /// plays. Call it with every new state; it only acts on what changed.
  void follow(EventPlayback playback);

  void dispose();
}

/// The speaker for this platform: just_audio everywhere, through media_kit on
/// Linux (main.dart), which is the evaluation's phone (frontend/Dockerfile,
/// target phone).
AudioOutput platformAudioOutput({DateTime Function() now = DateTime.now}) => JustAudioOutput(now: now);

/// [AudioOutput] over just_audio, playing the Deezer preview URL.
class JustAudioOutput implements AudioOutput {
  final AudioPlayer _player = AudioPlayer();
  final DateTime Function() _now;

  /// The URL loaded in [_player], so the same song is not reloaded on every
  /// refresh.
  String? _url;

  /// [follow] calls run one after the other: loading a URL takes a moment,
  /// and a second state arriving meanwhile must apply after it, not race it.
  Future<void> _pending = Future.value();

  /// How far the local playhead may wander from the server's before it is
  /// pulled back. Re-seeking on every refresh would stutter; the server's
  /// `updated_at` is only accurate to the second anyway.
  static const _maxDrift = Duration(milliseconds: 1500);

  JustAudioOutput({DateTime Function() now = DateTime.now}) : _now = now;

  @override
  void follow(EventPlayback playback) {
    _pending = _pending.then((_) => _apply(playback)).catchError((Object error) {
      // A preview that fails to load (an expired Deezer URL, no network)
      // leaves the room silent, not the screen broken: the controls still
      // drive the server.
      debugPrint('Event audio: $error');
    });
  }

  Future<void> _apply(EventPlayback playback) async {
    final url = playback.track?.previewUrl;
    if (url == null) {
      _url = null;
      await _player.stop();
      return;
    }
    if (url != _url) {
      _url = url;
      await _player.setUrl(url);
    }
    // After the load: the song kept moving while it buffered.
    final target = playback.positionAt(_now());
    if ((_player.position - target).abs() > _maxDrift) {
      await _player.seek(target);
    }
    if (playback.isPaused) {
      await _player.pause();
    } else if (!_player.playing) {
      // play() completes when playback stops, not when it starts.
      unawaited(_player.play());
    }
  }

  @override
  void dispose() {
    _player.dispose();
  }
}
