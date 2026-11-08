import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/mapping/event.mapping.dart';
import 'package:app/core/mapping/user.mapping.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/gen/music_room/v1/dto/event.pb.dart';
import 'package:app/gen/music_room/v1/dto/user.pb.dart';

import 'fake_home_apis.dart';

final now = DateTime.utc(2026, 10, 3, 20);
DateTime hours(int h) => now.add(Duration(hours: h));

void main() {
  group('phaseAt', () {
    test('a live event is current, an ended one past, whatever its times', () {
      expect(event('a', status: 'live', startsAt: hours(5)).phaseAt(now), EventPhase.current);
      expect(event('c', status: 'ended', startsAt: hours(5)).phaseAt(now), EventPhase.past);
    });

    test('a scheduled event is placed by its times', () {
      expect(event('a', startsAt: hours(-1), endsAt: hours(1)).phaseAt(now), EventPhase.current);
      expect(event('b', startsAt: hours(-3), endsAt: hours(-1)).phaseAt(now), EventPhase.past);
      expect(event('c', startsAt: hours(1), endsAt: hours(3)).phaseAt(now), EventPhase.upcoming);
    });

    test('a scheduled event without times, or with no end, is upcoming', () {
      expect(event('a').phaseAt(now), EventPhase.upcoming);
      expect(event('b', startsAt: hours(-1)).phaseAt(now), EventPhase.upcoming);
    });
  });

  group('EventTimeline', () {
    test('sorts past oldest first, upcoming soonest first, around what is current', () {
      final timeline = EventTimeline.from([
        event('later', startsAt: hours(48)),
        event('old', status: 'ended', endsAt: hours(-48)),
        event('live', status: 'live'),
        event('soon', startsAt: hours(2)),
        event('recent', status: 'ended', endsAt: hours(-2)),
      ], now);

      expect(timeline.past.map((e) => e.publicId), ['old', 'recent']);
      expect(timeline.current.map((e) => e.publicId), ['live']);
      expect(timeline.upcoming.map((e) => e.publicId), ['soon', 'later']);
    });

    test('events without times fall back on when they were created', () {
      final timeline = EventTimeline.from([
        event('b', createdAt: epoch.add(const Duration(days: 2))),
        event('a', createdAt: epoch.add(const Duration(days: 1))),
      ], now);

      expect(timeline.upcoming.map((e) => e.publicId), ['a', 'b']);
    });
  });

  group('mapping', () {
    test('MusicEventDTO: 0 times are null, an empty description is null', () {
      final summary = MusicEventDTO(
        publicId: 'e-1',
        name: 'Party',
        status: 'scheduled',
        startsAt: Int64(now.millisecondsSinceEpoch ~/ 1000),
        createdAt: Int64(1),
      ).toSummary();

      expect(summary.startsAt!.isAtSameMomentAs(now), isTrue); // local time, for display
      expect(summary.endsAt, isNull);
      expect(summary.description, isNull);
      expect(summary.createdAt.millisecondsSinceEpoch, 1000);
    });

    test('FriendDTO: the avatar key becomes a media URL, an empty one null', () {
      String url(String key) => 'http://media.test/$key';
      final withAvatar =
          FriendDTO(publicId: 'u-2', displayName: 'trinity', avatarStorageKey: 'a/1.png')
              .toSummary(mediaUrl: url);
      final without = FriendDTO(publicId: 'u-3', displayName: 'morpheus').toSummary(mediaUrl: url);

      expect(withAvatar.avatarUrl, 'http://media.test/a/1.png');
      expect(withAvatar.displayName, 'trinity');
      expect(without.avatarUrl, isNull);
    });
  });
}
