import 'package:grpc/grpc.dart';
import 'package:app/core/network/backend_address.dart';
import 'package:app/globals/app_constants.dart';
import 'package:flutter/foundation.dart';
import 'package:app/gen/openapi_client/lib/api.dart';
import './grpc.dart';

typedef NetworkService = HttpService;

/// A concrete implementation of [RemoteService] managing a gRPC connection channel.
class HttpService implements RemoteService {
  /// The underlying OpenAPI client used to convey network calls.
  final ApiClient client;

  /// Private constructor to enforce initialization via [GrpcServiceFactory].
  HttpService._(this.client);

  /// Verifies connectivity to the remote endpoint.
  @override
  Future<bool> canConnect() async => true; // TO modify later
}

/// Factory responsible for creating, initializing, and verifying [GrpcService] instances.
class HttpServiceFactory implements RemoteServiceFactory<HttpService> {
  /// Asynchronously creates a [ClientChannel], instantiates [GrpcService], and verifies connectivity.
  static Future<HttpService> create() async {
    final client = _createClient();
    final service = HttpService._(client);
    await service.canConnect();
    return service;
  }

  /// Constructs the underlying [ClientChannel] using parameters configured in [AppConstants].
  static ApiClient _createClient() {
    final BackendAddress(:host, :port) = BackendAddress.current;
    final secureCredentials = AppConstants.backendSecureCredentials;

    final scheme = secureCredentials ? 'https' : 'http';
    final baseUrl = '$scheme://$host:$port';

    debugPrint('Try to connect to HTTP backend at $baseUrl');

    return ApiClient(basePath: baseUrl);
  }
}

// Notes ( a faire un jour ):
// 1. Test channel reconnection behavior when connectivity breaks.
// 2. Identify error codes thrown on channel failure and handle them gracefully.
// 3. Implement channel keep-alive options to prevent dropped connections.
// 4. Ensure production builds enforce secure TLS credentials.


/// Proto3 Default Values for Nullable Dart Primitives

extension NullableStringExtension on String? {
  /// Proto3 default for string: ''
  String get orEmpty => this ?? '';

  /// Custom fallback value
  String or(String defaultValue) => this ?? defaultValue;
}

extension NullableIntExtension on int? {
  /// Proto3 default for int32/int64: 0
  int get orZero => this ?? 0;

  /// Custom fallback value
  int or(int defaultValue) => this ?? defaultValue;
}

extension NullableDoubleExtension on double? {
  /// Proto3 default for float/double: 0.0
  double get orZero => this ?? 0.0;

  /// Custom fallback value
  double or(double defaultValue) => this ?? defaultValue;
}

extension NullableBoolExtension on bool? {
  /// Proto3 default for bool: false
  bool get orFalse => this ?? false;

  /// Custom fallback value
  bool or(bool defaultValue) => this ?? defaultValue;
}

extension NullableListExtension<T> on List<T>? {
  /// Proto3 default for repeated fields: []
  List<T> get orEmpty => this ?? const [];

  /// Custom fallback value
  List<T> or(List<T> defaultValue) => this ?? defaultValue;
}

extension NullableMapExtension<K, V> on Map<K, V>? {
  /// Proto3 default for map fields: {}
  Map<K, V> get orEmpty => this ?? const {};

  /// Custom fallback value
  Map<K, V> or(Map<K, V> defaultValue) => this ?? defaultValue;
}

/// Generic extension applicable to any type
extension NullableGenericExtension<T> on T? {
  /// Returns the instance or the provided default value
  T or(T defaultValue) => this ?? defaultValue;
}