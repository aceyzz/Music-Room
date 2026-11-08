import 'package:flutter/foundation.dart';
import 'package:app/core/search/query.dart';

/// Manages active query constraints and handles filtering for entity type [T].
class FilterController<T> {
  FilterController([Query<T>? initialQuery])
      : _queryNotifier = ValueNotifier<Query<T>?>(initialQuery);

  final ValueNotifier<Query<T>?> _queryNotifier;

  /// Exposes read-only listenable for UI builders.
  ValueListenable<Query<T>?> get queryListenable => _queryNotifier;

  /// Gets the current active query constraint.
  Query<T>? get query => _queryNotifier.value;

  /// Returns true if an active constraint is applied.
  bool get hasFilter => _queryNotifier.value != null;

  /// Updates the active constraint.
  void update(Query<T>? constraint) {
    if (_queryNotifier.value != constraint) {
      _queryNotifier.value = constraint;
    }
  }

  /// Clears the active constraint.
  void clear() {
    if (_queryNotifier.value != null) {
      _queryNotifier.value = null;
    }
  }

  /// Filters [items] using the active constraint.
  /// Returns the original list if no constraint is active.
  List<T> filter(List<T> items) {
    final constraint = _queryNotifier.value;
    if (constraint == null) return items;
    return items.where(constraint.satisfies).toList();
  }

  /// Disposes internal notifier.
  void dispose() {
    _queryNotifier.dispose();
  }
}
