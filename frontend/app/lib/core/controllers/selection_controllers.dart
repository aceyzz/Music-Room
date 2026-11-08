import 'package:flutter/foundation.dart';

class SelectionController<ID extends Object, T extends Object> {
  SelectionController({ID? initialID}) : _selectedID = ValueNotifier<ID?>(initialID);

  /// Reactive notifier holding the actual selected item instance [T?].
  final ValueNotifier<ID?> _selectedID;

  /// Gets the currently selected ID
  ValueNotifier<ID?> get selectedId => _selectedID;

  /// Returns true if an item is currently selected
  bool get hasSelection => _selectedID.value != null;

  /// Selects a specific ID
  void select(ID id) {
    if (_selectedID.value != id) {
      _selectedID.value = id;
    }
  }

  /// Toggles selection for a given ID
  void toggle(ID id) {
    if (_selectedID.value == id) {
      clear();
    } else {
      select(id);
    }
  }

  /// Clears the current selection
  void clear() {
    if (_selectedID.value != null) {
      _selectedID.value = null;
    }
  }

  /// Checks if a specific ID is selected
  bool isSelected(ID id) => _selectedID.value == id;

  /// Utility to resolve the actual item instance from a RepositoryController's state list/map
  T? resolveSelectedItem(Iterable<T>? items, ID Function(T item) idExtractor) {
    if (_selectedID.value == null || items == null) return null;
    try {
      return items.firstWhere((item) => idExtractor(item) == _selectedID.value);
    } catch (_) {
      return null;
    }
  }

  /// Disposes internal value notifier.
  void dispose() {
    _selectedID.dispose();
  }
}

class MultiSelectionController<ID extends Object, T extends Object> {
  MultiSelectionController({Set<ID>? initialSelection})
      : _selectedIDs = ValueNotifier<Set<ID>>(
          Set.unmodifiable(initialSelection ?? {}),
        );

  /// Private reactive notifier holding the set of selected IDs.
  final ValueNotifier<Set<ID>> _selectedIDs;

  /// Exposes the read-only listenable for UI subscriptions.
  ValueListenable<Set<ID>> get selectedIdsListenable => _selectedIDs;

  /// Gets the current set of selected IDs.
  Set<ID> get selectedIds => _selectedIDs.value;

  /// Returns true if at least one item is selected.
  bool get hasSelection => _selectedIDs.value.isNotEmpty;

  /// Checks if a specific ID is currently selected.
  bool isSelected(ID id) => _selectedIDs.value.contains(id);

  /// Adds a specific ID to the selection set.
  void select(ID id) {
    if (!_selectedIDs.value.contains(id)) {
      _selectedIDs.value = Set.unmodifiable({..._selectedIDs.value, id});
    }
  }

  /// Removes a specific ID from the selection set.
  void deselect(ID id) {
    if (_selectedIDs.value.contains(id)) {
      final updated = Set<ID>.from(_selectedIDs.value)..remove(id);
      _selectedIDs.value = Set.unmodifiable(updated);
    }
  }

  /// Toggles selection for a given ID.
  void toggle(ID id) {
    if (isSelected(id)) {
      deselect(id);
    } else {
      select(id);
    }
  }

  /// Clears all current selections.
  void clear() {
    if (_selectedIDs.value.isNotEmpty) {
      _selectedIDs.value = const {};
    }
  }

  /// Utility to resolve all selected item instances from a collection.
  List<T> resolveSelectedItems(
    Iterable<T>? items,
    ID Function(T item) idExtractor,
  ) {
    if (_selectedIDs.value.isEmpty || items == null) return const [];
    return items.where((item) => _selectedIDs.value.contains(idExtractor(item))).toList();
  }

  /// Disposes internal value notifier.
  void dispose() {
    _selectedIDs.dispose();
  }
}
