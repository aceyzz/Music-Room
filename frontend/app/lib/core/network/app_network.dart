import 'package:app/core/device/device_info.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/network/grpc.dart';
import 'package:app/core/network/http.dart';

/// Manages network service lifecycles and verifies connectivity across the application.
///
/// [AppNetwork] initializes network services when the application enters the foreground,
/// enabling early detection of server connection issues and offline states.
class AppNetwork {
  /// The underlying gRPC service instance managed by this network context.
  final GrpcService grpcService;
  final HttpService httpService;

  /// The session token attached to every gRPC call. Written by the auth feature.
  final SessionCredentials credentials;

  /// Private constructor to enforce initialization through [connect].
  AppNetwork._(this.grpcService, this.httpService, this.credentials);

  /// Asynchronously initializes network services and verifies server connection.
  ///
  /// Call this method when the application starts or comes into view.
  ///
  /// [device] is what every call reports about this install (main.dart loads
  /// it first, see [DeviceInfo.load]); without it, the model is left out.
  static Future<AppNetwork> connect({DeviceInfo? device}) async {
    final credentials = SessionCredentials();
    final grpcService =
        await GrpcServiceFactory.create(credentials, device ?? DeviceInfo.fallback());
    final httpService = await HttpServiceFactory.create();
    return AppNetwork._(grpcService, httpService, credentials);
  }
}
