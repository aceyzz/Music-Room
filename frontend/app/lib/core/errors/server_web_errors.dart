
import 'app_error.dart';

/// 400 Bad Request
class BadRequestException extends ServerException {
  const BadRequestException(String message) : super(400, message);
}

/// 401 Unauthorized
class UnauthorizedException extends ServerException {
  const UnauthorizedException(String message) : super(401, message);
}

/// 403 Forbidden
class ForbiddenException extends ServerException {
  const ForbiddenException(String message) : super(403, message);
}

/// 404 Not Found
class NotFoundException extends ServerException {
  const NotFoundException(String message) : super(404, message);
}

/// 408 Request Timeout
class TimeoutException extends ServerException {
  const TimeoutException(String message) : super(408, message);
}

/// 429 Too Many Requests
class RateLimitException extends ServerException {
  const RateLimitException(String message) : super(429, message);
}

/// 500 / 502 / 503 Internal Server Error / Bad Gateway / Service Unavailable
class InternalServerException extends ServerException {
  const InternalServerException(String message) : super(500, message);
}
