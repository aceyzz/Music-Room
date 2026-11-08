import 'package:fixnum/fixnum.dart';

import 'package:app/core/location/position_source.dart';
import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/sources/grpc_source.dart';
import 'package:app/features/event/data/commands/event_grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/event_service.pbgrpc.dart';

/// What the app needs from EventService. An interface so stores can be tested
/// without a channel.
abstract interface class EventApi {
  /// The events of [userPublicId] (the signed-in user; the server checks it
  /// against the session).
  ///
  /// Today that is only the events they host: GetMusicEvents does not list the
  /// ones they joined or were invited to yet (docs/todo.md §3).
  Future<List<EventSummary>> myEvents(String userPublicId);

  /// Creates an event hosted by [hostPublicId] (the signed-in user), planned
  /// from [startsAt] to [endsAt]. With [venue], only people there can vote,
  /// while it runs (`location_time`, its window those times); [voteLicense]
  /// is then not used. The server refuses an end that is not after
  /// the start or is already past; a start in the past is fine.
  Future<EventSummary> createEvent(
    String hostPublicId, {
    required String name,
    String description = '',
    required EventVisibility visibility,
    required VoteLicense voteLicense,
    required DateTime startsAt,
    required DateTime endsAt,
    EventVenue? venue,
  });
}

/// One state of a live event as the viewer sees it: what watch sends.
typedef LiveEventView = ({
  EventSummary event,
  EventPlayback playback,
  bool canControl,
  List<QueueEntry> queue,
  // May vote and suggest (event#can_vote): the ballots and the + show then.
  bool canVote,
});

/// What the live event screen needs from EventService: the event, what it is
/// playing, its queue, and the playback buttons.
///
/// Apart from [EventApi] so the Home and Events fakes do not have to grow
/// with it. Every id is a public id; [viewerPublicId] / [userPublicId] is the
/// signed-in user, checked against the session by the server.
abstract interface class LiveEventApi {
  Future<EventSummary> event(String eventPublicId, String viewerPublicId);

  /// The event, what plays, who controls it and the queue at once, then again
  /// after every change anyone makes (a vote, a suggestion, the buttons, the
  /// next song starting on its own), for as long as it is listened to. Ends
  /// with NotFoundError when the event is gone.
  Stream<LiveEventView> watch(String eventPublicId, String viewerPublicId);

  /// What is playing, and whether the viewer may press the buttons
  /// (host-only for now, see docs/todo.md §4.3).
  Future<({EventPlayback playback, bool canControl})> playback(
    String eventPublicId,
    String viewerPublicId,
  );

  /// The songs waiting, in play order.
  Future<List<QueueEntry>> queue(String eventPublicId, String viewerPublicId);

  /// The host and the invited people: the page shows who the host is.
  Future<List<EventMember>> members(String eventPublicId, String viewerPublicId);

  /// Ends the current song and plays the most-voted one. Throws
  /// [PreconditionFailedError] when the queue is empty.
  Future<({EventPlayback playback, List<QueueEntry> queue})> playNext(
    String eventPublicId,
    String userPublicId,
  );

  /// Pauses or resumes at [position]: pause, resume, seek and restart are all
  /// this one call today.
  Future<EventPlayback> setPlayback(
    String eventPublicId,
    String userPublicId, {
    required bool isPaused,
    required Duration position,
  });

  /// Upvotes [entryPublicId], once: voting again is a no-op, and there is no
  /// un-vote. [accepted] is false when the vote was not counted (already
  /// cast, or the song left the queue); [queue] is the queue after it, in
  /// play order, either way. [at] is where the voter is, for an event
  /// that only counts votes from its venue (`location_time`).
  Future<({bool accepted, List<QueueEntry> queue})> castVote(
    String eventPublicId,
    String userPublicId,
    String entryPublicId, {
    Position? at,
  });

  /// Adds the Deezer song [deezerSongId] to the queue, with no votes: it
  /// goes after every song that has some, so only votes move it up.
  /// Throws [ConflictError] when it is already queued or playing. Answers
  /// with the queue after it, in play order. Never starts the radio, even
  /// when nothing plays: only the host's play does. [at] as for [castVote].
  Future<List<QueueEntry>> suggestSong(
    String eventPublicId,
    String userPublicId,
    int deezerSongId, {
    Position? at,
  });
}

/// What the info page of an upcoming event and the recap of a past one need
/// from EventService. Read-only.
///
/// [event] and [queue] are the same calls as on [LiveEventApi]; one source
/// implements both, and the separate interface keeps each page's fake to what
/// that page calls.
abstract interface class EventInfoApi {
  Future<EventSummary> event(String eventPublicId, String viewerPublicId);

