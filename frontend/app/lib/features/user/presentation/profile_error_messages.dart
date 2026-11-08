import 'package:app/core/errors/app_error.dart';
import 'package:app/features/user/data/avatar_image.dart';

/// User-facing text for a profile failure. Like auth_error_messages.dart, the
/// server's own strings are not shown: they are written for developers.
enum ProfileAction { load, save, changeAvatar, removeAvatar }

String profileErrorMessage(AppError error, ProfileAction action) {
  return switch ((error, action)) {
    (AvatarRejectedError(:final message), _) => message,
    (InvalidInputError(), ProfileAction.save) =>
      'Some details were not accepted. Check the country (2 letters) and the phone number.',
    (InvalidInputError(), ProfileAction.changeAvatar) =>
      'That image could not be read. Try another one.',
    (UnauthorizedError(), _) => 'Your session has ended. Please sign in again.',
    (NetworkError(), _) => 'Cannot reach the server. Check your connection.',
    (_, ProfileAction.load) => 'Your profile could not be loaded.',
    _ => 'Something went wrong. Please try again.',
  };
}
