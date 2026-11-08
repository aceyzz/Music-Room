import 'package:flutter/foundation.dart';
import 'package:grpc/grpc.dart';

import '../commands.dart';
import 'package:app/core/errors/error_mapper.dart';
import 'package:app/core/errors/domain_errors.dart';
import 'package:app/core/errors/not_implemented_errors.dart';

// -----------------------------------------------------------------------------
// RPC (gRPC) COMMANDS
// -----------------------------------------------------------------------------

abstract class RpcCallCommand<Req, Res, ClientType> extends RemoteCommand<Req, Res, ClientType> {
  const RpcCallCommand(super.request);

  @override
  Future<Res> call(ClientType client) async {
    try {
      final response = await execute(client, request);

      if (response == null) {
        final context = captureContext();
        throw NoResponseError.fromCommand('grpc', context);
      }
      return response;
    } on GrpcError catch (error, stackTrace) {
      debugPrint("A grpc error was thrown after a grpc command: $error");
      throw ErrorMapper.fromGrpc(error, stackTrace);
    } catch (error, stackTrace) {
      debugPrint("An unknown error was thrown after a from a grpc command: $error");
      throw ErrorMapper.from(error, stackTrace);
    }
  }
}

abstract class RpcWatchCommand<Req, Res, ClientType>
    extends RemoteStreamCommand<Req, Res, ClientType> {
  const RpcWatchCommand(super.request);

  Stream<Res> execute(ClientType client, Req request) => throw const NeedsOverrideError();

  /// The stream's errors come out as AppErrors, like RpcCallCommand's.
  @override
  Stream<Res> call(ClientType client) => execute(client, request).handleError(
        (Object error, StackTrace stackTrace) => throw error is GrpcError
            ? ErrorMapper.fromGrpc(error, stackTrace)
            : ErrorMapper.from(error, stackTrace),
      );
}

class RpcSyncCommand<Req, Res, ClientType> extends RemoteSyncCommand<Req, Res, ClientType> {
  const RpcSyncCommand(super.requestStream);

  Stream<Res> execute(ClientType client, Stream<Req> actions) => throw const NeedsOverrideError();

  @override
  Stream<Res> call(ClientType client, Stream<Req> actions) => execute(client, actions);
}
