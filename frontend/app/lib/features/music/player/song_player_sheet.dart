import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/playlist_cover.dart';
import 'package:app/features/event/presentation/widgets/event_player.dart';
import 'package:app/features/music/player/song_player.dart';

/// The "now playing" bar at the bottom of the tabs and of a playlist: cover,
/// title, play / pause and a thin progress line. Nothing until a song has
/// been played. Tapping it opens the full player ([showSongPlayerSheet]).
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key});

  @override
  Widget build(BuildContext context) {
    final player = context.watch<SongPlayer>();
    final track = player.current;
    if (track == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () => showSongPlayerSheet(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (context, snapshot) {
                final length = track.duration.inMilliseconds;
                final at = (snapshot.data ?? Duration.zero).inMilliseconds;
                return LinearProgressIndicator(
                  value: length > 0 ? (at / length).clamp(0.0, 1.0) : 0,
                  minHeight: 2,
                );
              },
            ),
            ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox.square(dimension: 40, child: PlaylistCover(url: track.coverUrl, iconSize: 20)),
              ),
              title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                tooltip: player.playing ? 'Pause' : 'Play',
                onPressed: player.toggle,
                icon: Icon(player.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The full player over the current page: cover, seek bar, previous /
/// play-pause / next. Same widgets as the event player.
Future<void> showSongPlayerSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _SongPlayerView(),
    );

class _SongPlayerView extends StatelessWidget {
  const _SongPlayerView();

  @override
  Widget build(BuildContext context) {
    final player = context.watch<SongPlayer>();
    final track = player.current;
    if (track == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimens.spacingXL,
          0,
          AppDimens.spacingXL,
          AppDimens.spacingL,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppDimens.radiusL),
              child: SizedBox.square(dimension: 240, child: PlaylistCover(url: track.coverUrl)),
            ),
            const SizedBox(height: AppDimens.spacingL),
            Text(track.title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: AppDimens.spacingXXS),
            Text(track.artist, style: muted, textAlign: TextAlign.center),
            const SizedBox(height: AppDimens.spacingM),
            // The playhead as of now; the bar moves it on by itself while the
            // song plays.
            PlaybackProgress(
              playback: EventPlayback(
                track: track,
                isPaused: !player.playing,
                position: player.position,
                updatedAt: DateTime.now(),
              ),
              onSeek: player.seek,
            ),
            const SizedBox(height: AppDimens.spacingXS),
            PlaybackControls(
              isPlaying: player.playing,
              onPrevious: player.previous,
              onPlayPause: player.toggle,
              onNext: player.next,
            ),
          ],
        ),
      ),
    );
  }
}
