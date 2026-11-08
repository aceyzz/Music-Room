// Runs what the Home tab loads against a real backend: HomeStore ->
// EventGrpcSource / UserGrpcSource / PlaylistGrpcSource -> AuthInterceptor ->
// EventService and UserService.
//
// Opt-in, like auth_live_test.dart:
//
//   flutter test test/live --dart-define=LIVE_GRPC_HOST=localhost
@Tags(['live'])
library;

import 'package:fixnum/fixnum.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/event/event_summary.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/event/data/event_source.dart';
import 'package:app/features/home/presentation/stores/home_store.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/gen/music_room/v1/services/event_service.pbgrpc.dart';
import 'package:app/gen/music_room/v1/services/user_service.pbgrpc.dart';

import '../mocks/mock_flutter_secure_storage.dart';

const _host = String.fromEnvironment('LIVE_GRPC_HOST');
const _port = int.fromEnvironment('LIVE_GRPC_PORT', defaultValue: 50051);

/// One signed-in account, with clients that carry its session.
class _Account {
  final AuthUser user;
  final List<ClientInterceptor> interceptors;

  _Account(this.user, this.interceptors);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ClientChannel channel;
  late _Account neo;
  late _Account trinity;

  Future<_Account> register(String name) async {
    final credentials = SessionCredentials();
    final interceptors = [AuthInterceptor(credentials)];
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
      email: 'live-home-$name-$stamp@example.test',
      password: 'live-password',
      displayName: '$name$stamp',
    );
    return _Account((session.state.value as SignedIn).user, interceptors);
  }

  HomeStore homeOf(_Account account) => HomeStore(
        EventGrpcSource(channel, account.interceptors),
        UserGrpcSource(channel, account.interceptors),
        PlaylistGrpcSource(channel, account.interceptors),
        account.user.publicId,
      );

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
    neo = await register('neo');
    trinity = await register('trinity');
  });

  tearDownAll(() async {
    if (_host.isNotEmpty) {
      await channel.shutdown();
    }
  });

  group('live home', skip: _host.isEmpty ? 'set --dart-define=LIVE_GRPC_HOST' : null, () {
    test('a new account has empty sections, and none fails', () async {
      final home = homeOf(neo);
      await home.start();

      expect(home.events.value.error, isNull);
      expect(home.events.value.data!.isEmpty, isTrue);
      expect(home.friends.value.data, isEmpty);
      expect(home.playlists.value.data, isEmpty); // no RPC yet
      home.stop();
    });

    test('a friend shows up once the request is accepted', () async {
      final neoUsers = UserServiceClient(channel, interceptors: neo.interceptors);
      final trinityUsers = UserServiceClient(channel, interceptors: trinity.interceptors);

      // The permission check reads OpenFGA, which learns about a new account
      // through the outbox a moment after it is created: retry briefly.
      SendFriendRequestResponse? sent;
      for (var attempt = 0; sent == null; attempt++) {
        try {
          sent = await neoUsers.sendFriendRequest(SendFriendRequestRequest(
            requesterPublicId: neo.user.publicId,
            addresseePublicId: trinity.user.publicId,
          ));
        } on GrpcError catch (e) {
          if (e.code != StatusCode.permissionDenied || attempt >= 20) {
            rethrow;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
      await trinityUsers.acceptFriendRequest(AcceptFriendRequestRequest(
        requestId: sent.request.id,
        addresseePublicId: trinity.user.publicId,
      ));

      final home = homeOf(neo);
      await home.reloadFriends();
      final friend = home.friends.value.data!.single;
      expect(friend.publicId, trinity.user.publicId);
      expect(friend.displayName, trinity.user.displayName);
      expect(friend.avatarUrl, isNull);
      home.stop();
    });

    test('a hosted event comes back upcoming, with its times', () async {
      final events = EventServiceClient(channel, interceptors: neo.interceptors);
      // Tomorrow, on whole seconds: what the server stores.
      final startsAt = DateTime.fromMillisecondsSinceEpoch(
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000 * 1000);
      final endsAt = startsAt.add(const Duration(hours: 3));
      final created = await events.createEvent(CreateEventRequest(
        hostPublicId: neo.user.publicId,
        name: 'Live home party',
        description: 'From the live test',
        startsAt: Int64(startsAt.millisecondsSinceEpoch ~/ 1000),
        endsAt: Int64(endsAt.millisecondsSinceEpoch ~/ 1000),
      ));

      final home = homeOf(neo);
      await home.reloadEvents();
      final timeline = home.events.value.data!;
      final event = timeline.upcoming.single;
      expect(event.publicId, created.event.publicId);
      expect(event.name, 'Live home party');
      expect(event.status, 'scheduled');
      expect(event.startsAt, startsAt);
      expect(event.endsAt, endsAt);
      expect(event.phaseAt(DateTime.now()), EventPhase.upcoming);
      home.stop();
    });
  });
}
