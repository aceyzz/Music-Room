import 'dart:async';

import 'package:app/core/errors/app_error.dart';

/// Keeps one server stream (a Watch RPC) open while a page shows it.
///
/// The stream sends the whole state at once, then again after every change
/// (backend/internal/realtime). When it drops -- the network, a server
/// restart -- it is opened again, a little later each time it fails in a
/// row. NotFoundError ends it for good: the object is gone, or the viewer may
/// no longer see it, and asking again would get the same answer; [resume]
/// opens it again (the page's "Try again").
class LiveStream<T> {
  final Stream<T> Function() _open;
  final void Function(T state) _onState;
  final void Function(AppError error) _onError;

  /// How long to wait before opening the stream again, one step further each
  /// time it fails in a row (the last step repeats).
  final List<Duration> retryDelays;

  static const defaultRetryDelays = [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 10),
  ];

  StreamSubscription<T>? _subscription;
  Timer? _retry;
  int _failures = 0;
  bool _gone = false;
  bool _stopped = false;

  /// What [start] waits for: the first state, the first failure, or [stop].
  Completer<void>? _opened;

  LiveStream(
    this._open, {
    required void Function(T state) onState,
    required void Function(AppError error) onError,
    this.retryDelays = defaultRetryDelays,
  })  : _onState = onState,
        _onError = onError;

  /// Opens the stream. Completes at the first state or the first failure.
  Future<void> start() => _subscribe();

  /// Opens the stream again if it ended for good. Does nothing while it is
  /// open or about to be reopened.
  void resume() {
    if (_stopped || _subscription != null || (_retry?.isActive ?? false)) {
      return;
    }
    _gone = false;
    unawaited(_subscribe());
  }

  void stop() {
    _stopped = true;
    _settle();
    _subscription?.cancel();
    _retry?.cancel();
  }

  Future<void> _subscribe() {
    _settle();
    final opened = _opened = Completer<void>();
    _subscription = _open().listen(
      (state) {
        _failures = 0;
        _onState(state);
        _settle();
      },
      onError: (Object error) {
        if (error is NotFoundError) {
          _gone = true;
        }
        if (error is AppError) {
          _onError(error);
        }
        _settle();
      },
      onDone: () {
        _subscription = null;
        _settle();
        _scheduleRetry();
      },
    );
    return opened.future;
  }

  void _scheduleRetry() {
    if (_stopped || _gone) {
      return;
    }
    final delay = retryDelays[_failures.clamp(0, retryDelays.length - 1)];
    _failures++;
    _retry = Timer(delay, () {
      if (!_stopped) {
        _subscribe();
      }
    });
  }

  void _settle() {
    final opened = _opened;
    if (opened != null && !opened.isCompleted) {
      opened.complete();
    }
  }
}
