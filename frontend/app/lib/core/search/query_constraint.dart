import 'package:app/core/search/number_constraints.dart';
import 'package:app/core/search/text_constraints.dart';
import 'package:app/core/search/query.dart';

/// Represents a composable query constraint (Specification Pattern) evaluated lazily.
///
/// Use this pattern to define reusable filtering logic and combine complex rules
/// (e.g., `(Genre == "Rock" OR Genre == "Pop") AND Duration < 200 AND NOT Explicit`).
///
/// ### Example Usage:
/// ```dart
/// num getDuration(Song s) => s.durationInSeconds;
/// String getTitle(Song s) => s.title;
///
/// final filter = getDuration.greaterThan(180)
///     .and(getTitle.contains('Midnight'))
///     .and(getDuration.lessThan(300));
///
/// final results = songs.where(filter.satisfies).toList();
/// ```
final class QueryConstraint<T> {
  const QueryConstraint._();

  static Query<T> andAll<T>(List<Query<T>> constraints) =>
      AndConstraint<T>(constraints);

  static Query<T> orAll<T>(List<Query<T>> constraints) =>
      OrConstraint<T>(constraints);

  static Query<T> nor<T>(List<Query<T>> constraints) =>
      NorConstraint<T>(constraints);

  static Query<T> xor<T>(List<Query<T>> constraints) =>
      XorConstraint<T>(constraints);

  static Query<T> negate<T>(Query<T> constraint) =>
      NotConstraint<T>(constraint);

  static Query<T> equalTo<T>(num value, num Function(T) getField) =>
      EqualTo<T>(value, getField);

  static Query<T> greaterThan<T>(num threshold, num Function(T) getField) =>
      GreaterThan<T>(threshold, getField);

  static Query<T> greaterOrEqualThan<T>(
          num threshold, num Function(T) getField) =>
      GreaterOrEqualThan<T>(threshold, getField);

  static Query<T> lessThan<T>(num threshold, num Function(T) getField) =>
      LessThan<T>(threshold, getField);

  static Query<T> lessOrEqualThan<T>(num threshold, num Function(T) getField) =>
      LessOrEqualThan<T>(threshold, getField);

  static Query<T> between<T>(num min, num max, num Function(T) getField) =>
      BetweenConstraint<T>(min, max, getField);

  static Query<T> text<T>(String query, String Function(T) getField) =>
      TextConstraint<T>(query, getField);

  static Query<T> textEqual<T>(String target, String Function(T) getField,
          {bool caseSensitive = false}) =>
      TextEqual<T>(target, getField, caseSensitive: caseSensitive);

  static Query<T> textContains<T>(String query, String Function(T) getField,
          {bool caseSensitive = false}) =>
      TextContains<T>(query, getField, caseSensitive: caseSensitive);

  static Query<T> textStartsWith<T>(String prefix, String Function(T) getField,
          {bool caseSensitive = false}) =>
      TextStartsWith<T>(prefix, getField, caseSensitive: caseSensitive);

  static Query<T> regexp<T>(RegExp regExp, String Function(T) getField) =>
      Regexp<T>(regExp, getField);

  static Query<T> textEmpty<T>(String Function(T) getField) =>
      TextEmpty<T>(getField);
}

// Enable chaining syntax without having to repeat QueryConstraint.all()
extension QueryOrDefaultExtension<T> on Query<T> {
  Query<T> orDefault(Query<T> fallback, {required bool Function() condition}) {
    return ConditionalOrDefault<T>(
      condition: condition(),
      ifTrue: this,
      ifFalse: fallback,
    );
  }

  // Specialized convenience version for text search queries
  Query<T> orDefaultWhenEmpty(Query<T> fallback, String queryText) {
    return TextEmptyOrDefault<T>(
      conditional: this,
      fallback: fallback,
      queryText: queryText,
    );
  }
}

// Extension for text fields enable chaining syntax
extension StringPropertyExtension<T> on String Function(T) {
  Query<T> textEquals(String target, {bool caseSensitive = false}) =>
      TextEqual<T>(target, this, caseSensitive: caseSensitive);

  Query<T> contains(String query, {bool caseSensitive = false}) =>
      TextContains<T>(query, this, caseSensitive: caseSensitive);

  Query<T> startsWith(String prefix, {bool caseSensitive = false}) =>
      TextStartsWith<T>(prefix, this, caseSensitive: caseSensitive);

  Query<T> matches(RegExp regExp) => Regexp<T>(regExp, this);

  Query<T> isEmpty() => TextEmpty<T>(this);
}

// Enable chaining syntax without having to repeat QueryConstraint.all()
extension NumPropertyExtension<T> on num Function(T) {
  Query<T> equalTo(num value) => EqualTo<T>(value, this);
  Query<T> greaterThan(num threshold) =>
      GreaterThan<T>(threshold, this);
  Query<T> greaterOrEqualThan(num threshold) =>
      GreaterOrEqualThan<T>(threshold, this);
  Query<T> lessThan(num threshold) => LessThan<T>(threshold, this);
  Query<T> lessOrEqualThan(num threshold) =>
      LessOrEqualThan<T>(threshold, this);
  Query<T> between(num min, num max) =>
      BetweenConstraint<T>(min, max, this);
}
