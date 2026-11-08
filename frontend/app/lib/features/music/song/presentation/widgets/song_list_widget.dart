// import 'package:app/core/auto_rebuild/auto_rebuild_widgets.dart';
// import 'package:app/core/models/song/song.dart';
// import 'package:app/core/theme/app_dimens.dart';
// import 'package:app/features/music/song/presentation/stores/song_list_store.dart';
// import 'package:flutter/material.dart';

// class SongListWidget extends AutoRebuildOnAny {
//   final SongListStore store;
//   final ValueChanged<Song>? onSongTap;

//   const SongListWidget({
//     super.key,
//     required this.store,
//     this.onSongTap,
//   });

//   @override
//   List<Listenable> listenables(BuildContext context) => [
//         store.songs,
//         store.selection.selectedId,
//       ];

//   @override
//   Widget buildWidget(BuildContext context) {
//     final state = store.songs.value;
//     final List<Song>? songs = state.data;
//     final selectedSongId = store.selection.selectedId;

//     if (state.isLoading && (songs == null || songs.isEmpty)) {
//       return const Center(
//         child: CircularProgressIndicator(),
//       );
//     }

//     if (state.hasError && (songs == null || songs.isEmpty)) {
//       return Center(
//         child: Text(
//           'Error: ${state.error?.message ?? 'Failed to load songs'}',
//         ),
//       );
//     }

//     if (songs == null || songs.isEmpty) {
//       return const Center(
//         child: Text('No songs available'),
//       );
//     }

//     final colorScheme = Theme.of(context).colorScheme;

//     return ListView.builder(
//       itemCount: songs.length,
//       itemBuilder: (context, index) {
//         final song = songs[index];
//         final isSelected = song.id == selectedSongId;

//         return ListTile(
//           selected: isSelected,
//           selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
//           contentPadding: const EdgeInsets.symmetric(
//             horizontal: AppDimens.spacingM,
//             vertical: AppDimens.spacingXXS,
//           ),
//           leading: ClipRRect(
//             borderRadius: BorderRadius.circular(AppDimens.radiusS),
//             child: Image.network(
//               song.albumArtUrl,
//               width: 48,
//               height: 48,
//               fit: BoxFit.cover,
//               errorBuilder: (context, error, stackTrace) => Container(
//                 width: 48,
//                 height: 48,
//                 color: colorScheme.surfaceContainerHighest,
//                 child: Icon(
//                   Icons.music_note_rounded,
//                   color: colorScheme.onSurfaceVariant,
//                 ),
//               ),
//             ),
//           ),
//           title: Text(
//             song.title,
//             maxLines: 1,
//             overflow: TextOverflow.ellipsis,
//             style: TextStyle(
//               fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
//               color: isSelected ? colorScheme.primary : colorScheme.onSurface,
//             ),
//           ),
//           subtitle: Text(
//             song.artist,
//             maxLines: 1,
//             overflow: TextOverflow.ellipsis,
//             style: TextStyle(
//               color: colorScheme.onSurfaceVariant,
//             ),
//           ),
//           trailing: isSelected
//               ? Icon(
//                   Icons.graphic_eq_rounded,
//                   color: colorScheme.primary,
//                 )
//               : null,
//           onTap: () {
//             store.selection.select(song.id);
//             onSongTap?.call(song);
//           },
//         );
//       },
//     );
//   }
// }