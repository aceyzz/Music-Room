import 'package:app/core/errors/app_error.dart';

/// User-facing text for a failed edit on the playlist page. Like
/// live_event_error_messages.dart, the server's own strings are not shown:
/// they are written for developers.
enum PlaylistEdit { add, remove, move }

String playlistEditErrorMessage(AppError error, PlaylistEdit edit) {
  return switch ((error, edit)) {
    // PERMISSION_DENIED arrives as UnauthorizedError (ErrorMapper.fromGrpc):
    // the edit licence changed, or the user was never allowed.
    (UnauthorizedError(), _) => "You can't edit this playlist.",
    // The song, or the one it was dropped under, was removed meanwhile. The
    // store has read the playlist again, so the screen is already right.
    (NotFoundError(), PlaylistEdit.move) =>
      'Someone else just changed this part of the playlist. The list is up to date now.',
    (NotFoundError(), _) => 'This playlist no longer exists.',
    // ALREADY_EXISTS: the page catches it first and asks "add it still?".
    (ConflictError(), _) => 'Song already present in the playlist.',
    (NetworkError(), _) => 'Cannot reach the server. Check your connection.',
    _ => 'Something went wrong. Please try again.',
  };
}