  /// The songs waiting, in play order.
  Future<List<QueueEntry>> queue(String eventPublicId, String viewerPublicId);

  /// The host and everyone invited, in the order they joined.
  Future<List<EventMember>> members(String eventPublicId, String viewerPublicId);
}

/// Native gRPC implementation of [EventApi]. Built with the network's
/// interceptors, so the session token is attached.
/// What an event's settings page needs from EventService: the changes its
/// host and admins make after creation. [userPublicId] is the signed-in
/// user, checked against the session by the server, which also decides who
/// may do what; refusals throw its AppError.
abstract interface class EventSettingsApi {
  Future<void> setVisibility(String eventPublicId, String userPublicId, EventVisibility visibility);

  /// Everyone or invited people only: `location_time` needs a venue and a
  /// window, which only the create form asks for.
  Future<void> setVoteLicense(String eventPublicId, String userPublicId, VoteLicense license);

  /// Only people within [venue] during [window] can vote (`location_time`).
  Future<void> setPlaceAndTime(
    String eventPublicId,
    String userPublicId,
    EventVenue venue,
    ({String start, String end, String timezone}) window,
  );

  Future<void> invite(String eventPublicId, String userPublicId, String inviteePublicId);

  Future<void> end(String eventPublicId);
}

class EventGrpcSource extends GrpcSource<void, EventServiceClient>
    implements EventApi, LiveEventApi, EventInfoApi, EventSettingsApi {
  @override
  final EventServiceClient client;

  EventGrpcSource(super.channel, super.interceptors)
      : client = EventServiceClient(channel, interceptors: interceptors);

  static EventGrpcSource from(AppNetwork appNetwork) =>
      GrpcSource.create(appNetwork, EventGrpcSource.new);

  @override
  Future<List<EventSummary>> myEvents(String userPublicId) async {
    final response =
        await GetMusicEventsCommand(GetMusicEventsRequest(userPublicId: userPublicId))(client);
    return [for (final event in response.events) event.toSummary()];
  }

  @override
  Future<EventSummary> createEvent(
    String hostPublicId, {
    required String name,
    String description = '',
    required EventVisibility visibility,
    required VoteLicense voteLicense,
    required DateTime startsAt,
    required DateTime endsAt,
    EventVenue? venue,
  }) async {
    final window = venue == null ? null : voteWindowFor(startsAt, endsAt);
    final response = await CreateEventCommand(CreateEventRequest(
      hostPublicId: hostPublicId,
      name: name,
      description: description,
      visibility: visibility.wire,
      voteLicense: venue == null ? voteLicense.wire : 'location_time',
      startsAt: _seconds(startsAt),
      endsAt: _seconds(endsAt),
      venueLatitude: venue?.latitude,
      venueLongitude: venue?.longitude,
      venueRadiusMeters: venue?.radiusMeters,
      voteWindowStart: window?.start,
      voteWindowEnd: window?.end,
      voteWindowTimezone: window?.timezone,
    ))(client);
    return response.event.toSummary();
  }

  @override
  Future<EventSummary> event(String eventPublicId, String viewerPublicId) async {
    final response = await GetMusicEventCommand(
      GetMusicEventRequest(publicId: eventPublicId, viewerPublicId: viewerPublicId),
    )(client);
    return response.event.toSummary();
  }

  @override
  Stream<LiveEventView> watch(String eventPublicId, String viewerPublicId) => WatchEventCommand(
        WatchEventRequest(eventPublicId: eventPublicId, viewerPublicId: viewerPublicId),
      )(client)
          .map((response) => (
                event: response.event.toSummary(),
                playback: response.playback.toPlayback(),
                canControl: response.viewerCanControl,
                queue: [for (final entry in response.queue) entry.toQueueEntry()],
                canVote: response.viewerCanVote,
              ));

  @override
  Future<({EventPlayback playback, bool canControl})> playback(
    String eventPublicId,
    String viewerPublicId,
  ) async {
    final response = await GetEventPlaybackCommand(
      GetEventPlaybackRequest(eventPublicId: eventPublicId, viewerPublicId: viewerPublicId),
    )(client);
    return (playback: response.playback.toPlayback(), canControl: response.viewerCanControl);
  }

  @override
  Future<List<QueueEntry>> queue(String eventPublicId, String viewerPublicId) async {
    final response = await ListEventQueueCommand(
      ListEventQueueRequest(eventPublicId: eventPublicId, viewerPublicId: viewerPublicId),
    )(client);
    return [for (final entry in response.queue) entry.toQueueEntry()];
  }

  @override
  Future<({EventPlayback playback, List<QueueEntry> queue})> playNext(
    String eventPublicId,
    String userPublicId,
  ) async {
    final response = await PlayNextInEventQueueCommand(
      PlayNextInEventQueueRequest(eventPublicId: eventPublicId, userPublicId: userPublicId),
    )(client);
    return (
      playback: response.playback.toPlayback(),
      queue: [for (final entry in response.queue) entry.toQueueEntry()],
    );
  }

  @override
  Future<EventPlayback> setPlayback(
    String eventPublicId,
    String userPublicId, {
    required bool isPaused,
    required Duration position,
  }) async {
    final response = await SetEventPlaybackCommand(SetEventPlaybackRequest(
      eventPublicId: eventPublicId,
      userPublicId: userPublicId,
      isPaused: isPaused,
      positionMs: position.inMilliseconds,
    ))(client);
    return response.playback.toPlayback();
  }

  @override
  Future<({bool accepted, List<QueueEntry> queue})> castVote(
    String eventPublicId,
    String userPublicId,
    String entryPublicId, {
    Position? at,
  }) async {
    final response = await CastVoteCommand(CastVoteRequest(
      eventPublicId: eventPublicId,
      userPublicId: userPublicId,
      queueEntryPublicId: entryPublicId,
      voterLatitude: at?.latitude,
      voterLongitude: at?.longitude,
    ))(client);
    return (
      accepted: response.accepted,
      queue: [for (final entry in response.queue) entry.toQueueEntry()],
    );
  }

  @override
  Future<List<QueueEntry>> suggestSong(
    String eventPublicId,
    String userPublicId,
    int deezerSongId, {
    Position? at,
  }) async {
    final response = await SuggestSongCommand(SuggestSongRequest(
      eventPublicId: eventPublicId,
      userPublicId: userPublicId,
      deezerSongId: Int64(deezerSongId),
      suggesterLatitude: at?.latitude,
      suggesterLongitude: at?.longitude,
    ))(client);
    return [for (final entry in response.queue) entry.toQueueEntry()];
  }

  @override
  Future<void> setVisibility(
    String eventPublicId,
    String userPublicId,
    EventVisibility visibility,
  ) =>
      SetEventVisibilityCommand(SetEventVisibilityRequest(
        eventPublicId: eventPublicId,
        userPublicId: userPublicId,
        visibility: visibility.wire,
      ))(client);

  @override
  Future<void> setVoteLicense(String eventPublicId, String userPublicId, VoteLicense license) =>
      SetEventVoteLicenseCommand(SetEventVoteLicenseRequest(
        eventPublicId: eventPublicId,
        userPublicId: userPublicId,
        voteLicense: license.wire,
      ))(client);

  @override
  Future<void> setPlaceAndTime(
    String eventPublicId,
    String userPublicId,
    EventVenue venue,
    ({String start, String end, String timezone}) window,
  ) =>
      SetEventVoteLicenseCommand(SetEventVoteLicenseRequest(
        eventPublicId: eventPublicId,
        userPublicId: userPublicId,
        voteLicense: 'location_time',
        venueLatitude: venue.latitude,
        venueLongitude: venue.longitude,
        venueRadiusMeters: venue.radiusMeters,
        voteWindowStart: window.start,
        voteWindowEnd: window.end,
        voteWindowTimezone: window.timezone,
      ))(client);

  @override
  Future<void> invite(String eventPublicId, String userPublicId, String inviteePublicId) =>
      InviteToEventCommand(InviteToEventRequest(
        eventPublicId: eventPublicId,
        inviterUserPublicId: userPublicId,
        inviteeUserPublicId: inviteePublicId,
      ))(client);

  @override
  Future<void> end(String eventPublicId) =>
      EndEventCommand(EndEventRequest(eventPublicId: eventPublicId))(client);

  @override
  Future<List<EventMember>> members(String eventPublicId, String viewerPublicId) async {
    final response = await ListEventMembersCommand(
      ListEventMembersRequest(eventPublicId: eventPublicId, viewerPublicId: viewerPublicId),
    )(client);
    return [for (final member in response.members) member.toMember()];
  }
}

/// Unix seconds, as the server takes times.
Int64 _seconds(DateTime time) => Int64(time.millisecondsSinceEpoch ~/ 1000);
