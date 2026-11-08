
import 'package:app/core/search/query.dart';
import 'package:app/core/search/search.dart';

/// Text matching constraint
class TextConstraint<T> implements Query<T> {
  final String query;
  final String Function(T) getField;

  TextConstraint(this.query, this.getField);

  @override
  bool satisfies(T item) {
    if (query.trim().isEmpty) return true;
    return getField(item).toLowerCase().contains(query.toLowerCase());
  }
}

/// Exact string match
class TextEqual<T> implements Query<T> {
  final String target;
  final String Function(T) getField;
  final bool caseSensitive;

  TextEqual(this.target, this.getField, {this.caseSensitive = false});

  @override
  bool satisfies(T item) {
    final value = getField(item);
    return caseSensitive
        ? value == target
        : value.toLowerCase() == target.toLowerCase();
  }
}

/// Contains substring
class TextContains<T> implements Query<T> {
  final String query;
  final String Function(T) getField;
  final bool caseSensitive;

  TextContains(this.query, this.getField, {this.caseSensitive = false});

  @override
  bool satisfies(T item) {
    if (query.trim().isEmpty) return true;
    final value = getField(item);
    return caseSensitive
        ? value.contains(query)
        : value.toLowerCase().contains(query.toLowerCase());
  }
}

/// Starts with prefix
class TextStartsWith<T> implements Query<T> {
  final String prefix;
  final String Function(T) getField;
  final bool caseSensitive;

  TextStartsWith(this.prefix, this.getField, {this.caseSensitive = false});

  @override
  bool satisfies(T item) {
    final value = getField(item);
    return caseSensitive
        ? value.startsWith(prefix)
        : value.toLowerCase().startsWith(prefix.toLowerCase());
  }
}

/// Regex match
class Regexp<T> implements Query<T> {
  final RegExp regExp;
  final String Function(T) getField;

  Regexp(this.regExp, this.getField);

  @override
  bool satisfies(T item) => regExp.hasMatch(getField(item));
}

/// Empty string check
class TextEmpty<T> implements Query<T> {
  final String Function(T) getField;

  TextEmpty(this.getField);

  @override
  bool satisfies(T item) => getField(item).trim().isEmpty;
}


class TextEmptyOrDefault<T> extends ConditionalOrDefault<T> {
  TextEmptyOrDefault({
    required String queryText,
    required Query<T> conditional,
    required Query<T> fallback,
  }) : super(
          condition: queryText.trim().isNotEmpty,
          ifTrue: conditional,
          ifFalse: fallback,
        );
}
