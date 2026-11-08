import 'package:flutter/foundation.dart';

import 'package:app/core/models/event/event_settings.dart';

/// Where an event sits relative to now. The Home carousel puts [past] events
/// to the left of the [current] one and [upcoming] ones to its right.
enum EventPhase { past, current, upcoming }

/// An event as a list shows it.
@immutable
class EventSummary {
  final String publicId;
  final String name;
  final String? description;

  /// scheduled | live | ended, as the server sends it.
  final String status;

  /// When the event is planned to run. Null when not set: the app always sets
  /// both, but events created before CreateEvent took them have neither.
  final DateTime? startsAt;
  final DateTime? endsAt;

  /// Orders events that have no times.
  final DateTime createdAt;

  final EventVisibility visibility;

  /// Who can suggest and vote: everyone | invited_only | location_time, as
  /// the server sends it ([voteLicenseLabel] words it). A string rather than
  /// [VoteLicense], which leaves out location_time on purpose.
  final String voteLicense;

  /// Where votes count from, for a place-and-time event; null otherwise.
  final EventVenue? venue;

  /// Whether the signed-in user hosts it: the list marks it.
  final bool viewerIsHost;

  /// Whether the signed-in user hosts it or was invited to it: Home shows
  /// only these.
  final bool viewerIsMember;

  /// The cover of the song playing, else of the next one: the Home card's
  /// picture. Null when there is none.
  final String? coverUrl;

  const EventSummary({
    required this.publicId,
    required this.name,
    required this.status,
    required this.createdAt,
    this.description,
    this.startsAt,
    this.endsAt,
    this.visibility = EventVisibility.public,
    this.voteLicense = 'everyone',
    this.venue,
    this.viewerIsHost = false,
    this.viewerIsMember = false,
    this.coverUrl,
  });


  /// The status wins when it is decisive (live is happening, ended
  /// is over); otherwise the planned times decide, and an event with no times
  /// that has not started is upcoming. The server does not move `status` on
  /// its own yet, so a scheduled event whose window has come is current.
  EventPhase phaseAt(DateTime now) {
    switch (status) {
      case 'live':
        return EventPhase.current;
      case 'ended':
        return EventPhase.past;
    }
    final starts = startsAt;
    final ends = endsAt;
    if (ends != null && !now.isBefore(ends)) {
      return EventPhase.past;
    }
    if (starts != null && !now.isBefore(starts) && ends != null) {
      return EventPhase.current;
    }
    return EventPhase.upcoming;
  }

  @override
  bool operator ==(Object other) =>
      other is EventSummary &&
      other.publicId == publicId &&
      other.name == name &&
      other.description == description &&
      other.status == status &&
      other.startsAt == startsAt &&
      other.endsAt == endsAt &&
      other.createdAt == createdAt &&
      other.visibility == visibility &&
      other.voteLicense == voteLicense &&
      other.venue == venue &&
      other.viewerIsHost == viewerIsHost &&
      other.viewerIsMember == viewerIsMember &&
      other.coverUrl == coverUrl;

  @override
  int get hashCode => Object.hash(publicId, name, description, status, startsAt, endsAt,
      createdAt, visibility, voteLicense, venue, viewerIsHost, viewerIsMember, coverUrl);
}

/// Events in carousel order: [past] (oldest first), [current], [upcoming]
/// (soonest first).
@immutable
class EventTimeline {
  final List<EventSummary> past;
  final List<EventSummary> current;
  final List<EventSummary> upcoming;

  const EventTimeline({this.past = const [], this.current = const [], this.upcoming = const []});

  factory EventTimeline.from(Iterable<EventSummary> events, DateTime now) {
    final past = <EventSummary>[];
    final current = <EventSummary>[];
    final upcoming = <EventSummary>[];
    for (final event in events) {
      switch (event.phaseAt(now)) {
        case EventPhase.past:
          past.add(event);
        case EventPhase.current:
          current.add(event);
        case EventPhase.upcoming:
          upcoming.add(event);
      }
    }
    // Oldest first for the past, so the most recent one sits next to "now";
    // soonest first for what is coming. An event without times falls back on
    // when it was created.
    past.sort((a, b) =>
        (a.endsAt ?? a.startsAt ?? a.createdAt).compareTo(b.endsAt ?? b.startsAt ?? b.createdAt));
    upcoming.sort((a, b) => (a.startsAt ?? a.createdAt).compareTo(b.startsAt ?? b.createdAt));
    return EventTimeline(past: past, current: current, upcoming: upcoming);
  }

  bool get isEmpty => past.isEmpty && current.isEmpty && upcoming.isEmpty;
}

/// The Events tab's two pills: what runs now, and what is coming. Ended
/// events are not listed anywhere.
enum EventFilter {
  current('Current', EventPhase.current),
  upcoming('Upcoming', EventPhase.upcoming);

  final String label;
  final EventPhase phase;

  const EventFilter(this.label, this.phase);

  /// The [events] under this pill as of [now], in list order: current, the one
  /// ending soonest first; upcoming, the one starting soonest first. An event
  /// with no times falls back on when it was created.
  List<EventSummary> pick(Iterable<EventSummary> events, DateTime now) {
    final picked = events.where((e) => e.phaseAt(now) == phase).toList();
    switch (this) {
      case current:
        picked.sort((a, b) => (a.endsAt ?? a.createdAt).compareTo(b.endsAt ?? b.createdAt));
      case upcoming:
        picked.sort((a, b) => (a.startsAt ?? a.createdAt).compareTo(b.startsAt ?? b.createdAt));
    }
    return picked;
  }
}
