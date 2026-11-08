import 'package:flutter/material.dart';

/// The row of pills at the top of the Playlists and Events tabs, one per
/// value of [values], [selected] highlighted. Scrolls sideways when the pills
/// do not fit. What a tap does is the page's call (both pages navigate).
class FilterPills<T> extends StatelessWidget {
  final List<T> values;
  final T selected;
  final String Function(T value) label;
  final ValueChanged<T> onTap;

  const FilterPills({
    super.key,
    required this.values,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: values.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final value = values[i];
          return ChoiceChip(
            label: Text(label(value)),
            selected: value == selected,
            showCheckmark: false,
            onSelected: (_) => onTap(value),
          );
        },
      ),
    );
  }
}
