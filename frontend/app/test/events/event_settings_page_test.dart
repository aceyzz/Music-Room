import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/device/device_info.dart';
import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/device/user_device.dart';
import 'package:app/core/models/event/event_playback.dart';
import 'package:app/core/models/event/event_details.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/device/data/device_source.dart';
import 'package:app/features/device/presentation/stores/device_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/pages/event_settings_page.dart';

import '../auth/fake_auth_api.dart';
import '../device/fake_delegation_api.dart';
import '../device/fake_device_api.dart';
import '../home/fake_home_apis.dart' as home;
import '../mocks/mock_flutter_secure_storage.dart';
import '../user/fake_social_api.dart';
import 'fake_event_settings_api.dart';
import 'fake_live_event_api.dart' show FakeLiveEventApi, FakePositionSource;

void main() {
  late FakeEventSettingsApi api;
  late FakeSocialApi social;
  late SessionStore session;
  late FakePositionSource positions;

  /// "Who can control the music" needs these three; most tests leave them
  /// out, and the section with them. [musicControl] provides them.
  late FakeDelegationApi delegation;
  late FakeLiveEventApi live;
  DeviceStore? device;

  /// This device (FakeDeviceApi's device-1, id 1, the Pixel) and a laptop;
  /// the event plays on [speaker], or has no speaker yet.
  void musicControl({int? speaker}) {
    final store = DeviceStore(FakeDeviceApi(), session, () async => 'install-1', DeviceInfo.fallback())
      ..start();
    addTearDown(store.stop);
    device = store;
    delegation.devices = const [
      UserDevice(id: 1, publicId: 'device-1', name: 'Pixel', platform: 'android'),
      UserDevice(id: 2, publicId: 'device-2', name: 'Laptop', platform: 'desktop'),
    ];
    live.current = EventPlayback.idle(DateTime(2026, 10, 3, 21), speakerDeviceId: speaker);
  }

  // The signed-in user is u-1 (FakeAuthApi). The host is the owner.
  EventMember member(String id, String role) =>
      EventMember(displayName: 'Name $id', role: role, publicId: id);

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final auth = FakeAuthApi()..emailVerified = true;
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: auth,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    await session.login(email: 'neo@example.test', password: 'password1234');
    api = FakeEventSettingsApi(home.event('e1'));
    social = FakeSocialApi();
    positions = FakePositionSource();
    delegation = FakeDelegationApi();
    live = FakeLiveEventApi();
    device = null;
  });

  Future<void> pumpPage(WidgetTester tester, List<EventMember> people) async {
    api.people = people;
    tester.view
      ..physicalSize = const Size(412, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/events/e1/settings',
      routes: [
        GoRoute(
          path: '/events/:id/settings',
          builder: (context, state) => EventSettingsPage(
            publicId: state.pathParameters['id']!,
            positions: positions,
            showMap: false,
          ),
        ),
        GoRoute(
          path: '/users/:id',
          builder: (context, state) => Text('profile ${state.pathParameters['id']}'),
        ),
        GoRoute(path: '/events', builder: (context, state) => const Text('events list')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<EventInfoApi>.value(value: api),
        Provider<EventSettingsApi>.value(value: api),
        Provider<SocialApi>.value(value: social),
        if (device case final device?) ...[
          Provider<DeviceStore>.value(value: device),
          Provider<DelegationApi>.value(value: delegation),
          Provider<LiveEventApi>.value(value: live),
        ],
      ],
      child: MaterialApp.router(theme: AppTheme.lightTheme(), routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('shows who can find it, who can vote, and the host and invited people',
      (tester) async {
    await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer')]);

    expect(find.text('Event e1'), findsOneWidget);
    expect(find.text(EventVisibility.public.description), findsOneWidget);
    expect(find.text(VoteLicense.everyone.description), findsOneWidget);
    expect(find.text('Invited people (2)'), findsOneWidget);
    expect(find.text('Host'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Invited'), findsOneWidget); // not the licence's
  });

  testWidgets('the host makes it private and votes invited-only', (tester) async {
    await pumpPage(tester, [member('u-1', 'owner')]);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invited').first);
    await tester.pumpAndSettle();

    expect(api.calls, ['visibility private', 'license invited_only']);
    expect(find.text(EventVisibility.private.description), findsOneWidget);
    expect(find.text(VoteLicense.invitedOnly.description), findsOneWidget);
  });

  testWidgets('a place-and-time licence is shown, and can be left for another', (tester) async {
    api.eventSummary = EventSummary(
      publicId: 'e1',
      name: 'Event e1',
      status: 'scheduled',
      createdAt: home.epoch,
      voteLicense: 'location_time',
    );
    await pumpPage(tester, [member('u-1', 'owner')]);
    expect(find.textContaining('Only people at the venue'), findsOneWidget);

    await tester.tap(find.text('Everyone'));
    await tester.pumpAndSettle();

    expect(api.calls, ['license everyone']);
  });

  testWidgets('an invited person sees everything but changes nothing', (tester) async {
    await pumpPage(tester, [member('u-9', 'owner'), member('u-1', 'viewer')]);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(api.calls, isEmpty);
    expect(find.text('Only its host can change these.'), findsOneWidget);
    expect(find.text('Invite'), findsNothing);
    expect(find.text('End event'), findsNothing);
  });

  testWidgets('an admin (set by no screen) is invited like the others: only the host changes',
      (tester) async {
    await pumpPage(tester, [member('u-9', 'owner'), member('u-1', 'admin')]);

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(api.calls, isEmpty);
    expect(find.text('Only its host can change these.'), findsOneWidget);
    expect(find.text('Invited · can manage'), findsNothing);
  });

  testWidgets('invite lists the friends not in it yet, and adds the one picked', (tester) async {
    social.friendList = const [
      FriendSummary(publicId: 'u-2', displayName: 'Already in'),
      FriendSummary(publicId: 'u-3', displayName: 'Trinity'),
    ];
    await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer')]);

    await tester.tap(find.text('Invite'));
    await tester.pumpAndSettle();
    expect(find.text('Already in'), findsNothing);
    await tester.tap(find.text('Trinity'));
    await tester.pumpAndSettle();

    expect(api.calls, ['invite u-3']);
    expect(find.text('Invited people (3)'), findsOneWidget);
  });

  testWidgets('a refused change says why', (tester) async {
    await pumpPage(tester, [member('u-1', 'owner')]);
    api.failure = const UnauthorizedError('permission denied');

    await tester.tap(find.text('Private'));
    await tester.pumpAndSettle();

    expect(find.text("You can't change this event."), findsOneWidget);
  });

  testWidgets('the host ends it after saying yes', (tester) async {
    await pumpPage(tester, [member('u-1', 'owner')]);

    await tester.tap(find.text('End event'));
    await tester.pumpAndSettle();
    expect(api.ended, isFalse, reason: 'asks first');
    await tester.tap(find.widgetWithText(FilledButton, 'End'));
    await tester.pumpAndSettle();

    expect(api.ended, isTrue);
    expect(find.text('events list'), findsOneWidget);
  });

  testWidgets('an ended event has no End button', (tester) async {
    api.eventSummary = home.event('e1', status: 'ended');
    await pumpPage(tester, [member('u-1', 'owner')]);

    expect(find.text('End event'), findsNothing);
  });

  testWidgets('an invited person opens their profile', (tester) async {
    await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer')]);

    await tester.tap(find.text('Name u-2'));
    await tester.pumpAndSettle();

    expect(find.text('profile u-2'), findsOneWidget);
  });

  group('Place & time', () {
    EventSummary timed({String license = 'everyone', EventVenue? venue}) => EventSummary(
          publicId: 'e1',
          name: 'Event e1',
          status: 'scheduled',
          createdAt: home.epoch,
          startsAt: DateTime.utc(2026, 10, 17, 18),
          endsAt: DateTime.utc(2026, 10, 17, 21),
          voteLicense: license,
          venue: venue,
        );

    testWidgets('the host places it on the page, saves, and the window is the event\'s hours',
        (tester) async {
      api.eventSummary = timed();
      positions.position = (latitude: 46.5374, longitude: 6.589);
      await pumpPage(tester, [member('u-1', 'owner')]);

      await tester.tap(find.text('Place & time'));
      await tester.pumpAndSettle();
      expect(api.placeAndTime, isNull, reason: 'nothing saved before Save');
      await tester.tap(find.text('Use my position'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1 km'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save the place'));
      await tester.pumpAndSettle();

      final sent = api.placeAndTime!;
      expect(sent.venue, (latitude: 46.5374, longitude: 6.589, radiusMeters: 1000));
      expect(sent.window, (start: '18:00', end: '21:00', timezone: 'UTC'));
      expect(find.textContaining('within 1 km of the venue'), findsOneWidget);
      expect(find.text('Save the place'), findsNothing, reason: 'saved');
    });

    testWidgets('coordinates can be typed, and nonsense is refused', (tester) async {
      api.eventSummary = timed();
      await pumpPage(tester, [member('u-1', 'owner')]);
      await tester.tap(find.text('Place & time'));
      await tester.pumpAndSettle();

      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '95');
      await tester.pump();
      expect(find.text('Latitude -90 to 90, longitude -180 to 180.'), findsOneWidget);
      expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save the place'))
              .onPressed,
          isNull);

      await tester.enterText(find.widgetWithText(TextField, 'Latitude'), '43.2965');
      await tester.enterText(find.widgetWithText(TextField, 'Longitude'), '5.3698');
      await tester.pump();
      await tester.tap(find.text('Save the place'));
      await tester.pumpAndSettle();

      expect(api.placeAndTime!.venue.latitude, 43.2965);
      expect(api.placeAndTime!.venue.radiusMeters, 500, reason: 'the default');
    });

    testWidgets('no position says so, and the venue shown can still be saved', (tester) async {
      api.eventSummary = timed();
      await pumpPage(tester, [member('u-1', 'owner')]);
      await tester.tap(find.text('Place & time'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use my position'));
      await tester.pumpAndSettle();
      expect(find.text('Your position is not available.'), findsOneWidget);
      await tester.tap(find.text('Save the place'));
      await tester.pumpAndSettle();

      expect(api.placeAndTime, isNotNull);
    });

    testWidgets('leaving Place & time before saving changes only the licence', (tester) async {
      api.eventSummary = timed();
      await pumpPage(tester, [member('u-1', 'owner')]);
      await tester.tap(find.text('Place & time'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Invited').first);
      await tester.pumpAndSettle();

      expect(api.placeAndTime, isNull);
      expect(api.calls, ['license invited_only']);
      expect(find.text('Latitude'), findsNothing);
    });

    testWidgets('an event with no times cannot use it', (tester) async {
      await pumpPage(tester, [member('u-1', 'owner')]);

      expect(find.text("Place & time needs the event's start and end times."), findsOneWidget);
      await tester.tap(find.text('Place & time'));
      await tester.pumpAndSettle();
      expect(find.text('Latitude'), findsNothing);
    });
  });

  group('the music control, on the invited people', () {
    // u-2 is invited and a friend; u-3 is invited, not a friend; Sarah is a
    // friend, not invited.
    const sarah = FriendSummary(publicId: 'sarah', displayName: 'Sarah');
    const u2 = FriendSummary(publicId: 'u-2', displayName: 'Name u-2');

    /// The switch on [name]'s row, if any.
    Finder switchOf(String name) => find.descendant(
          of: find.ancestor(of: find.text(name), matching: find.byType(ListTile)),
          matching: find.byType(Switch),
        );

    testWidgets('a switch on each invited friend only; on, it gives control on the device that plays',
        (tester) async {
      musicControl(speaker: 2);
      social.friendList = [sarah, u2];
      await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer'), member('u-3', 'viewer')]);

      expect(find.textContaining('on Laptop, the device that plays it'), findsOneWidget);
      expect(switchOf('Name u-2'), findsOneWidget);
      expect(switchOf('Name u-3'), findsNothing); // not a friend
      expect(switchOf('Name u-1 (you)'), findsNothing);
      expect(find.text('Sarah'), findsNothing); // not invited: invite her first

      await tester.tap(switchOf('Name u-2'));
      await tester.pumpAndSettle();

      expect(delegation.calls, contains('grant device-2 u-2 e1'));
      expect(tester.widget<Switch>(switchOf('Name u-2')).value, isTrue);
    });

    testWidgets('before the first play, the first friend switched on makes this device the speaker',
        (tester) async {
      musicControl();
      social.friendList = [u2];
      await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer')]);

      expect(find.textContaining('makes Pixel, this device, the one that does'), findsOneWidget);
      await tester.tap(switchOf('Name u-2'));
      await tester.pumpAndSettle();

      // The speaker first: without one the server lets only the host control,
      // whatever the licence.
      expect(
        delegation.calls.where((c) => c.startsWith('speaker') || c.startsWith('grant')),
        ['speaker e1 device-1', 'grant device-1 u-2 e1'],
      );
    });

    testWidgets('the switches stay after another setting changes', (tester) async {
      musicControl(speaker: 2);
      social.friendList = [u2];
      await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer')]);
      expect(switchOf('Name u-2'), findsOneWidget);

      await tester.tap(find.text('Private'));
      await tester.pumpAndSettle();

      expect(api.calls, contains('visibility private'));
      expect(switchOf('Name u-2'), findsOneWidget);
    });

    testWidgets('an invited person sees the people, with no switch', (tester) async {
      musicControl(speaker: 2);
      social.friendList = [const FriendSummary(publicId: 'u-9', displayName: 'Name u-9')];
      await pumpPage(tester, [member('u-9', 'owner'), member('u-1', 'viewer')]);

      expect(find.text('Name u-9'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('nor anyone on an ended event', (tester) async {
      musicControl(speaker: 2);
      social.friendList = [u2];
      api = FakeEventSettingsApi(home.event('e1', status: 'ended'));
      await pumpPage(tester, [member('u-1', 'owner'), member('u-2', 'viewer')]);

      expect(find.byType(Switch), findsNothing);
    });
  });
}
