import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/gen/music_room/v1/dto/event.pb.dart';

import '../home/fake_home_apis.dart';

void main() {
  final now = DateTime(2026, 10, 15, 20, 30);
  DateTime hours(int h) => now.add(Duration(hours: h));

  group('EventFilter', () {
    test('two pills, Current then Upcoming: ended events are in neither', () {
      expect(EventFilter.values.map((f) => f.label), ['Current', 'Upcoming']);
    });

    final events = [
      event('ends-late', startsAt: hours(-1), endsAt: hours(5)),
      event('ends-soon', startsAt: hours(-2), endsAt: hours(1)),
      event('undated-live', status: 'live', createdAt: DateTime(2026)),
      event('next-week', startsAt: hours(24 * 7), endsAt: hours(24 * 7 + 3)),
      event('tomorrow', startsAt: hours(24), endsAt: hours(27)),
      event('undated', createdAt: DateTime(2026, 10, 1)),
      event('last-month', startsAt: hours(-24 * 30), endsAt: hours(-24 * 30 + 3)),
      event('yesterday', startsAt: hours(-24), endsAt: hours(-21)),
      event('ended', status: 'ended', createdAt: DateTime(2026, 9, 20)),
    ];
    List<String> ids(EventFilter filter) =>
        filter.pick(events, now).map((e) => e.publicId).toList();

    test('Current: what runs now, the one ending soonest first', () {
      // An undated live event sorts by when it was created.
      expect(ids(EventFilter.current), ['undated-live', 'ends-soon', 'ends-late']);
    });

    test('Upcoming: what has not started, the soonest first', () {
      expect(ids(EventFilter.upcoming), ['undated', 'tomorrow', 'next-week']);
    });

  });

  group('visibility', () {
    test('maps from the wire; an unknown value is public, the server default', () {
      MusicEventDTO dto(String visibility) =>
          MusicEventDTO(publicId: 'e', name: 'E', visibility: visibility, createdAt: Int64(1));

      expect(dto('private').toSummary().visibility, EventVisibility.private);
      expect(dto('public').toSummary().visibility, EventVisibility.public);
      expect(dto('').toSummary().visibility, EventVisibility.public);
    });

    test('is part of an event summary\'s equality', () {
      expect(event('a'), event('a'));
      expect(event('a'), isNot(event('a', visibility: EventVisibility.private)));
    });
  });
}
