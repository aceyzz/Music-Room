import 'dart:async';
import 'package:app/core/errors/error_mapper.dart';
import 'package:flutter/material.dart';
import 'package:app/core/errors/app_error.dart';
import 'package:app/core/sources/source_state.dart';

class RepositoryController<Repo> {
  // Every controller MUST have a repository of type Repo
  final Repo repository;

// Keyed subscriptions for selective cancellation or replacement
  final Map<Object, StreamSubscription<dynamic>> _keyedSubscriptions = {};

  // Anonymous subscriptions that live until dispose()
  final List<StreamSubscription<dynamic>> _anonymousSubscriptions = [];

  bool _isInitialized = false;

  RepositoryController({required this.repository});

  /// Checks if a specific keyed subscription is currently active
  bool isSubscribedTo(Object key) => _keyedSubscriptions.containsKey(key);

  /// Cancels and removes a specific subscription by its key
  void cancelSubscription(Object key) {
    _keyedSubscriptions.remove(key)?.cancel();
  }

  void bindWithState<T, S extends SourceState<T>>({
    required Stream<T> stream,
    required ValueNotifier<S> notifier, 
    required S Function(T? currentData) onLoading,
    required S Function(T data) onSuccess,
    required S Function(AppError error, T? currentData) onError,
    Object? key,
  }) {
    // 1. Transition to loading
    notifier.value = onLoading(notifier.value.data);

    // 2. Listen and map success/error
    bind<T>(
      stream,
      (data) => notifier.value = onSuccess(data),
      onError: (error, stackTrace) {
        final appError = ErrorMapper.from(error, stackTrace);
        notifier.value = onError(appError, notifier.value.data);
      },
      key: key,
    );
  }

  // Add a callback when we add information to a subscribed stream.
  void bind<T>(
    Stream<T> stream,
    void Function(T data) onData, {
    Object? key,
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (key != null) {
      cancelSubscription(key);
    }

    final subscription = stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );

    if (key != null) {
      _keyedSubscriptions[key] = subscription;
    } else {
      _anonymousSubscriptions.add(subscription);
    }
  }

  /// Executes initialization logic once and marks the controller as initialized.
  Future<void> initialize(
    Future<void> Function(RepositoryController<Repo> controller) onInit,
  ) async {
    if (_isInitialized) return;

    await onInit(this);
    _isInitialized = true;
  }

  void dispose() {
    for (final sub in _keyedSubscriptions.values) {
      sub.cancel();
    }
    _keyedSubscriptions.clear();

    for (final sub in _anonymousSubscriptions) {
      sub.cancel();
    }
    _anonymousSubscriptions.clear();
  }
}
