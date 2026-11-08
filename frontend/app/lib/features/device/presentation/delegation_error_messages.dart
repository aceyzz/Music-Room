import 'package:app/core/errors/app_error.dart';

/// User-facing text for a licence that could not be given or taken back.
/// Like live_event_error_messages.dart, the server's own strings are written
/// for developers and not shown.
String delegationErrorMessage(AppError error) {
  return switch (error) {
    // The one live licence per friend, device and event (a second tap, or
    // another of the host's apps got there first).
    ConflictError() => 'They can already control the music.',
    NotFoundError() => 'That was already taken back.',
    // Friends only, checked when the licence is written: unfriended since
    // the list was read.
    UnauthorizedError() => 'You can only give control to a friend.',
    NetworkError() => 'Cannot reach the server. Check your connection.',
    _ => 'Something went wrong. Please try again.',
  };
}

/// User-facing text for a speaker that could not be picked, or devices that
/// could not be listed.
String speakerErrorMessage(AppError error) {
  return switch (error) {
    // SetEventSpeaker refuses an ended event.
    PreconditionFailedError() => 'The event has ended.',
    NotFoundError() || UnauthorizedError() => 'Only the host can pick, among their own devices.',
    NetworkError() => 'Cannot reach the server. Check your connection.',
    _ => 'Something went wrong. Please try again.',
  };
}
