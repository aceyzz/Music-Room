import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/models/user/profile_update.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/data/oauth_browser_flow.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/user/data/user_source.dart';

export 'package:app/features/auth/presentation/session_context.dart';

/// Who is using the app. The router redirects on it (globals/app_router.dart).
@immutable
sealed class SessionState {
  const SessionState();
}

final class SignedOut extends SessionState {
  /// True when the server ended the session (expired, idle, revoked) rather
  /// than the user logging out, so the login page can say why.
  final bool expired;

  const SignedOut({this.expired = false});

  @override
  bool operator ==(Object other) => other is SignedOut && other.expired == expired;

  @override
  int get hashCode => expired.hashCode;
}

final class SignedIn extends SessionState {
  final AuthSession session;

  const SignedIn(this.session);

  AuthUser get user => session.user;

  @override
  bool operator ==(Object other) =>
      other is SignedIn && other.session.token == session.token && other.user == user;

  @override
  int get hashCode => Object.hash(session.token, user);
}

/// Global store for the session. Built in main.dart above the router, since
/// every page depends on it (see the note in globals/app_router.dart).
///
/// Methods throw [AppError] on failure and leave [state] untouched; the page
/// that called them shows the error.
class SessionStore {
  final SessionRepository _repository;
  final SessionCredentials _credentials;

  /// Saves the optional profile at sign-up. Null in tests that don't care;
  /// [register] then reports the profile as not saved.
  final UserApi? _users;

  /// The browser half of "Sign in with ...". Null where no provider can be
  /// used (tests that don't care); [oauthProviders] is then empty.
  final OAuthBrowserFlow? _oauth;

  final ValueNotifier<SessionState> state = ValueNotifier(const SignedOut());

  SessionStore(
    this._repository,
    this._credentials, {
    UserApi? users,
    OAuthBrowserFlow? oauth,
  })  : _users = users,
        _oauth = oauth;

  /// Providers this build can sign in with: a client ID is configured and the
  /// platform can catch the redirect.
  Set<OAuthProvider> get oauthProviders => _oauth?.config.availableProviders ?? const {};

  /// False on platforms where the browser step is not wired (web, Windows,
  /// Linux), so the page can say why the buttons are off.
  bool get oauthPlatformSupported => _oauth?.config.platformSupported ?? false;

  /// Restores the stored session. Await it before building the router, so
  /// the first redirect already knows whether someone is signed in.
  Future<void> start() async {
    _credentials.onRejected = (_) => _expire();
    final session = await _repository.restore();
    state.value = session == null ? const SignedOut() : SignedIn(session);
  }

  void stop() {
    _credentials.onRejected = null;
    state.dispose();
  }

  /// The signed-in user; null when signed out. Pages behind the sign-in read
  /// it through `context.currentUser` (session_context.dart).
  AuthUser? get currentUser => _signedIn?.user;

  SignedIn? get _signedIn => switch (state.value) {
        final SignedIn s => s,
        SignedOut() => null,
      };

  Future<void> login({required String email, required String password}) async {
    final session = await _repository.login(email: email.trim(), password: password);
    state.value = SignedIn(session);
  }

  /// Creates the account, signs in, and saves [profile] if one is given.
  ///
  /// The profile is saved *before* [state] changes: SignedIn makes the router
  /// leave the sign-up page for /verify-email, and nothing should still be
  /// running on a page that is gone.
  ///
  /// A failed profile save does not fail the sign-up: the account exists and
  /// the user is in, so throwing would leave them on a form that can only say
  /// "email taken" on a retry. Returns false instead, for the page to mention.
  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
    ProfileUpdate? profile,
  }) async {
    final session = await _repository.register(
      email: email.trim(),
      password: password,
      displayName: displayName.trim(),
    );
    var profileSaved = true;
    if (profile != null && !profile.isEmpty) {
      profileSaved = await _saveProfile(session.user.publicId, profile);
    }
    state.value = SignedIn(session);
    return profileSaved;
  }

  Future<bool> _saveProfile(String publicId, ProfileUpdate profile) async {
    final users = _users;
    if (users == null) {
      return false;
    }
    try {
      await users.updateProfile(publicId, profile);
      return true;
    } on AppError catch (error) {
      debugPrint('Register: account created, profile not saved: $error');
      return false;
    }
  }

  /// "Sign in with [provider]": the login window, then [oauthLogin] with the
  /// code it returns. Throws [OAuthCancelledError] if the user backs out,
  /// which pages should not report as an error.
  Future<void> signInWithProvider(OAuthProvider provider) async {
    final oauth = _oauth;
    if (oauth == null) {
      throw OAuthFailedError('${provider.label} sign-in is not set up');
    }
    final authorization = await oauth.authorize(provider);
    await oauthLogin(
      provider: provider,
      code: authorization.code,
      redirectUri: authorization.redirectUri,
    );
  }

  /// Signs in with a provider's authorization code ([signInWithProvider]
  /// obtains one). [redirectUri] must be the one the code was issued for.
  Future<void> oauthLogin({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  }) async {
    final session = await _repository.oauthLogin(
      provider: provider,
      code: code,
      redirectUri: redirectUri,
    );
    state.value = SignedIn(session);
  }

  /// Emails a reset code. The server answers the same whether or not the
  /// address has an account, so this succeeding says nothing about it.
  Future<void> requestPasswordReset(String email) =>
      _repository.requestPasswordReset(email.trim());

  /// Sets the new password, then signs in with it: someone who just proved
  /// they own the inbox should not have to type it all again.
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await _repository.resetPassword(
      email: email.trim(),
      code: code.trim(),
      newPassword: newPassword,
    );
    await login(email: email, password: newPassword);
  }

  Future<void> logout() async {
    await _repository.logout();
    state.value = const SignedOut();
  }

  Future<void> verifyEmail(String code) async {
    try {
      await _repository.verifyEmail(code.trim());
    } on PreconditionFailedError {
      // Already verified (another device, or a double tap): the goal is met.
    }
    await _markVerified();
  }

  Future<void> resendVerificationCode() async {
    try {
      await _repository.requestEmailVerification();
    } on PreconditionFailedError {
      // The server says the email is already verified: this copy was stale.
      await _markVerified();
    }
  }

  Future<void> _markVerified() async {
    final current = _signedIn;
    if (current == null) {
      return;
    }
    state.value = SignedIn(await _repository.markEmailVerified(current.session));
  }

  Future<void> _expire() async {
    if (_signedIn == null) {
      return;
    }
    await _repository.forget();
    state.value = const SignedOut(expired: true);
  }
}
