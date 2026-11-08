// import 'package:app/gen/api.dart';
// import 'package:app/core/models/models.dart';

// import 'song_event.mapping.dart';

// extension SongDTOMappingGRPC on SongDTO {
//   Song toDomain() => Song(
//         id: id,
//         title: title,
//         artist: artist,
//         duration: duration,
//         albumArtUrl: albumArtUrl,
//         isLiked: isLiked,
//       );
// }

// extension SongDTOMappingJSON on V1SongDTO {
//   Song toDomain() => Song(
//         id: id ?? '0',
//         title: title ?? 'Unknown Title',
//         artist: artist ?? 'Unknown Artist',
//         duration: duration ?? '0',
//         albumArtUrl: albumArtUrl ?? '',
//         isLiked: isLiked ?? false,
//       );
// }

// extension GetSongResponseMapper on GetSongResponse {
//   Future<List<Song>> toDomainList() async => [song.toDomain()];
// }

// extension GetSongsResponseMapper on GetSongsResponse {
//   Future<List<Song>> toDomainList() async => songs.map((dto) => dto.toDomain()).toList();
// }

// extension WatchSongsResponseMapper on WatchSongsResponse {
//   List<SongEvent> toDomainList() {
//     switch (whichEvent()) {
//       case WatchSongsResponse_Event.songAdded:
//         return [songAdded.toDomain()];
//       case WatchSongsResponse_Event.songDeleted:
//         return [songDeleted.toDomain()];
//       case WatchSongsResponse_Event.heartbeat:
//         return [heartbeat.toDomain()];
//       case WatchSongsResponse_Event.notSet:
//         return const [];
//     }
//   }
// }

// extension SyncSongsResponseMapper on SyncSongsResponse {
//   List<SongEvent> toDomainList() {
//     switch (whichEvent()) {
//       case SyncSongsResponse_Event.songAdded:
//         return [songAdded.toDomain()];
//       case SyncSongsResponse_Event.songDeleted:
//         return [songDeleted.toDomain()];
//       case SyncSongsResponse_Event.heartbeat:
//         return [heartbeat.toDomain()];
//       case SyncSongsResponse_Event.notSet:
//         return const [];
//     }
//   }
// }

// extension V1GetSongsResponseMapper on V1GetSongsResponse {
//   List<Song> toDomainList() => songs.map((dto) => dto.toDomain()).toList();
// }
