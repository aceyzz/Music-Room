import 'package:grpc/grpc.dart';
import 'package:app/core/device/device_info.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/network/client_metadata_interceptor.dart';
import 'package:app/core/network/backend_address.dart';
import 'package:app/globals/app_constants.dart';
import 'package:flutter/foundation.dart';

// --- Contracts ---

/// Base contract for remote network services supporting health checks.
abstract interface class RemoteService {
  Future<bool> canConnect();
}

/// Marker protocol interface for remote service creation.
abstract interface class RemoteServiceFactory<T extends RemoteService> {}

// --- Base Source ---

// /// Abstract base class for gRPC data sources.
// abstract class GrpcSource {
//   final ClientChannel channel;

//   GrpcSource(this.channel);

//   /// Generates gRPC call options with a Bearer authentication token.
//   CallOptions optionsWithAuth(String token) {
//     return CallOptions(metadata: {'Authorization': 'Bearer $token'});
//   }

//   /// Instantiates a [GrpcSource] subtype from [AppNetwork].
//   static T create<T extends GrpcSource>(
//     AppNetwork appNetwork,
//     T Function(ClientChannel channel) sourceFactory,
//   ) =>
//       sourceFactory(appNetwork.grpcService.channel);
// }

// --- Concrete Implementation & Factory ---

typedef NetworkService = GrpcService;

/// A concrete implementation of [RemoteService] managing a gRPC connection channel.
class GrpcService implements RemoteService {
  /// The underlying gRPC channel used to convey network calls.
  final ClientChannel channel;

  /// Interceptors every generated client must be built with.
  ///
  /// In grpc-dart interceptors belong to the client (`XxxServiceClient(channel,
  /// interceptors: ...)`), not to the channel, so a source that builds its
  /// client without these sends no session token. [GrpcSource.create] passes
  /// them for you.
  final List<ClientInterceptor> interceptors;

  /// Private constructor to enforce initialization via [GrpcServiceFactory].
  GrpcService._(this.channel, this.interceptors);

  /// Verifies connectivity to the remote endpoint.
  @override
  Future<bool> canConnect() async => true; // TO modify later
}

/// Factory responsible for creating, initializing, and verifying [GrpcService] instances.
class GrpcServiceFactory implements RemoteServiceFactory<GrpcService> {

  /// Asynchronously creates a [ClientChannel], instantiates [GrpcService], and verifies connectivity.
  ///
  /// Every call made through it carries the token held in [credentials], and
  /// this install's platform and app version for the backend's activity logs.
  static Future<GrpcService> create(SessionCredentials credentials, DeviceInfo device) async {
    final channel = _createChannel();
    final service = GrpcService._(channel, [
      ClientMetadataInterceptor(device),
      AuthInterceptor(credentials),
    ]);
    await service.canConnect();
    return service;
  }

  /// Constructs the underlying [ClientChannel] to [BackendAddress.current].
  static ClientChannel _createChannel() {
    final BackendAddress(:host, :port) = BackendAddress.current;
    const secureCredentials = AppConstants.backendSecureCredentials;

    debugPrint('Try to connect to $host:$port');

    const options = ChannelOptions(
      credentials: secureCredentials
          ? ChannelCredentials.secure()
          : ChannelCredentials.insecure(),
    );

    return ClientChannel(host, port: port, options: options);
  }
}

// Notes ( a faire un jour ):
// 1. Test channel reconnection behavior when connectivity breaks.
// 2. Identify error codes thrown on channel failure and handle them gracefully.
// 3. Implement channel keep-alive options to prevent dropped connections.
// 4. Ensure production builds enforce secure TLS credentials.
