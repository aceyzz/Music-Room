import 'package:flutter/material.dart';
import '../search/query.dart';
import './source.dart';

class TextQuerySource<T> implements QuerySourceView<T> {
  final TextEditingController textController = TextEditingController();
  final Query<T> fallbackQuery;
  final Query<T> Function(String text) queryBuilder;

  @override
  final ValueNotifier<Query<T>> notifier;

  TextQuerySource({
    required this.queryBuilder,
    Query<T>? fallback,
  })  : fallbackQuery = fallback ?? All<T>(),
        notifier = ValueNotifier(fallback ?? All<T>()) {
    textController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    final text = textController.text;
    notifier.value = text.trim().isEmpty ? fallbackQuery : queryBuilder(text);
  }

  @override
  void dispose() {
    textController.dispose();
    notifier.dispose();
  }
}