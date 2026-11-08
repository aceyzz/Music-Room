abstract class Store {}


// import 'package:app/core/network/app_network.dart';
// import 'package:app/core/network/grpc.dart';

// /// An abstract base class for state-managing stores bound to a data source [S].
// ///
// /// A [Store] coordinates interactions between data sources (such as gRPC, REST,
// /// or local databases) and presentation logic or UI state controllers.
// ///
// /// Generic type parameter [S] represents the specific source contract or class.
// abstract class Store<S> {
//   /// The underlying data source instance used by this store.
//   final S source;

//   /// Creates a [Store] instance with the provided [source].
//   Store(this.source);

//   /// Centralized factory that instantiates any [Store] subtype [T] given a
//   /// [GrpcSource] subtype [S] and a constructor tear-off.
//   ///
//   /// This pattern simplifies dependency injection and decoupling during store setup.
//   ///
//   /// Example:
//   /// ```dart
//   /// final musicStore = Store.create(
//   ///   grpcMusicSource,
//   ///   MusicStore.new,
//   /// );
//   /// ```
//   ///
//   /// - [source]: The [GrpcSource] instance to pass to the store.
//   /// - [factory]: A factory function or constructor tear-off (e.g., `MusicStore.new`)
//   ///   that accepts [source] and returns an instance of [T].
//   static T create<S extends GrpcSource, T extends Store<S>>(
//     S source,
//     T Function(S) factory,
//   ) =>
//       factory(source);


//   static T from<S extends GrpcSource, T extends Store<S>>(
//     AppNetwork appNetwork,
//     S Function(AppNetwork) sourceFactory,
//     T Function(S) factory,
//   ) =>
//       factory(sourceFactory(appNetwork));
// }
