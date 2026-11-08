// import 'dart:async';

// import 'package:app/core/controllers/repository_controller.dart';
// import 'package:app/features/music/song/data/song_repository.dart';
// import 'package:app/core/sources/source_state.dart';

// import 'package:flutter/material.dart';

// import 'package:app/core/controllers/selection_controllers.dart';
// import 'package:app/core/models/song/song.dart';



// /// Manages state and stream subscriptions for the Song Detail feature.
// ///
// /// Orchestrates data streaming via [_repository] and selection tracking via [selection].
// class SongListStore {
//   /// Controller managing item selection state by ID.
//   late final SelectionController<String, Song> selection;

//   /// Internal repository controller used to obtain and watch [SongRepository].
//   late final RepositoryController<SongRepository> _repository;

//   /// Reactive state container holding the current [ListState] of [Song] items.
//   final ValueNotifier<ListState<Song>> songs =
//       ValueNotifier(ListState.initial());

//   /// Creates a [SongDetailStore] with injected dependencies.
//   SongListStore({
//     required this.selection,
//     required RepositoryController<SongRepository> repository,
//   }) : _repository = repository;

//   /// Resolves and returns the currently selected [Song] instance, or `null` if none is selected.
//   Song? get selectedSong {
//     return selection.resolveSelectedItem(songs.value.data, (song) => song.id);
//   }

//   /// Initializes the store and starts listening to the song stream.
//   ///
//   /// Call this when the feature is mounted or navigated to.
//   Future<void> start() async {
//     await _repository.initialize((controller) async {
//       // Start listening to the song stream
//       controller.bindWithState<List<Song>, ListState<Song>>(
//         stream: controller.repository.watchAllSongs(),
//         notifier: songs,
//         onSuccess: ListState.success,
//         onLoading: ListState.loading,
//         onError: ListState.error,
//         key: 'songs_stream',
//       );
//     });
//   }

//   void stop() {
//     _repository.dispose();
//     selection.dispose();
//   }
// }

