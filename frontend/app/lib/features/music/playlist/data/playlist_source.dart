import 'package:fixnum/fixnum.dart';

import 'package:app/core/mapping/playlist.mapping.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/sources/grpc_source.dart';
import 'package:app/features/music/playlist/data/commands/playlist_grpc_commands.dart';
import 'package:app/gen/music_room/v1/dto/playlist.pb.dart';
import 'package:app/gen/music_room/v1/services/playlist_service.pbgrpc.dart';

/// What the app needs from PlaylistService. An interface so stores can be
/// tested without a channel.
abstract interface class PlaylistApi {
  /// At most [limit] playlists for the Home "Your playlists" row: the first
  /// of [userPublicId]'s library (theirs, shared with them, their friends'),
  /// most recently changed first.
  Future<List<PlaylistSummary>> recentPlaylists(String userPublicId, {int limit = 5});

  /// The Playlists tab's library, in one call: what [userPublicId] (the
  /// signed-in user) owns, what they were invited to, and their friends'
  /// public playlists. One call so switching pills needs no request; the
  /// server decides the order and each playlist's relation.
  Future<List<LibraryPlaylist>> library(String userPublicId);

  /// Public playlists whose name matches [query], newest first when it is
  /// empty. [pageToken] is the previous page's `nextPageToken`. With
  /// [myTaste], only those whose owner likes a genre the user likes (among
  /// owners who show their music preferences to everyone).
  Future<PlaylistResults> publicPlaylists(
      {String query = '', String? pageToken, int pageSize = 30, bool myTaste = false});

  /// Creates an empty playlist owned by [ownerPublicId] (the signed-in user).
  Future<PlaylistSummary> createPlaylist(
    String ownerPublicId, {
    required String name,
    required PlaylistVisibility visibility,
    required EditLicense editLicense,
  });
}

/// One state of a playlist as the viewer sees it: what openPlaylist answers,
/// and what watchPlaylist sends.
typedef PlaylistView = ({PlaylistDetails details, List<PlaylistEntry> songs, bool canEdit});

/// What the playlist page needs from PlaylistService: one playlist, its
/// songs, and the edits to them. Separate from [PlaylistApi] so the pages that
/// only list playlists (and their fakes) do not grow with it.
///
/// Every edit answers with the whole playlist as it is after the edit,
/// including what others changed meanwhile. Each throws the server's
/// AppError.
abstract interface class PlaylistEditorApi {
  /// The playlist, its songs in order, and whether [viewerPublicId] (the
  /// signed-in user) may add, move and remove songs.
  Future<({PlaylistDetails details, List<PlaylistEntry> songs, bool canEdit})> openPlaylist(
      String publicId, String viewerPublicId);

  /// The same as [openPlaylist] at once, then again after every change anyone
  /// makes, for as long as it is listened to. Ends with NotFoundError when
  /// the viewer may no longer see the playlist (made private, deleted).
  Stream<PlaylistView> watchPlaylist(String publicId, String viewerPublicId);

  /// Appends the Deezer song [deezerId]. Throws ConflictError when it is
  /// already in the playlist, unless [allowDuplicate]: the server checks it
  /// under the playlist's lock, so this also catches someone else adding the
  /// same song a moment earlier.
  Future<PlaylistContents> addSong(String publicId, String userPublicId, int deezerId,
      {bool allowDuplicate = false});

  /// Removes the row [entryId]. NotFoundError when it is already gone.
  Future<PlaylistContents> removeSong(String publicId, String userPublicId, int entryId);

  /// Moves the row [entryId] to just after the row [afterEntryId], or to the
  /// top when it is 0. NotFoundError when either row has been removed.
  Future<PlaylistContents> moveSong(String publicId, String userPublicId, int entryId,
      {required int afterEntryId});
}

/// What a playlist's settings page needs from PlaylistService: its people,
/// and the changes its owner and admins make after creation. Separate from
/// [PlaylistEditorApi] so the song editor and its fake do not grow with it.
///
/// [userPublicId] is the signed-in user, checked against the session by the
/// server, which also decides who may do what (the owner and admins manage,
/// invited people may invite, only the owner deletes); refusals throw its
/// AppError.
abstract interface class PlaylistSettingsApi {
  /// The owner first, then admins, editors and viewers.
  Future<List<PlaylistMember>> members(String publicId, String userPublicId);

  Future<void> rename(String publicId, String name);

  Future<void> setVisibility(String publicId, PlaylistVisibility visibility);

  Future<void> setEditLicense(String publicId, EditLicense license);

  /// Makes [inviteePublicId] an editor of the playlist.
  Future<void> invite(String publicId, String userPublicId, String inviteePublicId);

  Future<void> delete(String publicId);
}

