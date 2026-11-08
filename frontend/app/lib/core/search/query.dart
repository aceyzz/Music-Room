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
abstract interface class Query<T> {
  /// Evaluates whether [item] satisfies this constraint.
  bool satisfies(T item);
}

/// Adds fluent combinators to any [Query].
extension QueryExtensions<T> on Query<T> {
  Query<T> and(Query<T> other) => AndConstraint<T>([this, other]);
  Query<T> or(Query<T> other) => OrConstraint<T>([this, other]);
  Query<T> not() => NotConstraint<T>(this);
}

// Logical AND composite constraint
class AndConstraint<T> implements Query<T> {
  final List<Query<T>> constraints;

  AndConstraint(this.constraints);

  @override
  bool satisfies(T item) => constraints.every((c) => c.satisfies(item));
}

/// Logical OR composite constraint: true if AT LEAST ONE constraint is satisfied.
class OrConstraint<T> implements Query<T> {
  final List<Query<T>> constraints;

  OrConstraint(this.constraints);

  @override
  bool satisfies(T item) => constraints.any((c) => c.satisfies(item));
}

/// Logical NOT unary constraint: true if the target constraint is NOT satisfied.
class NotConstraint<T> implements Query<T> {
  final Query<T> constraint;

  NotConstraint(this.constraint);

  @override
  bool satisfies(T item) => !constraint.satisfies(item);
}


/// Logical XOR composite constraint: true if EXACTLY ONE constraint is satisfied.
class XorConstraint<T> implements Query<T> {
  final List<Query<T>> constraints;

  XorConstraint(this.constraints);

  @override
  bool satisfies(T item) =>
      constraints.where((c) => c.satisfies(item)).length == 1;
}

/// Logical NOR composite constraint: true if NO constraints are satisfied.
class NorConstraint<T> implements Query<T> {
  final List<Query<T>> constraints;

  NorConstraint(this.constraints);

  @override
  bool satisfies(T item) => !constraints.any((c) => c.satisfies(item));
}


/// Logical NOR composite constraint: true if NO constraints are satisfied.
class All<T> implements Query<T> {
  All();

  @override
  bool satisfies(T item) => true;
}

/// Logical NOR composite constraint: true if NO constraints are satisfied.
class None<T> implements Query<T> {
  None();

  @override
  bool satisfies(T item) => false;
}


class ConditionalOrDefault<T> implements Query<T> {
  final bool condition;
  final Query<T> ifTrue;
  final Query<T> ifFalse;

  ConditionalOrDefault({
    required this.condition,
    required this.ifTrue,
    required this.ifFalse,
  });

  @override
  bool satisfies(T item) {
    // If the search string is empty, fall back to the default query
    if (condition) {
      return ifTrue.satisfies(item);
    }
    // Otherwise, evaluate the main conditional query
    return ifFalse.satisfies(item);
  }
}
