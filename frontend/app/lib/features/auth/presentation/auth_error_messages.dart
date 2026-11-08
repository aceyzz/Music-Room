import 'package:app/core/errors/app_error.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';

/// User-facing text for an auth failure.
///
/// The server's own messages are not shown: they are developer strings (some
/// in French) and several are deliberately vague so they do not reveal which
/// emails have accounts. The client knows which screen it is on and can say
/// something useful instead.
enum AuthAction {
  login,
  register,
  verifyEmail,
  resendCode,
  oauth,
  requestReset,
  resetPassword,
  linkAccount,
  unlinkAccount,
}

String authErrorMessage(AppError error, AuthAction action) {
  return switch ((error, action)) {
    (UnauthorizedError(), AuthAction.login) => 'Wrong email or password.',
    (ConflictError(), AuthAction.register) => 'That email or display name is already taken.',
    (InvalidInputError(), AuthAction.register) =>
      'Check your email, display name, and password (at least 8 characters).',
    (InvalidInputError(), AuthAction.verifyEmail) =>
      'That code is wrong or has expired. Request a new one.',
    (InvalidInputError(), AuthAction.resetPassword) =>
      'That code is wrong or has expired, or the password is under 8 characters.',
    (OAuthFailedError(), AuthAction.oauth) => 'Sign-in was not completed. Please try again.',
    (UnauthorizedError(), AuthAction.oauth) => 'Sign-in with that provider failed. Try again.',
    (PreconditionFailedError(), AuthAction.oauth) =>
      'That provider did not share an email address, which an account needs.',
    (InvalidInputError(), AuthAction.oauth) => 'That provider is not available right now.',
    // Either that identity is another Music Room account's, or this account
    // already has one from the provider: the page only offers Link for a
    // provider with none, so it is the first.
    (ConflictError(), AuthAction.linkAccount) =>
      'That account is already linked to another Music Room account.',
    (OAuthFailedError(), AuthAction.linkAccount) => 'Linking was not completed. Please try again.',
    (InvalidInputError(), AuthAction.linkAccount) =>
      'Linking with that provider failed. Please try again.',
    (PreconditionFailedError(), AuthAction.unlinkAccount) =>
      'It is your only way to sign in. Set a password first.',
    (NotFoundError(), AuthAction.unlinkAccount) => 'That account was already unlinked.',
    (UnauthorizedError(), _) => 'Your session has ended. Please sign in again.',
    (NetworkError(), _) => 'Cannot reach the server. Check your connection.',
    _ => 'Something went wrong. Please try again.',
  };
}
