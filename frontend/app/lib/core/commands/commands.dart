import 'package:app/core/errors/not_implemented_errors.dart';

abstract class Command<Req, Res, ClientType> with CommandContext<Req, Res> {
  final Req request;
  const Command(this.request);
}

typedef CommandContextData = ({
  String command,
  String requestType,
  String responseType
});

/// Simple mixin for commands to capture context for logging and error reporting.
mixin CommandContext<TRequest, TResponse> {
  CommandContextData captureContext() => (
        command: runtimeType.toString(),
        requestType: TRequest.toString(),
        responseType: TResponse.toString()
      );
}

// =================================================================
//                      Remote Commands
// =================================================================

abstract class RemoteCommand<Req, Res, ClientType>
    extends Command<Req, Res, ClientType> {
  const RemoteCommand(super.request);
  Future<Res> call(ClientType client);

  Future<Res?> execute(ClientType client, Req request) =>
      throw const NeedsOverrideError();
}

abstract class RemoteStreamCommand<Req, Res, ClientType>
    extends Command<Req, Res, ClientType> {
  const RemoteStreamCommand(super.request);
  Stream<Res> call(ClientType client);
}

abstract class RemoteSyncCommand<Req, Res, ClientType>
    extends Command<Stream<Req>, Res, ClientType> {
  const RemoteSyncCommand(super.requestStream);

  Stream<Res> call(ClientType client, Stream<Req> actions);
}
