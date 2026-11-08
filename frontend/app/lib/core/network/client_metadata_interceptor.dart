import 'package:grpc/grpc.dart';

import 'package:app/core/device/device_info.dart';

/// Adds `x-platform`, `x-device-model` and `x-app-version` to every call,
/// login included: subject V.6's platform, device and application version.
///
/// The backend copies them into each activity log row's `metadata`
/// (backend/internal/interceptor/activitylog.go). For a signed-in call the log
/// also names the session's device, bound by RegisterDevice, but the headers
/// are all a failed login or an expired token has to say what it ran on, so
/// they go on every call and not only the anonymous ones.
///
/// An empty value is left out rather than sent blank: the backend then records
/// the header as absent, which is what it is.
class ClientMetadataInterceptor extends ClientInterceptor {
  final Map<String, String> _headers;

  ClientMetadataInterceptor(DeviceInfo device)
      : _headers = {
          for (final (key, value) in [
            ('x-platform', device.platform),
            ('x-device-model', device.model),
            ('x-app-version', device.appVersion),
          ])
            if (value.isNotEmpty) key: value,
        };

  @override
  ResponseFuture<R> interceptUnary<Q, R>(
    ClientMethod<Q, R> method,
    Q request,
    CallOptions options,
    ClientUnaryInvoker<Q, R> invoker,
  ) =>
      invoker(method, request, options.mergedWith(CallOptions(metadata: _headers)));

  @override
  ResponseStream<R> interceptStreaming<Q, R>(
    ClientMethod<Q, R> method,
    Stream<Q> requests,
    CallOptions options,
    ClientStreamingInvoker<Q, R> invoker,
  ) =>
      invoker(method, requests, options.mergedWith(CallOptions(metadata: _headers)));
}
