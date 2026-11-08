import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// The search box at the top of a list page (public playlists, people), with
/// a clear button once something is typed.
///
/// It only reports text: waiting for typing to pause before searching is the
/// store's job (LibraryStore.search, FriendsStore.search), so clearing calls
/// [onChanged] with '' like any other edit.
class SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final String hintText;

  /// Opens the keyboard on the field as soon as it shows: for a sheet opened
  /// only to search.
  final bool autofocus;
  final EdgeInsetsGeometry padding;

  const SearchField({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.hintText,
    this.autofocus = false,
    this.padding = const EdgeInsets.fromLTRB(
      AppDimens.spacingM,
      0,
      AppDimens.spacingM,
      AppDimens.spacingXS,
    ),
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        autofocus: autofocus,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: const Icon(Icons.search),
          border: const OutlineInputBorder(),
          isDense: true,
          // Rebuilt with the text, so the clear button shows only when there
          // is something to clear.
          suffixIcon: ListenableBuilder(
            listenable: controller,
            builder: (context, _) => controller.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      controller.clear();
                      onChanged('');
                    },
                  ),
          ),
        ),
      ),
    );
  }
}
