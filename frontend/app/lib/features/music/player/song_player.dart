import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/sources/live_stream.dart';

/// A playlist's songs as its live stream pushes them: the tracks in order,
/// and one key per track (the playlist entry's id).
typedef PlaylistSongs = ({List<EventTrack> tracks, List<int> keys});

/// Plays Deezer previews on this device, outside any event: a playlist from
/// the song tapped in it, in a loop. The mini player bar and its sheet show it
/// (song_player_sheet.dart).
///
/// One for the whole app (main.dart), so the music keeps playing while the
/// user moves between tabs. Local only: the server knows nothing about it,
/// unlike an event's playback (event_audio_output.dart). It only reads: the
/// playlist's live stream, so that others' edits reach what plays next.
class SongPlayer extends ChangeNotifier {
  final AudioPlayer _player = AudioPlayer();

  /// The song again, from Deezer through the backend (SongSearchApi.getSong),
  /// for a fresh preview link: a stored one is signed for 15 minutes, and the
  /// demo data stores none. Null in tests.
  final Future<EventTrack> Function(int deezerId)? _refetch;

  /// The songs of the playlist being played, the playable ones only.
  List<EventTrack> _queue = const [];

  /// [_queue]'s rows, one key each (the playlist entry's id), so [follow]
  /// finds them again after an edit, duplicates included.
  List<int> _keys = const [];

  /// [current]'s place in [_queue]; once [follow] removed it, the place just
  /// before the song that came after it, so [next] goes on with that one.
  int _index = 0;

  /// Which playlist [_queue] is, for [follow]; null when the caller said none.
  String? _source;

  /// That playlist's live stream, open while it plays, whatever page the user
  /// is on: edits reach the queue, and losing access stops the music.
  LiveStream<PlaylistSongs>? _live;

  final _lostAccess = StreamController<void>.broadcast();

  /// The music stopped because the user may no longer see its playlist (made
  /// private, deleted), maybe from another page: SongPlayerNotices says so.
  Stream<void> get lostAccess => _lostAccess.stream;

  /// The song loaded, playing or paused; null before the first one. Kept
  /// apart from [_queue]: removed from the playlist, it still plays to its end.
  EventTrack? _current;
  int? _currentKey;
  EventTrack? get current => _current;

  bool get playing => _player.playing;
  Duration get position => _player.position;
  Stream<Duration> get positionStream => _player.positionStream;

  /// The audio player's state, cancelled by [dispose]: it can still send
  /// after.
  late final StreamSubscription<PlayerState> _state;

