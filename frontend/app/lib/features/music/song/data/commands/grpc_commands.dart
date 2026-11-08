// import 'package:app/core/commands/categories/grpc_commands.dart';
// import 'package:app/gen/api.dart';

// // Conditionally imported alongside `web_commands.dart`.
// //
// // Contains native gRPC implementations loaded exclusively when running on non-web platforms
// // (e.g., iOS, Android, macOS).

// // =============================================================================
// // FETCH COMMANDS (Unary RPC)
// // =============================================================================

// /// Base command for fetching song information.
// abstract class SongCallCommand<Req, Res> extends RpcCallCommand<Req, Res, MusicServiceClient> {
//   /// Creates a [SongCallCommand] with the provided [request].
//   const SongCallCommand(super.request);
// }

// /// Asks the server for a single song.
// class GetSongCommand extends SongCallCommand<GetSongRequest, GetSongResponse> {
//   const GetSongCommand(super.request);

//   @override
//   Future<GetSongResponse> execute(client, request) => client.getSong(request);
// }

// /// Asks the server for a list of songs.
// class GetSongsCommand extends SongCallCommand<GetSongsRequest, GetSongsResponse> {
//   const GetSongsCommand(super.request);

//   @override
//   Future<GetSongsResponse> execute(client, request) => client.getSongs(request);
// }

// /// Asks the server for detailed information about a single song.
// class GetSongDetailCommand
//     extends SongCallCommand<GetSongDetailRequest, GetSongDetailResponse> {
//   const GetSongDetailCommand(super.request);

//   @override
//   Future<GetSongDetailResponse> execute(client, request) =>
//       client.getSongDetail(request);
// }

// // =============================================================================
// // WATCH COMMANDS
// // Listen for continuous updates sent by the server whenever data changes.
// // =============================================================================

// /// Base command for receiving live song updates from the server.
// abstract class SongWatchCommand<Req, Res> extends RpcWatchCommand<Req, Res, MusicServiceClient> {
//   const SongWatchCommand(super.request);
// }

// /// Listens for real-time song changes pushed from the server.
// class WatchSongsCommand extends SongWatchCommand<WatchSongsRequest, WatchSongsResponse> {
//   const WatchSongsCommand(super.request);

//   @override
//   Stream<WatchSongsResponse> execute(client, request) => client.watchSongs(request);
// }


// /// Listens for real-time song detail updates pushed from the server.
// class WatchSongDetailCommand extends SongWatchCommand<WatchSongDetailRequest,
//     WatchSongDetailResponse> {
//   const WatchSongDetailCommand(super.request);

//   @override
//   Stream<WatchSongDetailResponse> execute(client, request) =>
//       client.watchSongDetail(request);
// }

// // =============================================================================
// // SYNCHRONIZE COMMANDS
// // Maintain a two-way connection where both client and server exchange updates.
// // =============================================================================

// /// Base command for two-way synchronization between client and server.
// abstract class SongSyncCommand<Req, Res> extends RpcSyncCommand<Req, Res, MusicServiceClient> {
//   const SongSyncCommand(super.requestStream);
// }

// /// Keeps song data in sync by continuously sending and receiving updates.
// class SyncSongsCommand extends SongSyncCommand<SyncSongsRequest, SyncSongsResponse> {
//   const SyncSongsCommand(super.requestStream);

//   @override
//   Stream<SyncSongsResponse> execute(MusicServiceClient client, Stream<SyncSongsRequest> actions) =>
//       client.syncSongs(actions);
// }

// /// Keeps song detail and playback state in sync via bidirectional streaming.
// class SyncSongDetailCommand extends SongSyncCommand<SyncSongDetailRequest,
//     SyncSongDetailResponse> {
//   const SyncSongDetailCommand(super.requestStream);

//   @override
//   Stream<SyncSongDetailResponse> execute(
//     MusicServiceClient client,
//     Stream<SyncSongDetailRequest> actions,
//   ) =>
//       client.syncSongDetail(actions);
// }