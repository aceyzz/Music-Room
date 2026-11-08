import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/features/device/presentation/stores/event_delegates_store.dart';

import '../user/fake_social_api.dart';
import 'fake_delegation_api.dart';

void main() {
  late FakeDelegationApi delegation;
  late FakeSocialApi social;
  late EventDelegatesStore store;

  const sarah = FriendSummary(publicId: 'sarah', displayName: 'Sarah');
  const noah = FriendSummary(publicId: 'noah', displayName: 'Noah');

  setUp(() {
    delegation = FakeDelegationApi();
    social = FakeSocialApi()..friendList = [sarah, noah];
    store = EventDelegatesStore(delegation, social, 'phone', 'e1', 'alex');
  });

  tearDown(() => store.stop());

  List<(String, int?)> shown() => [
        for (final d in store.state.value.data!) (d.friend.publicId, d.licenseId),
      ];

  test('lists every friend, with the licence this event gives them on this device', () async {
    final forThisEvent = delegation.seed('phone', 'sarah', eventPublicId: 'e1');
    delegation.seed('phone', 'noah', eventPublicId: 'another-event');
    delegation.seed('tablet', 'noah', eventPublicId: 'e1');

    await store.start();

    expect(shown(), [('sarah', forThisEvent.id), ('noah', null)]);
    expect(delegation.calls, ['licenses phone']);
  });

  test('beforeGrant runs once, before the first grant only', () async {
    store.stop();
    var ran = 0;
    store = EventDelegatesStore(delegation, social, 'phone', 'e1', 'alex', beforeGrant: () async {
      ran++;
      delegation.calls.add('before');
    });
    await store.start();

    await store.toggle(store.state.value.data![0]);
    await store.toggle(store.state.value.data![1]);

    expect(ran, 1);
    expect(delegation.calls.where((c) => !c.startsWith('licenses')),
        ['before', 'grant phone sarah e1', 'grant phone noah e1']);
  });

  test('a licence for no event (an old one) gives no control here', () async {
    delegation.seed('phone', 'noah');

    await store.start();

    expect(shown().last, ('noah', null));
  });

  test("toggle grants for this event on this device, then takes it back", () async {
    await store.start();

    await store.toggle(store.state.value.data!.first);
    expect(delegation.calls, contains('grant phone sarah e1'));
    final granted = shown().first;
    expect(granted.$2, isNotNull);

    await store.toggle(store.state.value.data!.first);
    expect(delegation.calls, contains('revoke phone ${granted.$2}'));
    expect(shown().first, ('sarah', null));
  });

  test('a failed toggle throws and keeps the list as it was', () async {
    await store.start();
    delegation.failure = const ConflictError('already granted');

    await expectLater(store.toggle(store.state.value.data!.first), throwsA(isA<ConflictError>()));
    expect(shown().first, ('sarah', null));
  });

  test('a failed load is reported, and reload recovers', () async {
    delegation.failure = const NetworkError('offline');

    await store.start();
    expect(store.state.value.error, isA<NetworkError>());

    await store.reload();
    expect(shown(), hasLength(2));
  });
}
