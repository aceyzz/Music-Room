import 'package:app/core/date/date.dart';
import 'package:flutter/foundation.dart';
export './auth/auth_user.dart';
export './auth/linked_account.dart';
export './auth/oauth_provider.dart';
export './user/profile_update.dart';
export './user/user_profile.dart';
export './song/song.dart';
export './song/song_event.dart';
export './song/song_detail.dart';
export './song/song_detail_event.dart';
// =============================================================================
// FRIEND MODEL
// =============================================================================

@immutable
class Friend {
  final String id;
  final String username;
  final String avatarUrl;

  const Friend({
    required this.id,
    required this.username,
    required this.avatarUrl,
  });

  Friend copyWith({
    String? id,
    String? username,
    String? avatarUrl,
  }) {
    return Friend(
      id: id ?? this.id,
      username: username ?? this.username,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}

// =============================================================================
// USER MODEL
// =============================================================================

@immutable
class User {
  final String id;
  final String username;
  final String avatarUrl;
  final List<Playlist> playlists;

  const User({
    required this.id,
    required this.username,
    required this.avatarUrl,
    this.playlists = const [],
  });

  User copyWith({
    String? id,
    String? username,
    String? avatarUrl,
    List<Playlist>? playlists,
  }) {
    return User(
      id: id ?? this.id,
      username: username ?? this.username,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      playlists: playlists ?? this.playlists,
    );
  }
}

// =============================================================================
// PLAYLIST MODEL
// =============================================================================

@immutable
class Playlist {
  final String id;
  final String title;
  final String imageUrl;
  final int trackCount;
  final bool isMyPlaylist;
  final List<String> participantAvatars;

  const Playlist({
    required this.id,
    required this.title,
    required this.imageUrl,
    required this.trackCount,
    required this.isMyPlaylist,
    this.participantAvatars = const [],
  });

  Playlist copyWith({
    String? id,
    String? title,
    String? imageUrl,
    int? trackCount,
    bool? isMyPlaylist,
    List<String>? participantAvatars,
  }) {
    return Playlist(
      id: id ?? this.id,
      title: title ?? this.title,
      imageUrl: imageUrl ?? this.imageUrl,
      trackCount: trackCount ?? this.trackCount,
      isMyPlaylist: isMyPlaylist ?? this.isMyPlaylist,
      participantAvatars: participantAvatars ?? this.participantAvatars,
    );
  }
}

// =============================================================================
// MUSIC EVENT MODEL
// =============================================================================

@immutable
class MusicEvent {
  final String id;
  final String title;
  final String description;
  final String imageUrl;
  final DateTime date;

  const MusicEvent({
    required this.id,
    required this.title,
    required this.description,
    required this.imageUrl,
    required this.date,
  });

  /// Named constructor that parses a [String] date (e.g., ISO-8601).
  MusicEvent.fromString({
    required String id,
    required String title,
    required String description,
    required String imageUrl,
    required String date,
  }) : this(
          id: id,
          title: title,
          description: description,
          imageUrl: imageUrl,
          date: parseDateString(date),
        );

  MusicEvent copyWith({
    String? id,
    String? title,
    String? description,
    String? imageUrl,
    DateTime? date,
  }) {
    return MusicEvent(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      imageUrl: imageUrl ?? this.imageUrl,
      date: date ?? this.date,
    );
  }
}