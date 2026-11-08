import 'package:flutter/material.dart';

/// Abstract widget that automatically listens to a [Listenable] and rebuilds.
abstract class AutoRebuildOn<T extends Listenable> extends StatelessWidget {
  const AutoRebuildOn({super.key});

  /// The [Listenable] object to watch for changes.
  T listenable(BuildContext context);

  /// Builds the widget subtree when [listenable] notifies changes.
  Widget buildWithListenable(BuildContext context, T listenable);

  @override
  Widget build(BuildContext context) {
    final targetListenable = listenable(context);
    return ListenableBuilder(
      listenable: targetListenable,
      builder: (context, _) => buildWithListenable(context, targetListenable),
    );
  }
}

/// Abstract widget that listens to multiple [Listenable] objects
/// and automatically rebuilds whenever any of them emit an update.
abstract class AutoRebuildOnAny extends StatelessWidget {
  const AutoRebuildOnAny({super.key});

  /// Provide the list of [Listenable] objects to watch.
  List<Listenable> listenables(BuildContext context);

  /// Builds the widget subtree when any listenable notifies changes.
  Widget buildWidget(BuildContext context);

  @override
  Widget build(BuildContext context) {
    final targets = listenables(context);

    return ListenableBuilder(
      listenable: Listenable.merge(targets),
      builder: (context, _) => buildWidget(context),
    );
  }
}
