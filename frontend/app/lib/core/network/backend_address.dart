import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/globals/app_constants.dart';

/// Where the backend is: the gRPC channel (grpc.dart), the REST client
/// (http.dart) and the images (AppConstants.mediaUrl) all read [current].
///
/// The build's `--dart-define` values (AppConstants) are the default; one the
/// user saved on the sign-in page ("Server", shared_preferences) wins over
/// them, so one APK reaches any machine. Read once, by [load] before
/// AppNetwork.connect(): the channels are built at start-up, so a change
/// applies on the next start.
class BackendAddress {
  final String host;

  /// gRPC: what the app talks.
  final int port;

  /// The HTTP server: images (`/media/`), the REST gateway, the OAuth page.
  final int httpPort;

  const BackendAddress({required this.host, required this.port, required this.httpPort});

  /// The build's own, from `--dart-define`.
  static const fromBuild = BackendAddress(
    host: AppConstants.backendHost,
    port: AppConstants.backendPort,
    httpPort: AppConstants.backendHttpPort,
  );

  /// The address in use, [fromBuild] until [load] reads a saved one.
  static BackendAddress current = fromBuild;

  static const _hostKey = 'backend.host';
  static const _portKey = 'backend.port';
  static const _httpPortKey = 'backend.httpPort';

  /// Reads the saved address into [current]; the build's when none is saved.
  /// Never throws: storage that cannot be read leaves the build's.
  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final host = prefs.getString(_hostKey);
      current = host == null || host.isEmpty
          ? fromBuild
          : BackendAddress(
              host: host,
              port: prefs.getInt(_portKey) ?? fromBuild.port,
              httpPort: prefs.getInt(_httpPortKey) ?? fromBuild.httpPort,
            );
    } catch (_) {
      current = fromBuild;
    }
  }

  /// Saves [address] for the next start; the build's own forgets any saved.
  static Future<void> save(BackendAddress address) async {
    final prefs = await SharedPreferences.getInstance();
    if (address == fromBuild) {
      await Future.wait([prefs.remove(_hostKey), prefs.remove(_portKey), prefs.remove(_httpPortKey)]);
      return;
    }
    await Future.wait([
      prefs.setString(_hostKey, address.host),
      prefs.setInt(_portKey, address.port),
      prefs.setInt(_httpPortKey, address.httpPort),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is BackendAddress && other.host == host && other.port == port && other.httpPort == httpPort;

  @override
  int get hashCode => Object.hash(host, port, httpPort);

  @override
  String toString() => '$host:$port';
}
