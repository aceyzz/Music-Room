import 'package:app/core/network/app_network.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/sources/source.dart';
import 'package:app/core/commands/command_executor.dart';

/// Abstract base class for gRPC data sources.
abstract class GrpcSource<T, ClientType> extends DataSource<T>
    with CommandExecutor<List<T>, ClientType> {
  final ClientChannel channel;

  /// Pass these to the generated client's constructor: they attach the
  /// session token (core/network/auth/auth_interceptor.dart).
  final List<ClientInterceptor> interceptors;

  GrpcSource(this.channel, this.interceptors);

  // ---------------------------- Factory ---------------------------------------------------

  /// Instantiates a [GrpcSource] subtype from [AppNetwork].
  static S create<S extends GrpcSource>(
    AppNetwork appNetwork,
    S Function(ClientChannel channel, List<ClientInterceptor> interceptors) sourceFactory,
  ) =>
      sourceFactory(appNetwork.grpcService.channel, appNetwork.grpcService.interceptors);
}
