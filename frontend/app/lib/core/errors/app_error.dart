typedef ErrorConstructor<T extends AppError> = T Function(
  String message, {
  Object? originalError,
  StackTrace? stackTrace,
});

sealed class AppError implements Exception {
  final String message;
  final Object? originalError;
  final StackTrace? stackTrace;

  const AppError(this.message, {this.originalError, this.stackTrace});

  /// A helper method for subclasses to safely format lazy messages.
  static T createLazy<T extends AppError>(
    String Function() messageBuilder,
    ErrorConstructor<T> constructor, [
    Object? originalError,
    StackTrace? stackTrace,
  ]) {
    // The string builder closure only executes right here,
    // saving CPU cycles if the error context is heavy or unused elsewhere.
    final evaluatedMessage = messageBuilder();
    return constructor(evaluatedMessage, originalError: originalError, stackTrace: stackTrace);
  }

  static String formatMessage(String template, Map<String, String> variables) {
    var result = template;
    for (final entry in variables.entries) {
      result = result.replaceAll('{${entry.key}}', entry.value);
    }
    return result;
  }

  /// Base helper to eliminate createLazy + formatMessage boilerplate
  static T createFormatted<T extends AppError>(
    String template,
    Map<String, String> placeholders,
    ErrorConstructor<T> constructor,
    Error? originalError,
    StackTrace? stackTrace,
  ) {
    return AppError.createLazy(
      () => AppError.formatMessage(template, placeholders),
      constructor,
      originalError,
      stackTrace,
    );
  }
}

class NetworkError extends AppError {
  const NetworkError(super.message, {super.originalError, super.stackTrace});
}

class ServerError extends AppError {
  final int statusCode;
  const ServerError(super.message, this.statusCode,
      {super.originalError, super.stackTrace});
}

class UnauthorizedError extends AppError {
  const UnauthorizedError(super.message,
      {super.originalError, super.stackTrace});
}

/// The server rejected the request's content (gRPC `INVALID_ARGUMENT`).
class InvalidInputError extends AppError {
  const InvalidInputError(super.message, {super.originalError, super.stackTrace});
}

/// The thing being created already exists (gRPC `ALREADY_EXISTS`).
class ConflictError extends AppError {
  const ConflictError(super.message, {super.originalError, super.stackTrace});
}

/// The thing asked for does not exist, or the caller may not know it does
/// (gRPC `NOT_FOUND`: the server folds "hidden from you" into it, e.g. a
/// profile once a block exists).
class NotFoundError extends AppError {
  const NotFoundError(super.message, {super.originalError, super.stackTrace});
}

/// The request is valid but the current state forbids it (gRPC `FAILED_PRECONDITION`).
class PreconditionFailedError extends AppError {
  const PreconditionFailedError(super.message, {super.originalError, super.stackTrace});
}

abstract class DomainError extends AppError {
  const DomainError(super.message, {super.originalError, super.stackTrace});
}

class UnknownError extends AppError {
  const UnknownError(super.message, {super.originalError, super.stackTrace});
}

class NotImplementedError extends AppError {
  const NotImplementedError(super.message,
      {super.originalError, super.stackTrace});
}


/// Base class for all server-related errors.
/// Base class for all server-related errors.
class ServerException extends AppError {
  final int statusCode;

  const ServerException(
    this.statusCode,
    super.message, {
    super.originalError,
    super.stackTrace,
  });

  @override
  String toString() => 'ServerException [$statusCode]: $message';
}
