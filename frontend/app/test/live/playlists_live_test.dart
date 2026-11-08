// Runs the Playlists tab's "Create playlist" against a real backend:
// LibraryStore -> PlaylistGrpcSource -> AuthInterceptor -> PlaylistService,
// then reads the playlist back to check what the server stored.
//
// Opt-in, like auth_live_test.dart:
//
//   flutter test test/live --dart-define=LIVE_GRPC_HOST=localhost
@Tags(['live'])
library;

import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/playlist/library_playlist.dart';
import 'package:app/core/models/playlist/playlist_settings.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/music/playlist/data/playlist_source.dart';
import 'package:app/features/music/playlist/presentation/stores/library_store.dart';
import 'package:app/gen/music_room/v1/services/playlist_service.pbgrpc.dart';

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
      email: 'live-playlists-$stamp@example.test',
      password: 'live-password',
      displayName: 'liveplaylists$stamp',
    );
    user = (session.state.value as SignedIn).user;
  });

  tearDownAll(() async {
    if (_host.isNotEmpty) {
      await channel.shutdown();
    }
  });

  group('live playlists', skip: _host.isEmpty ? 'set --dart-define=LIVE_GRPC_HOST' : null, () {
    test('a created playlist is listed as yours and stored with its settings', () async {
      final store = LibraryStore(
        PlaylistGrpcSource(channel, interceptors),
        user.publicId,
        user.displayName,
      );
      await store.start();

      final created = await store.create(
        name: 'Live road trip',
        visibility: PlaylistVisibility.private,
        editLicense: EditLicense.invitedOnly,
      );
      expect(created.publicId, isNotEmpty);
      expect(created.name, 'Live road trip');
      expect(created.songCount, 0);
      expect(created.relation, PlaylistRelation.mine);
      expect(store.library.value.data!.first, created);

      final stored = await PlaylistServiceClient(channel, interceptors: interceptors).getPlaylist(
        GetPlaylistRequest(playlistPublicId: created.publicId, viewerPublicId: user.publicId),
      );
      expect(stored.playlist.name, 'Live road trip');
      expect(stored.playlist.visibility, 'private');
      expect(stored.playlist.editLicense, 'invited_only');
      store.stop();
    });
  });
}