  SongPlayer({Future<EventTrack> Function(int deezerId)? refetch}) : _refetch = refetch {
    _state = _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed && _player.playing) {
        // The preview ran out: on to the next song, the first one after the
        // last. Never a "finished" state, which media_kit on Linux makes
        // awkward (a completed song reports 0 and ignores seeks).
        next();
      }
      notifyListeners();
    });
  }

  /// Plays [tracks] from [index]. Songs that cannot play are skipped: no
  /// preview and no Deezer id to ask for one. With [source] (the playlist's
  /// id) and [keys] (one per track), [follow] keeps the queue up with edits;
  /// with [updates] too (the playlist's live stream), the player follows them
  /// itself until another playlist plays.
  Future<void> playAll(
    List<EventTrack> tracks,
    int index, {
    String? source,
    List<int>? keys,
    Stream<PlaylistSongs> Function()? updates,
  }) async {
    keys ??= [for (var i = 0; i < tracks.length; i++) i];
    final start = keys[index];
    _set(tracks, keys);
    _source = source;
    _live?.stop();
    _live = null;
    if (source != null && updates != null) {
      _live = LiveStream(
        updates,
        onState: (songs) => follow(source, songs.tracks, songs.keys),
        // A dropped connection keeps the queue as it is, and LiveStream opens
        // it again; NotFound means the user may no longer see the playlist.
        onError: (error) {
          if (error is NotFoundError && source == _source) {
            _lostAccess.add(null);
            drop(source);
          }
        },
      );
      unawaited(_live!.start());
    }
    final at = _keys.indexOf(start);
    if (at < 0) return;
    await _load(at);
  }

  /// The playlist [source] changed (someone added, removed or moved a song):
  /// the songs after the current one follow it. The current one plays on,
  /// even if it was removed. Ignored for any other playlist.
  void follow(String source, List<EventTrack> tracks, List<int> keys) {
    if (source != _source || _currentKey == null) return;
    final oldKeys = _keys;
    _set(tracks, keys);
    _index = followedIndex(oldKeys, _index, _currentKey!, _keys);
    notifyListeners();
  }

  /// The user may no longer see the playlist [source] (made private, or
  /// deleted): if it is the one playing, the music stops and the player
  /// empties, which hides the mini player bar. Ignored for any other playlist.
  Future<void> drop(String source) async {
    if (source != _source) return;
    _source = null;
    _live?.stop();
    _live = null;
    _queue = const [];
    _keys = const [];
    _current = null;
    _currentKey = null;
    notifyListeners();
    try {
      await _player.stop();
    } catch (error) {
      // Emptied all the same: nothing left to play.
      debugPrint('Song player: $error');
    }
  }

  /// The playable [tracks] and their [keys].
  void _set(List<EventTrack> tracks, List<int> keys) {
    final playable = [for (var i = 0; i < tracks.length; i++) if (canPlay(tracks[i])) i];
    _queue = [for (final i in playable) tracks[i]];
    _keys = [for (final i in playable) keys[i]];
  }

  Future<void> _load(int index) async {
    _index = index;
    _current = _queue[index];
    _currentKey = _keys[index];
    notifyListeners();
    try {
      // Asked for here, when the song is about to play, not when the
      // playlist was opened: by the time a long playlist gets to a song, the
      // link it was listed with may have expired.
      var track = _current!;
      final key = _currentKey;
      if (!previewUsable(track.previewUrl, DateTime.now()) && _refetch != null && track.deezerId != 0) {
        final fresh = (await _refetch(track.deezerId)).previewUrl;
        track = EventTrack(
          deezerId: track.deezerId,
          title: track.title,
          artist: track.artist,
          album: track.album,
          coverUrl: track.coverUrl,
          previewUrl: fresh,
          duration: track.duration,
        );
        // Another song was picked while this one was being asked for.
        if (_currentKey != key) return;
        // Where it is now: an edit may have moved it ([follow]).
        final at = _keys.indexOf(key!);
        if (at >= 0) _queue = [..._queue]..[at] = track;
        _current = track;
      }
      final url = track.previewUrl;
      if (url == null) return;
      await _player.setUrl(url);
      // play() completes when playback stops, not when it starts.
      _player.play();
    } catch (error) {
      // An expired Deezer URL or no network: the song shows, silent.
      debugPrint('Song player: $error');
    }
  }

  void toggle() => _player.playing ? _player.pause() : _player.play();

  /// The next song, the first one after the last.
  Future<void> next() async {
    if (_queue.isEmpty) return;
    await _load((_index + 1) % _queue.length);
  }

  /// Back to the start of the song, or to the previous one (the last one
  /// before the first) when already near the start, as most players do.
  Future<void> previous() async {
    if (_player.position < const Duration(seconds: 3) && _queue.isNotEmpty) {
      await _load(previousIndex(_keys, _index, _currentKey));
    } else {
      await seek(Duration.zero);
    }
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
    notifyListeners();
  }

  /// Stops this player, for when an event's speaker takes over.
  Future<void> pause() => _player.pause();

  @override
  void dispose() {
    _live?.stop();
    _state.cancel();
    _lostAccess.close();
    _player.dispose();
    super.dispose();
  }
}

/// Where the queue stands once the playlist changed from [oldKeys] to
/// [newKeys], the song [currentKey] playing at [index]: its new place, or if
/// it was removed, the place just before the first song that came after it
/// and is still there, so the next song is that one. -1 (the next song is the
/// first) when none of them is left.
int followedIndex(List<int> oldKeys, int index, int currentKey, List<int> newKeys) {
  final at = newKeys.indexOf(currentKey);
  if (at >= 0) return at;
  for (var step = 1; step <= oldKeys.length; step++) {
    final key = oldKeys[(index + step) % oldKeys.length];
    final there = key == currentKey ? -1 : newKeys.indexOf(key);
    if (there >= 0) return there - 1;
  }
  return -1;
}

/// The song before the one playing ([currentKey], at [index]), the last one
/// before the first. Once [followedIndex] removed the current song, [index]
/// is already the song before it: that one, not the one before again.
int previousIndex(List<int> keys, int index, int? currentKey) {
  final playingIsThere = index >= 0 && index < keys.length && keys[index] == currentKey;
  return ((playingIsThere ? index - 1 : index) + keys.length) % keys.length;
}

/// Whether [track] can be played: it has a preview link, or a Deezer id to
/// ask for one.
bool canPlay(EventTrack track) => track.previewUrl != null || track.deezerId != 0;

/// Whether [track] is the same song as [other], whatever their preview links
/// (they change: [SongPlayer] refreshes them).
bool sameSong(EventTrack? track, EventTrack other) => track != null &&
    (track.deezerId != 0 ? track.deezerId == other.deezerId : track == other);

/// A link with at least a minute left. Deezer signs a preview link for 15
/// minutes ("...hdnea=exp=1760000000~acl=..."); a link with no expiry in it
/// is taken as good. Same rule as the backend's (internal/event/preview.go).
bool previewUsable(String? url, DateTime now) {
  if (url == null || url.isEmpty) return false;
  final match = RegExp(r'exp=(\d+)').firstMatch(url);
  if (match == null) return true;
  final expiry = int.parse(match.group(1)!);
  return now.millisecondsSinceEpoch ~/ 1000 < expiry - 60;
}
