import 'package:intl/intl.dart';

/// Who can find and open an event (`events.visibility`).
enum EventVisibility {
  public('public', 'Public', 'Anyone can find it and join in.'),
  private('private', 'Private', 'Only invited people can find it and vote.');

  final String wire;
  final String label;
  final String description;

  const EventVisibility(this.wire, this.label, this.description);

  /// An unknown value is [public], the server's default.
  static EventVisibility fromWire(String value) =>
      values.firstWhere((v) => v.wire == value, orElse: () => public);
}

/// Who can suggest songs and vote (`events.vote_license`). Like a playlist's
/// edit licence, on a private event "everyone" still means only the people
/// who can see it.
///
/// The server's third licence, `location_time` (only at the venue, during a
/// time window), is not offered: it needs a venue, a radius and a vote
/// window, which means a map and geolocation (docs/todo.md §10).
enum VoteLicense {
  everyone(
    'everyone',
    'Anyone who can see it',
    'Anyone who can find it can suggest songs and vote.',
  ),
  invitedOnly(
    'invited_only',
    'Only invited people',
    'Only the people invited to it can suggest songs and vote. Everyone else can listen.',
  );

  final String wire;
  final String label;

  /// What the choice means, in a sentence, under the picker.
  final String description;

  const VoteLicense(this.wire, this.label, this.description);

  /// Null for `location_time`, which only the create form sets.
  static VoteLicense? fromWire(String value) => values.where((l) => l.wire == value).firstOrNull;
}

/// Where a place-and-time event (vote licence `location_time`) counts votes
/// from: [latitude], [longitude] in degrees, and up to [radiusMeters] from it.
typedef EventVenue = ({double latitude, double longitude, int radiusMeters});

/// The radii offered for a venue, in meters.
const venueRadii = [100, 500, 1000];

/// The daily vote window the server wants for a place-and-time event
/// ("HH:MM" to "HH:MM" in [timezone]), taken from the event's own planned
/// times: people vote while it runs. Null when the event has no times.
///
/// In UTC, so the window means the same hours whatever the phone's zone. An
/// event of a day or more votes all day: a daily window from its start to
/// its end hour would shut it off every night.
({String start, String end, String timezone})? voteWindowFor(DateTime? startsAt, DateTime? endsAt) {
  if (startsAt == null || endsAt == null) {
    return null;
  }
  if (endsAt.difference(startsAt) >= const Duration(days: 1)) {
    return (start: '00:00', end: '23:59', timezone: 'UTC');
  }
  String hhmm(DateTime t) {
    final u = t.toUtc();
    return '${u.hour.toString().padLeft(2, '0')}:${u.minute.toString().padLeft(2, '0')}';
  }

  return (start: hhmm(startsAt), end: hhmm(endsAt), timezone: 'UTC');
}

/// Who can vote, in words, for any licence the server sends ([VoteLicense]
/// only lists the ones the create form offers). An unknown value reads as the
/// server's default.
String voteLicenseLabel(String wire) => switch (wire) {
      'invited_only' => 'Only invited people can vote',
      'location_time' => 'Only at the venue, during the vote window',
      _ => 'Anyone who can see it can vote',
    };

/// The three vote licences of V.2.1, as the create form and the settings
/// page offer them: short labels, so three fit a phone's width.
enum VoteChoice {
  everyone('Everyone'),
  invited('Invited'),
  placeAndTime('Place & time');

  final String label;

  const VoteChoice(this.label);

  static VoteChoice fromWire(String wire) => switch (wire) {
        'invited_only' => invited,
        'location_time' => placeAndTime,
        _ => everyone,
      };
}

/// "Only people within 500 m of the venue (46.5374, 6.5890) can suggest
/// songs and vote, while the event runs (20:00 to 23:00)."
String placeAndTimeText(EventVenue? venue, DateTime? startsAt, DateTime? endsAt) {
  final where = venue == null
      ? 'at the venue'
      : 'within ${venue.radiusMeters < 1000 ? '${venue.radiusMeters} m' : '${venue.radiusMeters ~/ 1000} km'}'
          ' of the venue (${venue.latitude.toStringAsFixed(4)}, ${venue.longitude.toStringAsFixed(4)})';
  final hours = startsAt == null || endsAt == null
      ? ''
      : ' (${DateFormat.Hm().format(startsAt.toLocal())} to ${DateFormat.Hm().format(endsAt.toLocal())})';
  return 'Only people $where can suggest songs and vote, while the event runs$hours.';
}
