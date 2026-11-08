
import 'package:app/core/errors/not_implemented_errors.dart';

abstract interface class Source {}


/// Single data provider
abstract class DataSource<T> implements Source {}


/// Composite source from different DataSource provider
abstract class DomainSource<T, S, U, V> implements Source {
    // One-time-action, a regular HTTP call for example
  Future<List<T>> fetch() => throw const NeedsOverrideError();

  // Data stream in real time (WebSocket, gRPC, or local DB listener)
  Stream<List<S>> watch() => throw const NeedsOverrideError();

  // Data stream in real time (WebSocket, gRPC, or local DB listener)
  Stream<List<U>> synchronize(Stream<V> clientActions) => throw const NeedsOverrideError();

}
