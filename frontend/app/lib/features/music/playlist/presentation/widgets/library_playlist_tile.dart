import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/widgets/entity_badges.dart';
import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/globals/app_router.dart';

/// One row of the Playlists tab: the cover, the name, and how the user
/// relates to it with its editor and song counts; a star marks one the user
/// owns and a lock a private one, as on the events list. Opens the playlist, and calls [onReturn] once
/// the user is back from it: its songs and cover may have changed there.
class LibraryPlaylistTile extends StatelessWidget {
  final LibraryPlaylist playlist;
  final VoidCallback? onReturn;

  static const coverSize = 56.0;

  const LibraryPlaylistTile({super.key, required this.playlist, this.onReturn});

  @override
  Widget build(BuildContext context) {
    final mine = playlist.relation == PlaylistRelation.mine;
    final private = playlist.visibility == PlaylistVisibility.private;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox.square(
          dimension: coverSize,
          child: PlaylistCover(url: playlist.coverUrl, iconSize: 24),
        ),
      ),
      title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(playlist.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: EntityBadges.fromFlags(
        isOwner: mine,
        ownerSemanticLabel: 'You own it',
        isPrivate: private,
      ),
      onTap: () async {
        await context.push(playlistPath(playlist.publicId));
        onReturn?.call();
      },
    );
  }
}
