import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/features/event/presentation/stores/my_events_store.dart';

import '../home/fake_home_apis.dart';

void main() {
  late FakeEventApi api;
  late MyEventsStore store;
  final start = DateTime(2026, 10, 16, 20);

  setUp(() {
    api = FakeEventApi()..events = [event('a'), event('b')];
    store = MyEventsStore(api, 'u-1');
  });

  Future<void> create() => store.create(
        name: 'Rooftop',
        description: 'Bring snacks',
        visibility: EventVisibility.private,
        voteLicense: VoteLicense.invitedOnly,
        startsAt: start,
        endsAt: start.add(const Duration(hours: 3)),
      );

  test('start loads the events', () async {
    await store.start();

    expect(store.events.value.data!.map((e) => e.publicId), ['a', 'b']);
    expect(api.calls, 1);
  });

  test('a failed load is reported, and reload recovers', () async {
    api.failure = const NetworkError('offline');
    await store.start();
    expect(store.events.value.error, isA<NetworkError>());

    api.failure = null;
    await store.reload();
    expect(store.events.value.error, isNull);
    expect(store.events.value.data, hasLength(2));
  });

  test('create sends the choices and adds the event to the list', () async {
    await store.start();
    await create();

    expect(api.created.single, (
      host: 'u-1',
      name: 'Rooftop',
      description: 'Bring snacks',
      visibility: EventVisibility.private,
      voteLicense: VoteLicense.invitedOnly,
      startsAt: start,
      endsAt: start.add(const Duration(hours: 3)),
      venue: null,
    ));
    expect(store.events.value.data!.map((e) => e.publicId), ['new-1', 'a', 'b']);
    expect(store.events.value.data!.first.visibility, EventVisibility.private);
  });

  test('a refused create throws and leaves the list as it was', () async {
    await store.start();
    api.failure = const InvalidInputError('ends_at must be in the future');

    await expectLater(create(), throwsA(isA<InvalidInputError>()));
    expect(store.events.value.data!.map((e) => e.publicId), ['a', 'b']);
  });

  test('nothing is written after stop', () async {
    final loading = store.start();
    store.stop();
    await loading; // would throw if it wrote to the disposed notifier
  });
}
