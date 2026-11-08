import 'package:flutter/foundation.dart';
import 'package:app/core/errors/app_error.dart';


typedef ItemState<T> = SourceItemState<T>;
typedef ListState<T> = SourceListState<T>;

@immutable
abstract class SourceState<T> {
  final T? data;
  final bool isLoading;
  final AppError? error;

  const SourceState({
    this.data,
    this.isLoading = false,
    this.error,
  });

  bool get hasData => data != null;
  bool get hasError => error != null;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SourceState<T> &&
        other.data == data &&
        other.isLoading == isLoading &&
        other.error == error;
  }

  @override
  int get hashCode => Object.hash(
        data,
        isLoading,
        error,
      );
}

@immutable
class SourceItemState<T> extends SourceState<T> {
  const SourceItemState({super.data, super.isLoading, super.error});

  /// Uninitialized, idle state
  factory SourceItemState.initial() => const SourceItemState();

  /// State when starting a new fetch or pull-to-refresh
  factory SourceItemState.loading(T? currentData) => SourceItemState(
        data: currentData,
        isLoading: true,
      );

  /// State when data is successfully loaded
  factory SourceItemState.success(T data) => SourceItemState(
        data: data,
      );

  /// State when an error occurs
  factory SourceItemState.error(AppError error, T? currentData) =>
      SourceItemState(
        data: currentData,
        error: error,
      );

  /// Creates a copy of the state with updated fields
  SourceItemState<T> copyWith({
    T? data,
    bool? isLoading,
    AppError? error,
  }) {
    return SourceItemState<T>(
      data: data ?? this.data,
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
    );
  }

}

@immutable
class SourceListState<T> extends SourceState<List<T>> {
  final bool isFetchingMore;
  final bool hasReachedEnd;

  const SourceListState({
    super.data,
    super.isLoading,
    super.error,
    this.isFetchingMore = false,
    this.hasReachedEnd = false,
  });

  /// Uninitialized, idle state
  factory SourceListState.initial() => const SourceListState();

  /// State when starting a new fetch or pull-to-refresh
  factory SourceListState.loading(List<T>? currentData) => SourceListState(
        data: currentData,
        isLoading: true,
      );

  /// State when fetching subsequent pages
  factory SourceListState.fetchingMore({required List<T> currentData}) =>
      SourceListState(
        data: currentData,
        isFetchingMore: true,
      );

  /// State when data is successfully loaded
  factory SourceListState.success(List<T> data, {bool hasReachedEnd = false}) =>
      SourceListState(
        data: data,
        hasReachedEnd: hasReachedEnd,
      );

  /// State when an error occurs
  factory SourceListState.error(AppError error, List<T>? currentData) =>
      SourceListState(
        data: currentData,
        error: error,
      );

  /// Creates a copy of the state with updated fields
  SourceListState<T> copyWith({
    List<T>? data,
    bool? isLoading,
    bool? isFetchingMore,
    bool? hasReachedEnd,
    AppError? error,
  }) {
    return SourceListState<T>(
      data: data ?? this.data,
      isLoading: isLoading ?? this.isLoading,
      isFetchingMore: isFetchingMore ?? this.isFetchingMore,
      hasReachedEnd: hasReachedEnd ?? this.hasReachedEnd,
      error: error ?? this.error,
    );
  }

 @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SourceListState<T> &&
        listEquals(data, other.data) &&
        other.isLoading == isLoading &&
        other.error == error &&
        other.isFetchingMore == isFetchingMore &&
        other.hasReachedEnd == hasReachedEnd;
  }

  @override
  int get hashCode => Object.hash(
        data != null ? Object.hashAll(data!) : null,
        isLoading,
        error,
        isFetchingMore,
        hasReachedEnd,
      );
}
