// import 'package:app/core/models/song/song_detail.dart';
// import 'package:app/core/models/song/song_detail_event.dart';
// import 'package:app/gen/music_room/v1/contracts.pbgrpc.dart';
// import 'package:app/core/mapping/mappers.dart';

// // =============================================================================
// // PROTOBUF DTO TO DOMAIN MODEL MAPPERS
// // =============================================================================

// extension PlaybackStateDTOMapper on PlaybackStateDTO {
//   /// Maps [PlaybackStateDTO] to the [PlaybackState] domain model.
//   PlaybackState toDomain() {
//     return PlaybackState(
//       isPlaying: playing,
//       currentPositionMs: currentPositionMs,
//       updatedAtTimestampMs: updatedAtTimestamp
//     );
//   }
// }

// extension SongDetailDTOMapper on SongDetailDTO {
//   /// Maps [SongDetailDTO] to the [SongDetail] domain model.
//   SongDetail toDomain() {
//     return SongDetail(
//       song: song.toDomain(),
//       playbackState: playbackState.toDomain(),
//     );
//   }
// }

// // =============================================================================
// // RESPONSE TO DOMAIN EVENT MAPPERS
// // =============================================================================

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
//         final startMs = playSong.hasStartPositionMs()
//             ? playSong.startPositionMs.toInt()
//             : 0;
//         return [
//           PlaybackStateUpdated(
//             PlaybackState(
//               isPlaying: true,
//               position: Duration(milliseconds: startMs),
//               updatedAt: DateTime.now().toUtc(),
//             ),
//           ),
//         ];
//       case SyncSongDetailResponse_Action.updateProgress:
//         return [
//           PlaybackStateUpdated(
//             PlaybackState(
//               isPlaying: true,
//               position: Duration(
//                 milliseconds: updateProgress.positionMs.toInt(),
//               ),
//               updatedAt: DateTime.now().toUtc(),
//             ),
//           ),
//         ];
//       case SyncSongDetailResponse_Action.notSet:
//         return const [];
//     }
//   }
// }