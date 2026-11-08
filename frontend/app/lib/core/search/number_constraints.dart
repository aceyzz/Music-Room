import 'package:app/core/search/query.dart';

/// Checks if a numeric field is equal to [threshold].
class EqualTo<T> implements Query<T> {
  final num value;
  final num Function(T) getField;

  EqualTo(this.value, this.getField);

  @override
  bool satisfies(T item) => getField(item) == value;
}

/// Checks if a numeric field is strictly greater than [threshold].
class GreaterThan<T> implements Query<T> {
  final num threshold;
  final num Function(T) getField;

  GreaterThan(this.threshold, this.getField);

  @override
  bool satisfies(T item) => getField(item) > threshold;
}

/// Checks if a numeric field is greater than or equal to [threshold].
class GreaterOrEqualThan<T> implements Query<T> {
  final num threshold;
  final num Function(T) getField;

  GreaterOrEqualThan(this.threshold, this.getField);

  @override
  bool satisfies(T item) => getField(item) >= threshold;
}

/// Checks if a numeric field is strictly less than [threshold].
class LessThan<T> implements Query<T> {
  final num threshold;
  final num Function(T) getField;

  LessThan(this.threshold, this.getField);

  @override
  bool satisfies(T item) => getField(item) < threshold;
}

/// Checks if a numeric field is less than or equal to [threshold].
class LessOrEqualThan<T> implements Query<T> {
  final num threshold;
  final num Function(T) getField;

  LessOrEqualThan(this.threshold, this.getField);

  @override
  bool satisfies(T item) => getField(item) <= threshold;
}

/// Checks if a numeric field falls within a range [min, max] inclusive.
class BetweenConstraint<T> implements Query<T> {
  final num min;
  final num max;
  final num Function(T) getField;

  BetweenConstraint(this.min, this.max, this.getField);

  @override
  bool satisfies(T item) {
    final value = getField(item);
    return value >= min && value <= max;
  }
}

