import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/features/event/data/event_source.dart';

/// In-memory [EventInfoApi] and [EventSettingsApi] over one event: a change
/// shows in what [event] answers next. [calls] records the changes
/// ("visibility private", "invite u-3"); [failure] is thrown by each while set.
class FakeEventSettingsApi implements EventInfoApi, EventSettingsApi {
  EventSummary eventSummary;
  List<EventMember> people;
  final List<String> calls = [];
  AppError? failure;
  bool ended = false;

  FakeEventSettingsApi(this.eventSummary, {this.people = const []});

  void _change(String call) {
    calls.add(call);
    if (failure != null) {
      throw failure!;
    }
  }

  EventSummary _with({EventVisibility? visibility, String? voteLicense, EventVenue? venue}) =>
      EventSummary(
        publicId: eventSummary.publicId,
        name: eventSummary.name,
        status: eventSummary.status,
        createdAt: eventSummary.createdAt,
        startsAt: eventSummary.startsAt,
        endsAt: eventSummary.endsAt,
        visibility: visibility ?? eventSummary.visibility,
        voteLicense: voteLicense ?? eventSummary.voteLicense,
        venue: venue ?? eventSummary.venue,
      );

  @override
  Future<EventSummary> event(String eventPublicId, String viewerPublicId) async => eventSummary;

  @override
  Future<List<EventMember>> members(String eventPublicId, String viewerPublicId) async => people;

  @override
  Future<List<QueueEntry>> queue(String eventPublicId, String viewerPublicId) async => const [];

  @override
  Future<void> setVisibility(
      String eventPublicId, String userPublicId, EventVisibility visibility) async {
    _change('visibility ${visibility.wire}');
    eventSummary = _with(visibility: visibility);
  }

  @override
  Future<void> setVoteLicense(
      String eventPublicId, String userPublicId, VoteLicense license) async {
    _change('license ${license.wire}');
    eventSummary = _with(voteLicense: license.wire);
  }

  /// What the last setPlaceAndTime sent.
  ({EventVenue venue, ({String start, String end, String timezone}) window})? placeAndTime;

  @override
  Future<void> setPlaceAndTime(
    String eventPublicId,
    String userPublicId,
    EventVenue venue,
    ({String start, String end, String timezone}) window,
  ) async {
    _change('place and time');
    placeAndTime = (venue: venue, window: window);
    eventSummary = _with(voteLicense: 'location_time', venue: venue);
  }

  @override
  Future<void> invite(String eventPublicId, String userPublicId, String inviteePublicId) async {
    _change('invite $inviteePublicId');
    people = [
      ...people,
      EventMember(displayName: inviteePublicId, role: 'viewer', publicId: inviteePublicId),
    ];
  }

  @override
  Future<void> end(String eventPublicId) async {
    _change('end');
    ended = true;
  }
}
