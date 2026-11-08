import 'package:flutter/material.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/widgets/snack.dart';

/// For a page that runs one request at a time and reports failures in a
/// snack bar: the try / catch AppError / finally-if-mounted dance every form
/// page needs, written once.
///
/// ```dart
/// class _MyPageState extends State<MyPage> with BusyState<MyPage> {
///   Future<void> _save() => run(() => store.save(...), message: myErrorText);
///   ... LoadingButton(busy: busy, onPressed: _save) ...
/// }
/// ```
mixin BusyState<T extends StatefulWidget> on State<T> {
  bool _busy = false;

  /// True while an action passed to [run] is in flight.
  bool get busy => _busy;

  /// Runs [action] unless one is already running. An [AppError] is shown via
  /// [message] (which turns it into user-facing text, or null to stay silent,
  /// e.g. when the user cancelled) and swallowed; returns whether the action
  /// succeeded, so a page can chain a follow-up.
  ///
  /// Only [AppError] is caught: sources map everything else, so anything that
  /// gets here otherwise is a bug and should surface as one.
  Future<bool> run(
    Future<void> Function() action, {
    required String? Function(AppError error) message,
  }) async {
    if (_busy) {
      return false;
    }
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } on AppError catch (error) {
      final text = message(error);
      if (text != null) {
        showError(text);
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void showError(String text) {
    if (!mounted) {
      return;
    }
    showSnack(context, text, error: true);
  }

  void showInfo(String text) {
    if (!mounted) {
      return;
    }
    showSnack(context, text);
  }
}
