// import 'package:app/core/network/http.dart';
// import 'package:fixnum/fixnum.dart';

// import 'package:app/gen/api.dart';
// import 'package:app/core/models/models.dart';

// extension PlaybackStateDTOMappingGRPC on PlaybackStateDTO {
//   PlaybackState toDomain() => PlaybackState(
//         isPlaying: playing,
//         currentPositionMs: currentPositionMs,
//         updatedAtTimestampMs: updatedAtTimestamp,
//       );
// }

// extension PlaybackStateDTOMappingJSON on V1PlaybackStateDTO {
//   PlaybackState toDomain() => PlaybackState(
//         isPlaying: playing.orFalse,
//         currentPositionMs: Int64.tryParseInt(currentPositionMs.or('0')) ?? Int64(0),
//         updatedAtTimestampMs: Int64.tryParseInt(updatedAtTimestamp.or('0')) ?? Int64(0),
//       );
// }

// extension SongDetailDTOMappingGRPC on SongDetailDTO {
//   SongDetail toDomain() => SongDetail(
//         song: Song(
//           id: song.id,
//           title: song.title,
//           artist: song.artist,
//           duration: song.duration,
//           albumArtUrl:  song.albumArtUrl,
//           isLiked: song.isLiked,
//         ),
//         playBackState: PlaybackState(
//           isPlaying: playbackState.playing,
//           currentPositionMs: playbackState.currentPositionMs,
//           updatedAtTimestampMs: playbackState.updatedAtTimestamp,
//         ),
//       );
// }

// extension SongDetailDTOMappingJSON on V1SongDetailDTO {
//   SongDetail toDomain() => SongDetail(
//         song: Song(
//           id: song?.id.or('0') ?? '0',
//           title: song?.title.or('Unknown Title') ?? 'Unknown Title',
//           artist: song?.artist.or('Unknown Artist') ?? 'Unknown Artist',
//           duration: song?.duration.or('0') ?? '0',
//           albumArtUrl: song?.albumArtUrl.or('') ?? '',
//           isLiked: song?.isLiked.orFalse ?? false,
//         ),
//         playBackState: PlaybackState(
//           isPlaying: playbackState?.playing.orFalse ?? false,
//           currentPositionMs:
//               Int64.tryParseInt(playbackState?.currentPositionMs.or('0') ?? '0') ?? Int64(0),
//           updatedAtTimestampMs:
//               Int64.tryParseInt(playbackState?.updatedAtTimestamp.or('0') ?? '0') ?? Int64(0),
//         ),
//       );
// }

// extension GetSongDetailResponseMapper on GetSongDetailResponse {
//   Future<List<SongDetail>> toDomainList() async => [songDetail.toDomain()];
// }

// extension WatchSongDetailResponseMapper on WatchSongDetailResponse {
//   /// Maps [WatchSongDetailResponse] stream payloads into domain [SongDetailEvent] items.
//   List<SongDetailEvent> toDomainList() {
//     switch (whichUpdate()) {
//       case WatchSongDetailResponse_Update.songDetail:
//         return [SongDetailRefreshed(songDetail.toDomain())];
//       case WatchSongDetailResponse_Update.playbackState:
//         return [PlaybackStateUpdated(playbackState.toDomain())];
//       case WatchSongDetailResponse_Update.notSet:
//         return const [];
//     }
//   }
// }

// extension SyncSongDetailResponseMapper on SyncSongDetailResponse {
//   /// Maps [SyncSongDetailResponse] stream payloads into domain [SongDetailEvent] items.
//   List<SongDetailEvent> toDomainList() {
//     switch (whichAction()) {
//       case SyncSongDetailResponse_Action.playSong:
//         final startMs = playSong.hasStartPositionMs() ? playSong.startPositionMs.toInt() : 0;
//         return [
//           PlaybackStateUpdated(
//             // PlaybackState.copyWith(isPlaying: true);
//             PlaybackState(
//               isPlaying: true,
//               currentPositionMs: Int64(startMs),
//               updatedAtTimestampMs: Int64(0), // to change later
//             ),
//           ),
//         ];
//       case SyncSongDetailResponse_Action.updateProgress:
//         return [
//           PlaybackStateUpdated(
//             PlaybackState(
//               isPlaying: true,
//               currentPositionMs: updateProgress.positionMs,
//               updatedAtTimestampMs: Int64(0), // to change later
//             ),
//           ),
//         ];
//       case SyncSongDetailResponse_Action.notSet:
//         return const [];
//     }
//   }
// }