/// Native gRPC implementation of [PlaylistApi] and [PlaylistEditorApi]. Built with the network's
/// interceptors, so the session token is attached.
class PlaylistGrpcSource extends GrpcSource<void, PlaylistServiceClient>
    implements PlaylistApi, PlaylistEditorApi, PlaylistSettingsApi {
  @override
  final PlaylistServiceClient client;

  PlaylistGrpcSource(super.channel, super.interceptors)
      : client = PlaylistServiceClient(channel, interceptors: interceptors);

  static PlaylistGrpcSource from(AppNetwork appNetwork) =>
      GrpcSource.create(appNetwork, PlaylistGrpcSource.new);

  /// The library's first [limit] (ListLibraryPlaylists): no RPC of its own,
  /// the library is already in the order the row wants.
  @override
  Future<List<PlaylistSummary>> recentPlaylists(String userPublicId, {int limit = 5}) async => [
        for (final playlist in (await library(userPublicId)).take(limit))
          PlaylistSummary(
            publicId: playlist.publicId,
            name: playlist.name,
            songCount: playlist.songCount,
            coverUrl: playlist.coverUrl,
            viewerIsOwner: playlist.relation == PlaylistRelation.mine,
            isPrivate: playlist.visibility == PlaylistVisibility.private,
          ),
      ];

  @override
  Future<List<LibraryPlaylist>> library(String userPublicId) async {
    final response = await ListLibraryPlaylistsCommand(
        ListLibraryPlaylistsRequest(viewerPublicId: userPublicId))(client);
    return [for (final playlist in response.playlists) playlist.toLibraryPlaylist()];
  }

  /// No viewer id to send: the interceptor fills the caller in from the
  /// session (`viewer_public_id`).
  @override
  Future<PlaylistResults> publicPlaylists({
    String query = '',
    String? pageToken,
    int pageSize = 30,
    bool myTaste = false,
  }) async {
    final response = await SearchPublicPlaylistsCommand(SearchPublicPlaylistsRequest(
      query: query,
      pageSize: pageSize,
      pageToken: pageToken ?? '',
      myTaste: myTaste,
    ))(client);
    return PlaylistResults(
      [for (final playlist in response.playlists) playlist.toLibraryPlaylist()],
      nextPageToken: response.nextPageToken.isEmpty ? null : response.nextPageToken,
    );
  }

  @override
  Future<PlaylistSummary> createPlaylist(
    String ownerPublicId, {
    required String name,
    required PlaylistVisibility visibility,
    required EditLicense editLicense,
  }) async {
    final response = await CreatePlaylistCommand(CreatePlaylistRequest(
      ownerPublicId: ownerPublicId,
      name: name,
      visibility: visibility.wire,
      editLicense: editLicense.wire,
    ))(client);
    return response.playlist.toSummary();
  }

  @override
  Future<({PlaylistDetails details, List<PlaylistEntry> songs, bool canEdit})> openPlaylist(
      String publicId, String viewerPublicId) async {
    final response = await GetPlaylistCommand(GetPlaylistRequest(
      playlistPublicId: publicId,
      viewerPublicId: viewerPublicId,
    ))(client);
    return (
      details: response.playlist.toDetails(),
      songs: [for (final song in response.songs) song.toEntry()],
      canEdit: response.viewerCanEditSongs,
    );
  }

  @override
  Stream<PlaylistView> watchPlaylist(String publicId, String viewerPublicId) =>
      WatchPlaylistCommand(WatchPlaylistRequest(
        playlistPublicId: publicId,
        viewerPublicId: viewerPublicId,
      ))(client)
          .map((response) => (
                details: response.playlist.toDetails(),
                songs: [for (final song in response.songs) song.toEntry()],
                canEdit: response.viewerCanEditSongs,
              ));

  @override
  Future<PlaylistContents> addSong(String publicId, String userPublicId, int deezerId,
      {bool allowDuplicate = false}) async {
    final response = await AddSongToPlaylistCommand(AddSongToPlaylistRequest(
      playlistPublicId: publicId,
      userPublicId: userPublicId,
      deezerSongId: Int64(deezerId),
      allowDuplicate: allowDuplicate,
    ))(client);
    return _contents(response.playlist, response.songs);
  }

  @override
  Future<PlaylistContents> removeSong(String publicId, String userPublicId, int entryId) async {
    final response = await RemoveSongFromPlaylistCommand(RemoveSongFromPlaylistRequest(
      playlistPublicId: publicId,
      userPublicId: userPublicId,
      playlistSongId: Int64(entryId),
    ))(client);
    return _contents(response.playlist, response.songs);
  }

  @override
  Future<PlaylistContents> moveSong(String publicId, String userPublicId, int entryId,
      {required int afterEntryId}) async {
    final response = await MoveSongInPlaylistCommand(MoveSongInPlaylistRequest(
      playlistPublicId: publicId,
      userPublicId: userPublicId,
      playlistSongId: Int64(entryId),
      afterPlaylistSongId: Int64(afterEntryId),
    ))(client);
    return _contents(response.playlist, response.songs);
  }

  @override
  Future<List<PlaylistMember>> members(String publicId, String userPublicId) async {
    final response = await ListPlaylistMembersCommand(ListPlaylistMembersRequest(
      playlistPublicId: publicId,
      viewerPublicId: userPublicId,
    ))(client);
    return [for (final member in response.members) member.toMember()];
  }

  @override
  Future<void> rename(String publicId, String name) =>
      RenamePlaylistCommand(RenamePlaylistRequest(playlistPublicId: publicId, name: name))(client);

  @override
  Future<void> setVisibility(String publicId, PlaylistVisibility visibility) =>
      SetPlaylistVisibilityCommand(SetPlaylistVisibilityRequest(
        playlistPublicId: publicId,
        visibility: visibility.wire,
      ))(client);

  @override
  Future<void> setEditLicense(String publicId, EditLicense license) =>
      SetPlaylistEditLicenseCommand(SetPlaylistEditLicenseRequest(
        playlistPublicId: publicId,
        editLicense: license.wire,
      ))(client);

  @override
  Future<void> invite(String publicId, String userPublicId, String inviteePublicId) =>
      InviteToPlaylistCommand(InviteToPlaylistRequest(
        playlistPublicId: publicId,
        inviterUserPublicId: userPublicId,
        inviteeUserPublicId: inviteePublicId,
      ))(client);

  @override
  Future<void> delete(String publicId) =>
      DeletePlaylistCommand(DeletePlaylistRequest(playlistPublicId: publicId))(client);

  static PlaylistContents _contents(PlaylistDTO playlist, List<PlaylistSongDTO> songs) => (
        details: playlist.toDetails(),
        songs: [for (final song in songs) song.toEntry()],
      );
}
