import 'package:app/core/search/search.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Manages text-based query generation for entity type [T] via a [TextEditingController].
class TextSearchController<T> {
  final TextEditingController textController;
  final Query<T> fallbackQuery;
  final Query<T> Function(String text) queryBuilder;

  final ValueNotifier<Query<T>?> _queryNotifier;

  TextSearchController({
    required this.queryBuilder,
    Query<T>? fallback,
    TextEditingController? textEditingController,
  })  : fallbackQuery = fallback ?? All<T>(),
        textController = textEditingController ?? TextEditingController(),
        _queryNotifier = ValueNotifier<Query<T>?>(fallback ?? All<T>()) {
    textController.addListener(_onTextChanged);
  }

  /// Exposes read-only listenable for UI builders.
  ValueListenable<Query<T>?> get queryListenable => _queryNotifier;

  /// Gets the current active query constraint.
  Query<T>? get query => _queryNotifier.value;

  /// Updates the search state when text input changes.
  void _onTextChanged() {
    final text = textController.text;
    if (text.trim().isEmpty) {
      _queryNotifier.value = fallbackQuery;
    } else {
      _queryNotifier.value = queryBuilder(text);
    }
  }

  /// Filters [items] using the active constraint.
  List<T> filter(List<T> items) {
    final constraint = _queryNotifier.value;
    if (constraint == null) return items;
    return items.where(constraint.satisfies).toList();
  }

  /// Clears text input and resets query to the fallback query.
  void clear() {
    textController.clear();
  }

  /// Disposes internal text editing controller and query notifier.
  void dispose() {
    textController.removeListener(_onTextChanged);
    textController.dispose();
    _queryNotifier.dispose();
  }
}
