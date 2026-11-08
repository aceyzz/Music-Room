import 'package:fixnum/fixnum.dart';
import 'song.dart';



class PlaybackState{
  final bool isPlaying;
  final Int64 currentPositionMs;
  final Int64 updatedAtTimestampMs;

  const PlaybackState({
    required this.isPlaying,
    required this.currentPositionMs,
    required this.updatedAtTimestampMs,
  });

  PlaybackState copyWith({
    bool? isPlaying,
    Int64? currentPositionMs,
    Int64? updatedAtTimestampMs,
  }) {
    return PlaybackState(
      isPlaying: isPlaying ?? this.isPlaying,
      currentPositionMs: currentPositionMs ?? this.currentPositionMs,
      updatedAtTimestampMs: updatedAtTimestampMs ?? this.updatedAtTimestampMs,
    );
  }
}

class SongDetail {
  final Song song;
  final PlaybackState playBackState;

  const SongDetail({
    required this.song,
    required this.playBackState
  });

  SongDetail copyWith({
    Song? song,
    PlaybackState? playBackState
  }) {
    return SongDetail(
      song: song ?? this.song,
      playBackState: playBackState ?? this.playBackState
    );
  }
}