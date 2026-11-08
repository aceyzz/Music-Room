// import 'package:app/core/models/song/song_detail.dart';
// import 'package:flutter/material.dart';

// import 'dart:async';

// import 'package:fixnum/fixnum.dart';

// import 'package:app/gen/api.dart';
// import 'package:app/core/sources/source_state.dart';
// import 'package:app/core/controllers/repository_controller.dart';
// import 'package:app/core/models/song/song.dart';
// import 'package:app/features/music/song/data/song_repository.dart';

// /// Manages state and stream subscriptions for the Song Detail feature.
// ///
// /// Orchestrates data streaming via [_repository] and selection tracking via [selection].
// class SongDetailStore {
//   /// Internal repository controller used to obtain and watch [SongRepository].
//   late final RepositoryController<SongRepository> _repository;

//   /// Reactive state container holding the current [ListState] of [Song] items.
//   final ValueNotifier<ItemState<SongDetail>> songDetailGet =
//       ValueNotifier(ItemState.initial());

//   /// Reactive state container holding the current [ListState] of [Song] items.
//   final ValueNotifier<ItemState<SongDetail>> songDetailWatch =
//       ValueNotifier(ItemState.initial());

//   /// Reactive state container holding the current [ListState] of [Song] items.
//   final ValueNotifier<ItemState<SongDetail>> songDetailSync =
//       ValueNotifier(ItemState.initial());

//   /// Outgoing stream controller to send local user actions to the bidirectional sync session.
//   final StreamController<SyncSongDetailRequest> _syncActionsController =
//       StreamController<SyncSongDetailRequest>.broadcast();

//   /// Creates a [SongDetailStore] with injected dependencies.
//   SongDetailStore({required RepositoryController<SongRepository> repository})
//       : _repository = repository;

//   /// Initializes the store and starts listening to the song stream.
//   ///
//   /// Call this when the feature is mounted or navigated to.
//   Future<void> start() async {
//     await _repository.initialize((controller) async {
//     // 1. One-off fetch (Convert Future to Stream for bindWithState)
//       controller.bindWithState<SongDetail, ItemState<SongDetail>>(
//         stream: Stream.fromFuture(
//           controller.repository.getSongDetail('0'),
//         ),
//         notifier: songDetailGet,
//         onSuccess: (data) => ItemState.success(data),
//         onLoading: (current) => ItemState.loading(current),
//         onError: (error, current) => ItemState.error(error, current),
//         key: 'get_song_detail',
//       );

//       // 2. Real-time watch stream
//       controller.bindWithState<SongDetail, ItemState<SongDetail>>(
//         stream: controller.repository.watchSongDetail('0'),
//         notifier: songDetailWatch,
//         onSuccess: (data) => ItemState.success(data),
//         onLoading: (current) => ItemState.loading(current),
//         onError: (error, current) => ItemState.error(error, current),
//         key: 'watch_song_detail',
//       );

//       // 3. Bidirectional sync stream
//       controller.bindWithState<SongDetail, ItemState<SongDetail>>(
//         stream: controller.repository.syncSongDetail(
//           '0',
//           _syncActionsController.stream,
//         ),
//         notifier: songDetailSync,
//         onSuccess: (data) => ItemState.success(data),
//         onLoading: (current) => ItemState.loading(current),
//         onError: (error, current) => ItemState.error(error, current),
//         key: 'sync_song_detail',
//       );
//     });
//   }

// /// Sends a play action request over the active synchronization session.
//   void playSong({int? startPositionMs}) {
//     final action = PlaySongActionDTO();
//     if (startPositionMs != null) {
//       action.startPositionMs = Int64(startPositionMs);
//     }

//     _syncActionsController.add(
//       SyncSongDetailRequest(playSong: action),
//     );
//   }

//   /// Sends a progress update action request over the active synchronization session.
//   void updateProgress(int positionMs) {
//     _syncActionsController.add(
//       SyncSongDetailRequest(
//         updateProgress: UpdateProgressDTO(
//           positionMs: Int64(positionMs),
//         ),
//       ),
//     );
//   }

//   /// Disposes repository subscriptions and internal stream controllers.
//   void stop() {
//     _syncActionsController.close();
//     _repository.dispose();
//   }
// }
