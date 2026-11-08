import 'dart:async';
import 'package:app/core/repository/repository.dart';
import 'package:app/core/models/models.dart';

/// Repository managing high-level song and playlist state operations.
class PlaylistRepository implements Repository {
  const PlaylistRepository();

  // =============================================================================
  // MOCKED PLAYLIST METHODS
  // =============================================================================

  /// Returns a mocked list of playlists instead of executing a network request.
  Future<List<Playlist>> getPlaylists() async {
    await Future.delayed(const Duration(milliseconds: 300));

    return [
      Playlist(
        id: 'p1',
        title: 'Chill Vibes 2025',
        imageUrl: 'https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=400',
        trackCount: 34,
        isMyPlaylist: true,
        participantAvatars: const [
          'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=200',
          'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=200',
          'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200',
          'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=200',
        ],
      ),
      Playlist(
        id: 'p2',
        title: 'Top Hits Radio',
        imageUrl: 'https://images.unsplash.com/photo-1470225620780-dba8ba36b745?w=400',
        trackCount: 50,
        isMyPlaylist: false,
        participantAvatars: const [
          'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=200',
          'https://images.unsplash.com/photo-1522075469751-3a6694fb2f61?w=200',
          'https://images.unsplash.com/photo-1517841905240-472988babdf9?w=200',
        ],
      ),
      Playlist(
        id: 'p3',
        title: 'Late Night Coding Beats',
        imageUrl: 'https://images.unsplash.com/photo-1518609878373-06d740f60d8b?w=400',
        trackCount: 48,
        isMyPlaylist: true,
        participantAvatars: const [
          'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=200',
          'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=200',
        ],
      ),
      Playlist(
        id: 'p4',
        title: 'Deep Focus & Lo-Fi',
        imageUrl: 'https://images.unsplash.com/photo-1508700115892-45ecd05ae2ad?w=400',
        trackCount: 65,
        isMyPlaylist: false,
        participantAvatars: const [
          'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200',
          'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=200',
          'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=200',
          'https://images.unsplash.com/photo-1522075469751-3a6694fb2f61?w=200',
          'https://images.unsplash.com/photo-1517841905240-472988babdf9?w=200',
        ],
      ),
      Playlist(
        id: 'p5',
        title: 'Workout Energy Blast',
        imageUrl: 'https://images.unsplash.com/photo-1571019613454-1cb2f99b2d8b?w=400',
        trackCount: 22,
        isMyPlaylist: true,
        participantAvatars: const [
          'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=200',
          'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=200',
          'https://images.unsplash.com/photo-1522075469751-3a6694fb2f61?w=200',
        ],
      ),
    ];
  }

  /// Returns a single mocked playlist by [id].
  Future<Playlist> getPlaylistById(String id) async {
    final playlists = await getPlaylists();
    return playlists.firstWhere(
      (p) => p.id == id,
      orElse: () => playlists.first,
    );
  }
}
