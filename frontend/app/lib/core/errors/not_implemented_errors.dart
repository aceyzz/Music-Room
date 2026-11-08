import './app_error.dart';

abstract class NotImplementedMessages {
  static const featureNotImplemented = 'This feature is not implemented yet.';
  static const needsOverride = 'Default implementation. Override this method before using it.';
  static const unsupportedType =
      'This type does not support this operation, but the method is included for interface conformance.';
  static const grpcEnpoint =
      "Endpoint not implemented: The server lacks a service implementation or method override for this gRPC request.";
  static const httpEndpoint =
      "Endpoint not served: The HTTP route or REST method is not handled or mapped by the server gateway.";
  static const websocketEvent =
      "Action not served: The requested event type is not supported or handled by the active WebSocket connection.";
}

class FeatureNotImplementedError extends NotImplementedError {
  const FeatureNotImplementedError({super.originalError, super.stackTrace})
      : super(NotImplementedMessages.featureNotImplemented);
}

class NeedsOverrideError extends NotImplementedError {
  const NeedsOverrideError({super.originalError, super.stackTrace})
      : super(NotImplementedMessages.needsOverride);
}

class UnsupportedTypeError extends NotImplementedError {
  const UnsupportedTypeError({super.originalError, super.stackTrace})
      : super(NotImplementedMessages.unsupportedType);
}

class GrpcEndpointNotImplemented extends NotImplementedError {
  const GrpcEndpointNotImplemented({super.originalError, super.stackTrace})
      : super(NotImplementedMessages.grpcEnpoint);
}

class HttpEndpointNotImplemented extends NotImplementedError {
  const HttpEndpointNotImplemented({super.originalError, super.stackTrace})
      : super(NotImplementedMessages.httpEndpoint);
}

class SocketEventNotImplemented extends NotImplementedError {
  const SocketEventNotImplemented({super.originalError, super.stackTrace})
      : super(NotImplementedMessages.websocketEvent);
}