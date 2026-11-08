import 'package:flutter/material.dart';

/// A playlist's cover, or a music note when there is none or it fails to
/// load. Fills its parent: size and round it there.
class PlaylistCover extends StatelessWidget {
  final String? url;
  final double iconSize;

  const PlaylistCover({super.key, required this.url, this.iconSize = 48});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: scheme.secondaryContainer,
      child: Center(
        child: Icon(Icons.music_note, size: iconSize, color: scheme.onSecondaryContainer),
      ),
    );
    final url = this.url;
    if (url == null) {
      return placeholder;
    }
    return Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => placeholder);
  }
}
