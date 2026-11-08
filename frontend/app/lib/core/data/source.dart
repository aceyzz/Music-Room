import 'package:flutter/material.dart';
import 'package:app/core/search/search.dart';

abstract interface class Reset {
  void dispose();
}

abstract interface class Source<T> {}

abstract interface class SourceView<T> implements Source<T> {
  ValueNotifier<T> get notifier;
}

abstract class QuerySourceView<T> implements SourceView<Query<T>>, Reset {}


