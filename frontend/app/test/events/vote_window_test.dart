import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/models/event/event_settings.dart';

void main() {
  test("the window is the event's hours, in UTC", () {
    expect(
      voteWindowFor(DateTime.utc(2026, 10, 17, 18, 30), DateTime.utc(2026, 10, 17, 23)),
      (start: '18:30', end: '23:00', timezone: 'UTC'),
    );
  });

  test('a night event crosses midnight, which the server allows', () {
    expect(
      voteWindowFor(DateTime.utc(2026, 10, 17, 22), DateTime.utc(2026, 10, 18, 3)),
      (start: '22:00', end: '03:00', timezone: 'UTC'),
    );
  });

  test('an event of a day or more votes all day', () {
    expect(
      voteWindowFor(DateTime.utc(2026, 10, 15, 12), DateTime.utc(2026, 10, 18, 2)),
      (start: '00:00', end: '23:59', timezone: 'UTC'),
    );
  });

  test('no times, no window', () {
    expect(voteWindowFor(null, DateTime.utc(2026)), isNull);
    expect(voteWindowFor(DateTime.utc(2026), null), isNull);
  });
}
