import './commands.dart';
import 'package:app/core/errors/error_mapper.dart';

mixin CommandExecutor<T, ClientType> {
  ClientType get client;

  // 1. Handles one-time unary requests (Future)
  Future<T> execute<Req, Res>(
    RemoteCommand<Req, Res, ClientType> command,
    Future<T> Function(Res) extractResponse,
  ) async {
    try {
      final response = await command(client);
      return await extractResponse(response);
    } catch (error, stackTrace) {
      throw ErrorMapper.from(error, stackTrace);
    }
  }

  // 2. Handles continuous streams (Stream)
  Stream<T> executeStream<Req, Res>(
    RemoteStreamCommand<Req, Res, ClientType> command,
    T Function(Res) extractResponse,
  ) {
    return command(client)
        .map(extractResponse)
        .handleError((error, stackTrace) {
      throw ErrorMapper.from(error, stackTrace);
    });
  }

  // 3. Bidirectional Streaming (Stream in, Stream out)
  Stream<T> executeBiStream<Req, Res>(
    RemoteSyncCommand<Req, Res, ClientType> command,
    Stream<Req> requests,
    T Function(Res) extractResponse,
  ) {
    return command(client, requests)
        .map(extractResponse)
        .handleError((error, stackTrace) {
      throw ErrorMapper.from(error, stackTrace);
    });
  }
}
