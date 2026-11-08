import 'package:fixnum/fixnum.dart';

import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/gen/music_room/v1/dto/event.pb.dart';
import 'package:app/gen/music_room/v1/dto/song.pb.dart';
import 'package:app/globals/app_constants.dart';

// gRPC only for now: EventService is called natively, so there is no
// V1MusicEventDTO (OpenAPI) mapper yet. Add one with the web source.

extension MusicEventDTOMapping on MusicEventDTO {
  EventSummary toSummary() => EventSummary(
        publicId: publicId,
        name: name,
        description: description.isEmpty ? null : description,
        status: status,
        startsAt: _time(startsAt),
        endsAt: _time(endsAt),
        createdAt: _time(createdAt) ?? DateTime.fromMillisecondsSinceEpoch(0),
        visibility: EventVisibility.fromWire(visibility),
        voteLicense: voteLicense.isEmpty ? 'everyone' : voteLicense,
        venue: venueRadiusMeters > 0
            ? (
                latitude: venueLatitude,
                longitude: venueLongitude,
                radiusMeters: venueRadiusMeters,
              )
            : null,
        viewerIsHost: viewerIsHost,
        viewerIsMember: viewerIsMember,
        coverUrl: coverUrl.isEmpty ? null : coverUrl,
      );
}

extension SongDTOEventMapping on SongDTO {
  EventTrack toTrack() => EventTrack(
        deezerId: deezerSongId.toInt(),
        title: title,
        artist: artistName,
        album: albumTitle,
        coverUrl: coverUrl.isEmpty ? null : coverUrl,
        previewUrl: previewUrl.isEmpty ? null : previewUrl,
        duration: Duration(seconds: durationSeconds.toInt()),
      );
}

extension EventPlaybackDTOMapping on EventPlaybackDTO {
  /// `updated_at` comes in whole seconds, so the playhead worked out from it
  /// ([EventPlayback.positionAt]) can run up to a second ahead. Fine for a
  /// 30-second preview; a millisecond field is the fix if it ever matters.
  EventPlayback toPlayback() {
    final updatedAt = _time(this.updatedAt) ?? DateTime.now();
    final speaker = speakerDeviceId == 0 ? null : speakerDeviceId.toInt();
    if (currentQueueEntryId == 0 || !hasCurrentSong()) {
      return EventPlayback.idle(updatedAt, speakerDeviceId: speaker);
    }
    return EventPlayback(
      currentEntryId: currentQueueEntryId.toInt(),
      track: currentSong.toTrack(),
      isPaused: isPaused,
      position: Duration(milliseconds: positionMs),
      updatedAt: updatedAt,
      speakerDeviceId: speaker,
    );
  }
}

extension EventQueueEntryDTOMapping on EventQueueEntryDTO {
  QueueEntry toQueueEntry() => QueueEntry(
        publicId: publicId,
        voteCount: voteCount.toInt(),
        track: song.toTrack(),
        viewerHasVoted: viewerHasVoted,
      );
}

extension EventMemberDTOMapping on EventMemberDTO {
  /// [mediaUrl] turns the avatar's storage key into a URL; the default points
  /// at the configured backend, tests pass their own.
  EventMember toMember({String Function(String storageKey) mediaUrl = AppConstants.mediaUrl}) =>
      EventMember(
        displayName: displayName,
        publicId: userPublicId.isEmpty ? null : userPublicId,
        avatarUrl: avatarStorageKey.isEmpty ? null : mediaUrl(avatarStorageKey),
        role: role,
        joinedAt: _time(joinedAt),
      );
}

/// Unix seconds, where 0 means not set.
DateTime? _time(Int64 seconds) =>
    seconds == 0 ? null : DateTime.fromMillisecondsSinceEpoch(seconds.toInt() * 1000);
