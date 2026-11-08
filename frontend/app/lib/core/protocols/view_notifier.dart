// import 'package:flutter/material.dart';

// mixin ViewNotifier<T extends StatefulWidget> on State<T> {
//   // Keep track of active subscriptions or listenables for automatic cleanup
//   final List<Listenable> _registeredListenables = [];

//   /// Registers any [Listenable] (ValueNotifier, CommandController, SearchController)
//   /// and automatically triggers [setState] when it changes.
//   void listenTo(Listenable listenable) {
//     listenable.addListener(_handleChange);
//     _registeredListenables.add(listenable);
//   }

//   @protected
//   void _handleChange() {
//     if (mounted) {
//       setState(() {});
//     }
//   }

//   @override
//   void dispose() {
//     // Automatically clean up all listeners to prevent memory leaks
//     for (final listenable in _registeredListenables) {
//       listenable.removeListener(_handleChange);
//     }
//     _registeredListenables.clear();
//     super.dispose();
//   }
// }