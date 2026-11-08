// import 'package:flutter/foundation.dart';
// import 'package:grpc/grpc.dart';

// import 'package:app/core/commands/commands.dart';
// import 'package:app/core/controllers/network_controller.dart';

// /// A specialized [ValueNotifier] that manages network state while executing
// /// commands against a specific data source type [Source].
// ///
// /// Generic parameters:
// /// - [Source]: The type of backend data source required by commands.
// /// - [T]: The base state response payload type managed by this controller.
// class CommandController<Source, T> extends ValueNotifier<NetworkState<T>> {
//   /// The underlying data source used to execute commands.
//   final Source source;

//   /// Creates a [CommandController] bound to the given [source].
//   CommandController(this.source, [NetworkState<T>? initialState])
//       : super(initialState ?? NetworkState.initial());

//   /// Direct access to [NetworkState.data].
//   T? get data => value.data;

//   /// Direct access to [NetworkState.isLoading].
//   bool get isLoading => value.isLoading;

//   /// Direct access to [NetworkState.error].
//   String? get error => value.error;

//   /// Whether non-null data is currently available in [value].
//   bool get hasData => value.data != null;

//   /// Executes a [command] targeting [source], automatically updating state to
//   /// loading, success, or failure.
//   ///
//   /// Type parameters:
//   /// - [Req]: The request parameter type expected by the command.
//   /// - [Res]: The gRPC response type produced by the command (must extend [T]).
//   Future<Res?> run<Req, Res extends T>(
//     Command<Req, Res, Source> command,
//   ) async {
//     value = NetworkState.loading(value.data);
//     try {
//       final ResponseFuture<Res> future = command(source);
//       final result = await future;
//       value = NetworkState.success(result as T);
//       return result;
//     } catch (e) {
//       value = NetworkState.failure(e.toString(), value.data);
//       return null;
//     }
//   }
// }
