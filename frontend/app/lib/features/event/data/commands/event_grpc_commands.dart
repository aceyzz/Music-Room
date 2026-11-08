import 'package:app/core/commands/categories/grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/event_service.pbgrpc.dart';

// One command per EventService RPC the app calls. Add the rest as pages need them.

class GetMusicEventsCommand
    extends RpcCallCommand<GetMusicEventsRequest, GetMusicEventsResponse, EventServiceClient> {
  const GetMusicEventsCommand(super.request);

  @override
  Future<GetMusicEventsResponse> execute(
    EventServiceClient client,
    GetMusicEventsRequest request,
  ) =>
      client.getMusicEvents(request);
}

class CreateEventCommand
    extends RpcCallCommand<CreateEventRequest, CreateEventResponse, EventServiceClient> {
  const CreateEventCommand(super.request);

  @override
  Future<CreateEventResponse> execute(
    EventServiceClient client,
    CreateEventRequest request,
  ) =>
      client.createEvent(request);
}

class GetMusicEventCommand
    extends RpcCallCommand<GetMusicEventRequest, GetMusicEventResponse, EventServiceClient> {
  const GetMusicEventCommand(super.request);

  @override
  Future<GetMusicEventResponse> execute(
    EventServiceClient client,
    GetMusicEventRequest request,
  ) =>
      client.getMusicEvent(request);
}

class WatchEventCommand
    extends RpcWatchCommand<WatchEventRequest, WatchEventResponse, EventServiceClient> {
  const WatchEventCommand(super.request);

  @override
  Stream<WatchEventResponse> execute(EventServiceClient client, WatchEventRequest request) =>
      client.watchEvent(request);
}

class GetEventPlaybackCommand
    extends RpcCallCommand<GetEventPlaybackRequest, GetEventPlaybackResponse, EventServiceClient> {
  const GetEventPlaybackCommand(super.request);

  @override
  Future<GetEventPlaybackResponse> execute(
    EventServiceClient client,
    GetEventPlaybackRequest request,
  ) =>
      client.getEventPlayback(request);
}

class ListEventQueueCommand
    extends RpcCallCommand<ListEventQueueRequest, ListEventQueueResponse, EventServiceClient> {
  const ListEventQueueCommand(super.request);

  @override
  Future<ListEventQueueResponse> execute(
    EventServiceClient client,
    ListEventQueueRequest request,
  ) =>
      client.listEventQueue(request);
}

class CastVoteCommand
    extends RpcCallCommand<CastVoteRequest, CastVoteResponse, EventServiceClient> {
  const CastVoteCommand(super.request);

  @override
  Future<CastVoteResponse> execute(EventServiceClient client, CastVoteRequest request) =>
      client.castVote(request);
}

class SuggestSongCommand
    extends RpcCallCommand<SuggestSongRequest, SuggestSongResponse, EventServiceClient> {
  const SuggestSongCommand(super.request);

  @override
  Future<SuggestSongResponse> execute(EventServiceClient client, SuggestSongRequest request) =>
      client.suggestSong(request);
}

class PlayNextInEventQueueCommand extends RpcCallCommand<PlayNextInEventQueueRequest,
    PlayNextInEventQueueResponse, EventServiceClient> {
  const PlayNextInEventQueueCommand(super.request);

  @override
  Future<PlayNextInEventQueueResponse> execute(
    EventServiceClient client,
    PlayNextInEventQueueRequest request,
  ) =>
      client.playNextInEventQueue(request);
}

class SetEventPlaybackCommand
    extends RpcCallCommand<SetEventPlaybackRequest, SetEventPlaybackResponse, EventServiceClient> {
  const SetEventPlaybackCommand(super.request);

  @override
  Future<SetEventPlaybackResponse> execute(
    EventServiceClient client,
    SetEventPlaybackRequest request,
  ) =>
      client.setEventPlayback(request);
}

class ListEventMembersCommand
    extends RpcCallCommand<ListEventMembersRequest, ListEventMembersResponse, EventServiceClient> {
  const ListEventMembersCommand(super.request);

  @override
  Future<ListEventMembersResponse> execute(
    EventServiceClient client,
    ListEventMembersRequest request,
  ) =>
      client.listEventMembers(request);
}

class SetEventVisibilityCommand extends RpcCallCommand<SetEventVisibilityRequest,
    SetEventVisibilityResponse, EventServiceClient> {
  const SetEventVisibilityCommand(super.request);

  @override
  Future<SetEventVisibilityResponse> execute(
          EventServiceClient client, SetEventVisibilityRequest request) =>
      client.setEventVisibility(request);
}

class SetEventVoteLicenseCommand extends RpcCallCommand<SetEventVoteLicenseRequest,
    SetEventVoteLicenseResponse, EventServiceClient> {
  const SetEventVoteLicenseCommand(super.request);

  @override
  Future<SetEventVoteLicenseResponse> execute(
          EventServiceClient client, SetEventVoteLicenseRequest request) =>
      client.setEventVoteLicense(request);
}

class InviteToEventCommand
    extends RpcCallCommand<InviteToEventRequest, InviteToEventResponse, EventServiceClient> {
  const InviteToEventCommand(super.request);

  @override
  Future<InviteToEventResponse> execute(EventServiceClient client, InviteToEventRequest request) =>
      client.inviteToEvent(request);
}

class EndEventCommand
    extends RpcCallCommand<EndEventRequest, EndEventResponse, EventServiceClient> {
  const EndEventCommand(super.request);

  @override
  Future<EndEventResponse> execute(EventServiceClient client, EndEventRequest request) =>
      client.endEvent(request);
}
