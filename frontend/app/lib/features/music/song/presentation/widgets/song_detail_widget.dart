// import 'package:app/core/auto_rebuild/auto_rebuild_widgets.dart';
// import 'package:app/core/models/song/song_detail.dart';
// import 'package:app/core/theme/app_dimens.dart';
// import 'package:flutter/material.dart';
// import '../stores/song_detail_store.dart';

// class SongDetailWidget extends AutoRebuildOnAny {
//   final SongDetailStore store;
//   final VoidCallback? onPlayToggle;
//   final VoidCallback? onLikeToggle;

//   const SongDetailWidget({
//     super.key,
//     required this.store,
//     this.onPlayToggle,
//     this.onLikeToggle,
//   });

//   @override
//   List<Listenable> listenables(BuildContext context) => [
//         store.songDetailGet,
//         store.songDetailWatch,
//         store.songDetailSync,
//       ];

//   @override
//   Widget buildWidget(BuildContext context) {
//     // Prefer real-time streams (sync/watch) over one-off fetch state
//     final itemState = store.songDetailSync.value.data != null
//         ? store.songDetailSync.value
//         : (store.songDetailWatch.value.data != null
//             ? store.songDetailWatch.value
//             : store.songDetailGet.value);

//     final SongDetail? detail = itemState.data;

//     if (itemState.isLoading && detail == null) {
//       return const Center(
//         child: CircularProgressIndicator(),
//       );
//     }

//     if (itemState.hasError && detail == null) {
//       return Center(
//         child: Text('Error: ${itemState.error?.message ?? 'Failed to load details'}'),
//       );
//     }

//     if (detail == null) {
//       return const Center(
//         child: Text('No song detail available'),
//       );
//     }

//     final song = detail.song;
//     final playbackState = detail.playBackState;
//     final theme = Theme.of(context);
//     final colorScheme = theme.colorScheme;

//     return Padding(
//       padding: const EdgeInsets.all(AppDimens.spacingL),
//       child: Column(
//         mainAxisAlignment: MainAxisAlignment.center,
//         children: [
//           // Album Art
//           Container(
//             width: 260,
//             height: 260,
//             decoration: BoxDecoration(
//               borderRadius: BorderRadius.circular(AppDimens.radiusXL),
//               boxShadow: [
//                 BoxShadow(
//                   color: colorScheme.shadow.withValues(alpha: 0.2),
//                   blurRadius: AppDimens.spacingL,
//                   offset: const Offset(0, 8),
//                 ),
//               ],
//             ),
//             child: ClipRRect(
//               borderRadius: BorderRadius.circular(AppDimens.radiusXL),
//               child: Image.network(
//                 song.albumArtUrl,
//                 fit: BoxFit.cover,
//                 errorBuilder: (context, error, stackTrace) => Container(
//                   color: colorScheme.surfaceContainerHighest,
//                   child: Icon(
//                     Icons.music_note_rounded,
//                     size: AppDimens.iconXL * 2,
//                     color: colorScheme.onSurfaceVariant,
//                   ),
//                 ),
//               ),
//             ),
//           ),
//           const SizedBox(height: AppDimens.spacingXL),

//           // Title & Artist Header
//           Row(
//             mainAxisAlignment: MainAxisAlignment.spaceBetween,
//             children: [
//               Expanded(
//                 child: Column(
//                   crossAxisAlignment: CrossAxisAlignment.start,
//                   children: [
//                     Text(
//                       song.title,
//                       style: theme.textTheme.headlineSmall?.copyWith(
//                         fontWeight: FontWeight.bold,
//                       ),
//                       maxLines: 1,
//                       overflow: TextOverflow.ellipsis,
//                     ),
//                     const SizedBox(height: AppDimens.spacingXXS),
//                     Text(
//                       song.artist,
//                       style: theme.textTheme.titleMedium?.copyWith(
//                         color: colorScheme.onSurfaceVariant,
//                       ),
//                       maxLines: 1,
//                       overflow: TextOverflow.ellipsis,
//                     ),
//                   ],
//                 ),
//               ),
//               IconButton(
//                 icon: Icon(
//                   song.isLiked
//                       ? Icons.favorite_rounded
//                       : Icons.favorite_border_rounded,
//                   color: song.isLiked
//                       ? Colors.red
//                       : colorScheme.onSurfaceVariant,
//                   size: AppDimens.iconL,
//                 ),
//                 onPressed: onLikeToggle,
//               ),
//             ],
//           ),
//           const SizedBox(height: AppDimens.spacingL),

//           // Player Controls
//           Row(
//             mainAxisAlignment: MainAxisAlignment.spaceEvenly,
//             children: [
//               IconButton(
//                 icon: const Icon(Icons.skip_previous_rounded),
//                 iconSize: AppDimens.iconL,
//                 onPressed: () {},
//               ),
//               IconButton.filled(
//                 icon: Icon(
//                   playbackState.isPlaying
//                       ? Icons.pause_rounded
//                       : Icons.play_arrow_rounded,
//                 ),
//                 iconSize: AppDimens.iconXL,
//                 onPressed: onPlayToggle,
//               ),
//               IconButton(
//                 icon: const Icon(Icons.skip_next_rounded),
//                 iconSize: AppDimens.iconL,
//                 onPressed: () {},
//               ),
//             ],
//           ),
//         ],
//       ),
//     );
//   }
// }