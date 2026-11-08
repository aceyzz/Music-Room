import 'package:app/core/errors/app_error.dart';
import 'package:app/core/errors/not_implemented_errors.dart';
import 'package:grpc/grpc.dart';
import 'server_web_errors.dart';

class ErrorMapper {
  static AppError from(Object error, [StackTrace? stackTrace]) {
    // Already mapped by an inner layer (RpcCallCommand maps GrpcError, and
    // CommandExecutor maps again on the way out). Re-mapping would turn every
    // typed error into UnknownError.
    if (error is AppError) {
      return error;
    }
    if (error is GrpcError) {
      return fromGrpc(error, stackTrace);
    }

    // Example using standard Dart exceptions.
    // Replace these checks with gRPC (GrpcError) or Dio (DioException) checks if applicable.

    if (error is FormatException) {
      return UnknownError('Data parsing failed', originalError: error, stackTrace: stackTrace);
    }

    // Simulate catching a specific server exception
    if (error.toString().contains('SocketException')) {
      return NetworkError('No internet connection', originalError: error, stackTrace: stackTrace);
    }

    if (error.toString().contains('401')) {
      return UnauthorizedError('Session expired. Please log in again.',
          originalError: error, stackTrace: stackTrace);
    }

    return UnknownError('An unexpected error occurred',
        originalError: error, stackTrace: stackTrace);
  }

  static AppError fromGrpc(GrpcError error, [StackTrace? stackTrace]) {
    // Utility helper to build the final display message
    String buildMessage(String fallback) {
      if (error.message != null && error.message!.isNotEmpty) {
        return '$fallback: ${error.message}';
      }
      return fallback;
    }

    switch (error.code) {
      case StatusCode.cancelled:
        return NetworkError(
          buildMessage('Request was cancelled'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.invalidArgument:
      case StatusCode.outOfRange:
        return InvalidInputError(
          buildMessage('Invalid argument provided'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.deadlineExceeded:
        return NetworkError(
          buildMessage('Request timed out'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.notFound:
        return NotFoundError(
          buildMessage('Requested resource not found'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.permissionDenied:
        return UnauthorizedError(
          buildMessage('Permission denied'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.unauthenticated:
        return UnauthorizedError(
          buildMessage('Authentication required'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.unimplemented:
        return NotImplementedError(
          buildMessage('Endpoint not implemented on server'),
          originalError: error,
          stackTrace: stackTrace
        );

      case StatusCode.internal:
      case StatusCode.dataLoss:
        return ServerError(
          buildMessage('Internal server error'),
          error.code,
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.unavailable:
        return NetworkError(
          buildMessage('Service unavailable or network disconnected'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.alreadyExists:
        return ConflictError(
          buildMessage('Already exists'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.failedPrecondition:
        return PreconditionFailedError(
          buildMessage('Operation not allowed in the current state'),
          originalError: error,
          stackTrace: stackTrace,
        );

      case StatusCode.ok:
      case StatusCode.unknown:
      case StatusCode.resourceExhausted:
      case StatusCode.aborted:
      default:
        return UnknownError(
          buildMessage('An unexpected gRPC error occurred'),
          originalError: error,
          stackTrace: stackTrace,
        );
    }
  }

  /// Maps WebSocket/HTTP status codes and messages into domain exceptions.
  static AppError fromServerError(int statusCode, String? errorMessage, String? connection) {
    final message = errorMessage ?? 'An unknown server error occurred.';

    switch (statusCode) {
      case 400:
        return BadRequestException(message);
      case 401:
        return UnauthorizedException(message);
      case 403:
        return ForbiddenException(message);
      case 404:
        return NotFoundException(message);
      case 408:
        return TimeoutException(message);
      case 429:
        return RateLimitException(message);
      case 500:
      case 501:
        if (connection == null) {
          // to change later
          return HttpEndpointNotImplemented();
        }
        return connection.contains('websocket')
            ? SocketEventNotImplemented()
            : HttpEndpointNotImplemented();
      case 502:
      case 503:
        return InternalServerException(message);
      default:
        return ServerException(statusCode, message);
    }
  }
}
