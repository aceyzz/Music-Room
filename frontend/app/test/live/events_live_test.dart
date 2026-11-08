// Runs the Events tab's "Create event" against a real backend:
// MyEventsStore -> EventGrpcSource -> AuthInterceptor -> EventService, then
// lists the user's events and reads the event back to check its times.
//
// Opt-in, like auth_live_test.dart:
//
//   flutter test test/live --dart-define=LIVE_GRPC_HOST=localhost
@Tags(['live'])
library;

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/event/presentation/stores/my_events_store.dart';
import 'package:app/gen/music_room/v1/services/event_service.pbgrpc.dart';

import '../mocks/mock_flutter_secure_storage.dart';

const _host = String.fromEnvironment('LIVE_GRPC_HOST');
const _port = int.fromEnvironment('LIVE_GRPC_PORT', defaultValue: 50051);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientChannel channel;
  late AuthUser user;
  late List<ClientInterceptor> interceptors;

  setUpAll(() async {
    if (_host.isEmpty) {
      return;
    }
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    channel = ClientChannel(
      _host,
      port: _port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final credentials = SessionCredentials();
    interceptors = [AuthInterceptor(credentials)];
    final session = SessionStore(
      SessionRepository(
        api: AuthGrpcSource(channel, interceptors),
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    await session.register(
      email: 'live-events-$stamp@example.test',
      password: 'live-password',
      displayName: 'liveevents$stamp',
    );
    user = (session.state.value as SignedIn).user;
  });

  tearDownAll(() async {
    if (_host.isNotEmpty) {
      await channel.shutdown();
    }
  });

  group('live events', skip: _host.isEmpty ? 'set --dart-define=LIVE_GRPC_HOST' : null, () {
    // Whole seconds: the server stores unix seconds.
    final now =
        DateTime.fromMillisecondsSinceEpoch(DateTime.now().millisecondsSinceEpoch ~/ 1000 * 1000);

    test('an event starting now is created with its times and listed as Current', () async {
      final store = MyEventsStore(EventGrpcSource(channel, interceptors), user.publicId);
      await store.start();

      final created = await store.create(
        name: 'Live rooftop',
        description: 'Bring snacks',
        visibility: EventVisibility.private,
        voteLicense: VoteLicense.invitedOnly,
        startsAt: now.subtract(const Duration(minutes: 5)),
        endsAt: now.add(const Duration(hours: 2)),
      );
      expect(created.publicId, isNotEmpty);
      expect(created.visibility, EventVisibility.private);
      expect(created.startsAt, now.subtract(const Duration(minutes: 5)));
      expect(created.endsAt, now.add(const Duration(hours: 2)));
      expect(created.phaseAt(DateTime.now()), EventPhase.current);

      // A reload keeps it: the server lists the events the user hosts.
      await store.reload();
      final current = EventFilter.current.pick(store.events.value.data!, DateTime.now());
      expect(current.map((e) => e.publicId), contains(created.publicId));

      final stored = await EventServiceClient(channel, interceptors: interceptors).getMusicEvent(
        GetMusicEventRequest(publicId: created.publicId, viewerPublicId: user.publicId),
      );
      expect(stored.event.startsAt.toInt(), now.millisecondsSinceEpoch ~/ 1000 - 300);
      expect(stored.event.voteLicense, 'invited_only');
      store.stop();
    });

    test('the server refuses an event that is already over', () async {
      final store = MyEventsStore(EventGrpcSource(channel, interceptors), user.publicId);
      await expectLater(
        store.create(
          name: 'Too late',
          description: '',
          visibility: EventVisibility.public,
          voteLicense: VoteLicense.everyone,
          startsAt: now.subtract(const Duration(hours: 3)),
          endsAt: now.subtract(const Duration(hours: 1)),
        ),
        throwsA(isA<InvalidInputError>()),
      );
      store.stop();
    });
  });
}
