class Song {
  final String id;
  final String title;
  final String artist;
  final String duration;
  final String albumArtUrl;
  final bool isLiked;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    required this.duration,
    required this.albumArtUrl,
    required this.isLiked,
});

  Song copyWith({
    String? id,
    String? title,
    String? artist,
    String? duration,
    String? albumArtUrl,
    bool? isLiked,
  }) {
    return Song(
      id: id ?? this.id,
      title:title ?? this.title,
      artist: artist ?? this.artist,
      duration: duration ?? this.duration,
      albumArtUrl: albumArtUrl ?? this.albumArtUrl,
      isLiked: isLiked ?? this.isLiked,
    );
  }
}
