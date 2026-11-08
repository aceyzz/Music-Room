import 'package:grpc/grpc.dart';

import 'session_credentials.dart';

/// Attaches `authorization: Bearer <token>` to every unary call, and reports
/// an `UNAUTHENTICATED` answer to [SessionCredentials] so the app can sign out.
///
/// The server's interceptor requires the header on every RPC except the three
/// that create a session (backend/internal/interceptor/policy.go). Those three
/// get no header, and their `UNAUTHENTICATED` (a wrong password) is not a dead
/// session, so it is not reported.
///
/// Streams (the Watch RPCs) carry the same header. Their `UNAUTHENTICATED` is
/// not reported: the response stream can only be listened to once, by its
/// caller, and the next unary call reports a dead session anyway.
class AuthInterceptor extends ClientInterceptor {
  final SessionCredentials credentials;

  AuthInterceptor(this.credentials);

  static const _anonymousMethods = {
    '/music_room.v1.AuthService/Register',
    '/music_room.v1.AuthService/Login',
    '/music_room.v1.AuthService/OAuthLogin',
    // Public on the server too (interceptor/policy.go): a stale token here
    // must not turn a reset into an UNAUTHENTICATED "session ended".
    '/music_room.v1.AuthService/RequestPasswordReset',
    '/music_room.v1.AuthService/ResetPassword',
  };

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) {
    final token = credentials.token;
    if (token == null || _anonymousMethods.contains(method.path)) {
      return invoker(method, request, options);
    }

    final response = invoker(
      method,
      request,
      options.mergedWith(CallOptions(metadata: {'authorization': 'Bearer $token'})),
    );

    // A side listener: the caller still receives the error from `response`
    // itself. onError returns normally, so this derived future never surfaces
    // as an unhandled error.
    response.then<void>((_) {}, onError: (Object error) {
      if (error is GrpcError && error.code == StatusCode.unauthenticated) {
        credentials.reject(token);
      }
    });
    return response;
  }

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) {
    final token = credentials.token;
    if (token == null) {
      return invoker(method, requests, options);
    }
    return invoker(
      method,
      requests,
      options.mergedWith(CallOptions(metadata: {'authorization': 'Bearer $token'})),
    );
  }
}
