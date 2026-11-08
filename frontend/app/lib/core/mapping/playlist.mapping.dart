import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_details.dart';
import 'package:app/core/models/playlist/playlist_member.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/models/playlist/playlist_summary.dart';
import 'package:app/gen/music_room/v1/dto/playlist.pb.dart';
import 'package:app/globals/app_constants.dart';

// gRPC only for now: PlaylistService is called natively, so there is no
// V1PlaylistDTO (OpenAPI) mapper yet. Add one with the web source.

extension PlaylistDTOMapping on PlaylistDTO {
  /// [mediaUrl] turns the cover's storage key into a URL; the default points
  /// at the configured backend, tests pass their own.
  PlaylistSummary toSummary(
          {String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) =>
      PlaylistSummary(
        publicId: publicId,
        name: name,
        songCount: songCount,
        coverUrl: coverStorageKey.isEmpty ? null : mediaUrl(coverStorageKey),
      );

  PlaylistDetails toDetails(
          {String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) =>
      PlaylistDetails(
        publicId: publicId,
        name: name,
        coverUrl: coverStorageKey.isEmpty ? null : mediaUrl(coverStorageKey),
        visibility: PlaylistVisibility.fromWire(visibility),
        editLicense: EditLicense.fromWire(editLicense),
        songCount: songCount,
        totalDuration: Duration(seconds: totalDurationSeconds),
        revision: revision.toInt(),
      );
}

extension PlaylistMemberDTOMapping on PlaylistMemberDTO {
  /// [mediaUrl] turns the avatar's storage key into a URL; the default points
  /// at the configured backend, tests pass their own.
  PlaylistMember toMember({String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) =>
      PlaylistMember(
        publicId: userPublicId,
        displayName: displayName,
        avatarUrl: avatarStorageKey.isEmpty ? null : mediaUrl(avatarStorageKey),
        role: PlaylistRole.fromWire(role),
      );
}

extension PlaylistListItemDTOMapping on PlaylistListItemDTO {
  LibraryPlaylist toLibraryPlaylist() => LibraryPlaylist(
        publicId: publicId,
        name: name,
        coverUrl: firstSongCoverUrl.isEmpty ? null : firstSongCoverUrl,
        songCount: songCount,
        editorCount: editorCount,
        ownerPublicId: ownerPublicId,
        ownerName: ownerDisplayName,
        // An unknown value reads as public: the loosest tie, never a claim
        // the playlist is the user's.
        relation: PlaylistRelation.values
            .firstWhere((r) => r.name == relation, orElse: () => PlaylistRelation.public),
        ownerIsFriend: ownerIsFriend,
        visibility: PlaylistVisibility.fromWire(visibility),
      );
}

extension PlaylistSongDTOMapping on PlaylistSongDTO {
  PlaylistEntry toEntry() => PlaylistEntry(id: id.toInt(), track: song.toTrack());
}
