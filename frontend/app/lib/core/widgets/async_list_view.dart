import 'package:flutter/material.dart';

import 'package:app/core/sources/source_state.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/section_placeholder.dart';

/// A reusable list view driven by a [ListState] with pull-to-refresh,
/// loading, error, empty, and infinite scroll (near-end) pagination handling.
class AsyncListView<T> extends StatelessWidget {
  final ListState<T> state;
  final List<T>? items;
  final String emptyMessage;
  final Future<void> Function() onRefresh;
  final Future<void> Function()? onRetry;
  final Future<void> Function()? onNearEnd;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final double placeholderHeight;
  final EdgeInsetsGeometry padding;
  final ScrollPhysics physics;
  final Key? refreshKey;

  const AsyncListView({
    super.key,
    required this.state,
    required this.items,
    required this.emptyMessage,
    required this.onRefresh,
    required this.itemBuilder,
    this.onRetry,
    this.onNearEnd,
    this.placeholderHeight = 240.0,
    this.padding = AppDimens.listBottomPadding,
    this.physics = const AlwaysScrollableScrollPhysics(),
    this.refreshKey,
  });

  @override
  Widget build(BuildContext context) {
    final items = this.items;
    final error = state.error;
    final retry = onRetry ?? onRefresh;

    final List<Widget> fallback;
    if (items == null) {
      fallback = [
        if (error != null)
          SectionPlaceholder.error(error, height: placeholderHeight, onRetry: retry)
        else
          SectionPlaceholder.loading(height: placeholderHeight),
      ];
    } else if (items.isEmpty && error == null) {
      fallback = [SectionPlaceholder.message(emptyMessage, height: placeholderHeight)];
    } else {
      fallback = const [];
    }

    final footer = <Widget>[
      if (items != null && state.isFetchingMore)
        const SectionPlaceholder.loading(height: 72)
      else if (items != null && error != null)
        SectionPlaceholder.error(error, height: 96, onRetry: retry),
    ];
    final rows = items ?? const [];

    return RefreshIndicator(
      key: refreshKey,
      onRefresh: onRefresh,
      child: ListView.builder(
        physics: physics,
        padding: padding,
        itemCount: fallback.length + rows.length + footer.length,
        itemBuilder: (context, i) {
          if (i < fallback.length) {
            return fallback[i];
          }
          final row = i - fallback.length;
          if (row < rows.length) {
            final nearEnd = onNearEnd;
            // One row asks for more, the fifth from the end, when it is
            // built; not each of the last five, and not while a page loads.
            if (nearEnd != null && !state.isFetchingMore && row == (rows.length - 5).clamp(0, rows.length - 1)) {
              WidgetsBinding.instance.addPostFrameCallback((_) => nearEnd());
            }
            return itemBuilder(context, rows[row], row);
          }
          return footer[row - rows.length];
        },
      ),
    );
  }
}
