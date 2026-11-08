import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app/core/sources/source_state.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/section_placeholder.dart';

export 'package:app/core/widgets/section_placeholder.dart';

/// A titled block of the Home tab, with a "See all" link to the tab that
/// holds the rest when [onSeeAll] is set.
class HomeSection extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  final Widget child;

  const HomeSection({super.key, required this.title, required this.child, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppDimens.spacingM, 0, AppDimens.spacingXS, 10),
            child: Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
                if (onSeeAll case final onSeeAll?)
                  TextButton(onPressed: onSeeAll, child: const Text('See all')),
              ],
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// An asynchronous [HomeSection] that observes a [SourceState] and automatically
/// shows a loading placeholder or an error placeholder with retry before calling [builder].
class AsyncHomeSection<T> extends StatelessWidget {
  final String title;
  final VoidCallback? onSeeAll;
  final ValueListenable<SourceState<T>> listenable;
  final double height;
  final Future<void> Function() onRetry;
  final Widget Function(BuildContext context, T data) builder;

  const AsyncHomeSection({
    super.key,
    required this.title,
    this.onSeeAll,
    required this.listenable,
    required this.height,
    required this.onRetry,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return HomeSection(
      title: title,
      onSeeAll: onSeeAll,
      child: ValueListenableBuilder<SourceState<T>>(
        valueListenable: listenable,
        builder: (context, state, _) {
          if (state.data case final data?) {
            return builder(context, data);
          }
          if (state.error case final error?) {
            return SectionPlaceholder.error(
              error,
              height: height,
              onRetry: onRetry,
            );
          }
          return SectionPlaceholder.loading(height: height);
        },
      ),
    );
  }
}

