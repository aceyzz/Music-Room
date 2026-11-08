// import 'package:flutter/foundation.dart';

// /// Represents the state of an asynchronous network operation.
// @immutable
// class NetworkState<T> {
//   /// The payload returned by a successful network request.
//   final T? data;

//   /// Indicates whether a network request is currently in progress.
//   final bool isLoading;

//   /// Error message returned if the network request fails.
//   final String? error;

//   /// Creates a [NetworkState] instance.
//   const NetworkState({this.data, this.isLoading = false, this.error});

//   /// Creates an uninitialized default state.
//   factory NetworkState.initial() => const NetworkState();

//   /// Creates a loading state, optionally retaining current [data] while re-fetching.
//   factory NetworkState.loading([T? currentData]) =>
//       NetworkState(data: currentData, isLoading: true);

//   /// Creates a successful state containing the fetched [data].
//   factory NetworkState.success(T data) =>
//       NetworkState(data: data, isLoading: false);

//   /// Creates a failure state containing an [error] message and optional cached [currentData].
//   factory NetworkState.failure(String error, [T? currentData]) =>
//       NetworkState(data: currentData, isLoading: false, error: error);
// }

// /// A [ValueNotifier] that manages and emits changes to a [NetworkState].
// class NetworkController<T> extends ValueNotifier<NetworkState<T>> {
//   /// Creates a [NetworkController] with an optional [initialState].
//   NetworkController() : super(NetworkState.initial());

//   /// Direct access to the current [NetworkState.data].
//   T? get data => value.data;

//   /// Direct access to [NetworkState.isLoading].
//   bool get isLoading => value.isLoading;

//   /// Direct access to [NetworkState.error].
//   String? get error => value.error;

//   /// Whether non-null data is currently available in [value].
//   bool get hasData => value.data != null;

//   /// Executes an asynchronous network call, automatically updating state
//   /// to loading, success, or failure.
//   Future<T?> execute(Future<T> Function() call) async {
//     value = NetworkState.loading(value.data);
//     try {
//       final result = await call();
//       value = NetworkState.success(result);
//       return result;
//     } catch (e) {
//       value = NetworkState.failure(e.toString(), value.data);
//       return null;
//     }
//   }

//   /// Resets the controller state back to [NetworkState.initial].
//   void reset() {
//     value = NetworkState.initial();
//   }
// }
