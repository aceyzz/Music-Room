import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app/core/widgets/snack.dart';
import 'package:app/features/music/player/song_player.dart';

/// What the user reads once a playlist they were on, or listening to, is no
/// longer theirs to see. One text for the playlist page and for the player,
/// so when both say it at once it shows once (showSnack).
const lostPlaylistMessage = "You can't see this playlist any more.";

/// Says why the music stopped when the player stopped it itself
/// ([SongPlayer.lostAccess]): the playlist went private or was deleted while
/// the user was on another page, and the mini player just went away.
///
/// Above every page (MaterialApp's builder), so it speaks wherever the user is.
class SongPlayerNotices extends StatefulWidget {
  final Widget child;

  const SongPlayerNotices({super.key, required this.child});

  @override
  State<SongPlayerNotices> createState() => _SongPlayerNoticesState();
}

class _SongPlayerNoticesState extends State<SongPlayerNotices> {
  late final StreamSubscription<void> _lostAccess;

  @override
  void initState() {
    super.initState();
    _lostAccess = context.read<SongPlayer>().lostAccess.listen((_) {
      if (mounted) showSnack(context, lostPlaylistMessage);
    });
  }

  @override
  void dispose() {
    _lostAccess.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
