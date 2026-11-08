import '../commands.dart';
import 'package:app/core/errors/error_mapper.dart';
import 'package:app/core/errors/domain_errors.dart';
import 'package:app/core/errors/not_implemented_errors.dart';

// -----------------------------------------------------------------------------
// HTTP COMMANDS
// -----------------------------------------------------------------------------

abstract class HttpCallCommand<Req, Res, ClientType> extends RemoteCommand<Req, Res, ClientType> {
  const HttpCallCommand(super.request);

  @override
  Future<Res> call(ClientType client) async {
    try {
      final response = await execute(client, request);

      // Create or handle errors based on the response received

      if (response == null) {
        final context = captureContext();
        throw NoResponseError.fromCommand('http', context);
      }
      return response;
    } catch (error, stackTrace) {
      throw ErrorMapper.from(error, stackTrace);
    }
  }
}

abstract class HttpWatchCommand<Req, Res, ClientType>
    extends RemoteStreamCommand<Req, Res, ClientType> {
  const HttpWatchCommand(super.request);

  Stream<Res> execute(ClientType client, Req request) => throw const NeedsOverrideError();

  @override
  Stream<Res> call(ClientType client) => execute(client, request);
}
