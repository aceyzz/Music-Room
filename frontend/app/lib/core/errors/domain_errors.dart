import './app_error.dart';
import 'package:app/core/commands/commands.dart';

abstract class DomainErrorMessages {
  static const noResponse =
      '[{commandType}] Execution failed ({connectionType}) | '
      'Request: {requestType} -> Received: null (Expected: {responseType})';

  static const validationFailed = 'Validation failed for {field}: {reason}';
}

class NoResponseError extends DomainError {
  const NoResponseError(super.message, {super.originalError, super.stackTrace});

  factory NoResponseError.fromCommand(
    String connection,
    CommandContextData context, [
    Error? error,
    StackTrace? trace,
  ]) =>
      AppError.createFormatted(
        DomainErrorMessages.noResponse,
        {
          'connectionType': connection, 
          'commandType': context.command,
          'requestType': context.requestType,
          'responseType': context.responseType
        },
        NoResponseError.new,
        error,
        trace,
      );
}

class ValidationFailedError extends DomainError {
  const ValidationFailedError(
    super.message, {
    super.originalError,
    super.stackTrace,
  });

  factory ValidationFailedError.create(
    String field,
    String reason, [
    Error? error,
    StackTrace? trace,
  ]) =>
      AppError.createFormatted(
        DomainErrorMessages.validationFailed,
        {'field': field, 'reason': reason},
        ValidationFailedError.new,
        error,
        trace,
      );
}
