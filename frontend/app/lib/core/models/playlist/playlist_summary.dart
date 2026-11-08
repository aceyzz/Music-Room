import 'package:flutter/foundation.dart';

/// A playlist as a list shows it.
@immutable
class PlaylistSummary {
  final String publicId;
  final String name;
  final String? coverUrl;
  final int songCount;

  /// Whether the signed-in user owns it: Home marks it with a star.
  final bool viewerIsOwner;

  /// Private: Home marks it with a lock.
  final bool isPrivate;

  const PlaylistSummary({
    required this.publicId,
    required this.name,
    required this.songCount,
    this.coverUrl,
    this.viewerIsOwner = false,
    this.isPrivate = false,
  });

  @override
  bool operator ==(Object other) =>
      other is PlaylistSummary &&
      other.publicId == publicId &&
      other.name == name &&
      other.coverUrl == coverUrl &&
      other.songCount == songCount &&
      other.viewerIsOwner == viewerIsOwner &&
      other.isPrivate == isPrivate;

  @override
  int get hashCode => Object.hash(publicId, name, coverUrl, songCount, viewerIsOwner, isPrivate);
}
