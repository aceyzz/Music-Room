import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/core/widgets/entity_badges.dart';
import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/globals/app_router.dart';

/// The Home "Your playlists" row: square covers, scrolling sideways. Which
/// playlists and in what order is PlaylistApi.recentPlaylists' call. Opens a
/// playlist, and calls [onReturn] once the user is back from it: it may have
/// changed there, or gone (made private, deleted).
class RecentPlaylists extends StatelessWidget {
  final List<PlaylistSummary> playlists;
  final VoidCallback? onReturn;

  static const height = 196.0;
  static const _cover = 140.0;

  const RecentPlaylists({super.key, required this.playlists, this.onReturn});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: playlists.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) => _PlaylistCard(playlist: playlists[i], onReturn: onReturn),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final PlaylistSummary playlist;
  final VoidCallback? onReturn;

  const _PlaylistCard({required this.playlist, this.onReturn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final songs = playlist.songCount == 1 ? '1 song' : '${playlist.songCount} songs';
    return Semantics(
      button: true,
      // The card reads as one button: the star is said in its label.
      label: [
        playlist.name,
        if (playlist.viewerIsOwner) 'yours',
        if (playlist.isPrivate) 'private',
      ].join(', '),
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await context.push(playlistPath(playlist.publicId));
          onReturn?.call();
        },
        child: SizedBox(
          width: RecentPlaylists._cover,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox.square(
                  dimension: RecentPlaylists._cover,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PlaylistCover(url: playlist.coverUrl),
                      // Yours and private, as on the events: a star and a
                      // lock, on a dark pill to read on any cover.
                      if (playlist.viewerIsOwner || playlist.isPrivate)
                        Positioned(
                          top: 8,
                          right: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: EntityBadges.fromFlags(
                                isOwner: playlist.viewerIsOwner,
                                isPrivate: playlist.isPrivate,
                                color: Colors.white,
                                iconSize: 18,
                              )!,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              Text(
                songs,
                style:
                    theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
