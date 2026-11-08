import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/playlist_cover.dart';

/// Formats a track duration into mm:ss format (e.g., "3:45", "0:30").
String formatTrackDuration(Duration duration) {
  final seconds = duration.inSeconds;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// A standard list tile displaying a music track with its cover art, title,
/// artist, optional duration, and trailing actions or indicators.
class TrackTile extends StatelessWidget {
  final String title;
  final String? artist;
  final String? coverUrl;
  final Duration? duration;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;
  final double coverSize;
  final BorderRadiusGeometry borderRadius;
  final EdgeInsetsGeometry? contentPadding;

  const TrackTile({
    super.key,
    required this.title,
    this.artist,
    this.coverUrl,
    this.duration,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.selected = false,
    this.coverSize = AppDimens.trackCoverSize,
    this.borderRadius = const BorderRadius.all(Radius.circular(AppDimens.radiusS)),
    this.contentPadding,
  });

  @override
  Widget build(BuildContext context) {
    Widget? subtitleWidget = subtitle;
    if (subtitleWidget == null && artist != null) {
      final duration = this.duration;
      final text = duration == null
          ? artist!
          : '$artist · ${formatTrackDuration(duration)}';
      subtitleWidget = Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
    }

    return ListTile(
      contentPadding: contentPadding,
      selected: selected,
      onTap: onTap,
      leading: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox.square(
          dimension: coverSize,
          child: PlaylistCover(url: coverUrl, iconSize: coverSize / 2),
        ),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitleWidget,
      trailing: trailing,
    );
  }
}
