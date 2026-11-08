import 'package:app/core/errors/app_error.dart';
import 'package:app/core/location/position_source.dart';

/// User-facing text for a failed playback button. Like
/// profile_error_messages.dart, the server's own strings are not shown: they
/// are written for developers.
enum PlaybackAction { playPause, next, seek }

String playbackErrorMessage(AppError error, PlaybackAction action) {
  return switch ((error, action)) {
    // PERMISSION_DENIED and UNAUTHENTICATED both arrive as UnauthorizedError
    // (ErrorMapper.fromGrpc). A lost session is handled by the session store
    // and sends the user to the login page, so here it means "not yours".
    (UnauthorizedError(), _) => 'Only the person in control can do that.',
    (PreconditionFailedError(), _) => 'The queue is empty: suggest some songs first.',
    (NetworkError(), _) => 'Cannot reach the server. Check your connection.',
    _ => 'Something went wrong. Please try again.',
  };
}

/// User-facing text for a vote that failed.
String voteErrorMessage(AppError error) {
  return _placeAndTime(error, 'vote') ??
      switch (error) {
        // Not a member under an invited-only licence.
        UnauthorizedError() => "You can't vote in this event.",
        // Gone from the queue: it started playing (LiveEventStore.vote).
        NotFoundError() => 'That song has already left the queue.',
        // The only status that refuses votes (requireVoteResiduals).
        PreconditionFailedError() => 'This event has ended.',
        NetworkError() => 'Cannot reach the server. Check your connection.',
        _ => 'Something went wrong. Please try again.',
      };
}

/// User-facing text for a suggestion that failed.
String suggestErrorMessage(AppError error) {
  return _placeAndTime(error, 'suggest songs') ??
      switch (error) {
        // ALREADY_EXISTS: queued or playing right now. It can come back once it
        // has played.
        ConflictError() => 'That song is already in the queue.',
        // Suggesting follows the vote licence (docs/permissions.md §11).
        UnauthorizedError() => "You can't suggest songs in this event.",
        PreconditionFailedError() => 'This event has ended.',
        NetworkError() => 'Cannot reach the server. Check your connection.',
        _ => 'Something went wrong. Please try again.',
      };
}

/// Why someone may not [action] in an event that only counts the people at
/// its venue during its window (`location_time`), or null when that is not
/// the reason. The server says which rule refused (requireVoteResiduals in
/// backend/internal/event/access.go).
String? _placeAndTime(AppError error, String action) => switch (error) {
      PositionUnavailableError() =>
        "Your position is not available, and this event only lets people at its venue $action.",
      UnauthorizedError(:final message) when message.contains('venue radius') =>
        "You are not at this event's venue: only people there can $action.",
      UnauthorizedError(:final message) when message.contains('vote window') =>
        "This event only lets people $action during its hours.",
      _ => null,
    };
