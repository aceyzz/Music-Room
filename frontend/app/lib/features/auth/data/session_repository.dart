import 'package:flutter/foundation.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/globals/app_constants.dart';

/// Keeps the three copies of the session in step: the server's, the one in
/// secure storage (survives restarts), and the one in memory that the gRPC
/// interceptor attaches to every call ([SessionCredentials]).
///
/// Every method that changes the session writes all three, in that order, so
/// the in-memory token is never ahead of what was persisted.
class SessionRepository {
  final AuthApi api;
  final TokenStorageService storage;
  final SessionCredentials credentials;
  final String devSessionToken;

  SessionRepository({
    required this.api,
    required this.storage,
    required this.credentials,
    this.devSessionToken = kDebugMode ? AppConstants.devSessionToken : '',
  });

  /// The stored session at startup, or null when signed out.
  Future<AuthSession?> restore() async {
    final stored = await storage.readSession();
    if (stored != null) {
      credentials.set(stored.token);
      return stored;
    }
    if (devSessionToken.isNotEmpty) {
      credentials.set(devSessionToken);
      return _devSession(devSessionToken);
    }
    return null;
  }

  Future<AuthSession> login({required String email, required String password}) async {
    final session = await api.login(email: email, password: password);
    await storage.saveSession(session);
    credentials.set(session.token);
    return session;
  }

  /// Same three-way save as [login]: OAuthLogin returns a session directly.
  Future<AuthSession> oauthLogin({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  }) async {
    final session = await api.oauthLogin(provider: provider, code: code, redirectUri: redirectUri);
    await storage.saveSession(session);
    credentials.set(session.token);
    return session;
  }

  /// Creates the account, then logs in: RegisterResponse carries no token.
  /// The server has already emailed the first verification code.
  Future<AuthSession> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    await api.register(email: email, password: password, displayName: displayName);
    return login(email: email, password: password);
  }

  /// Revokes the session server-side, then forgets it locally whatever the
  /// server said: a user who taps "log out" offline must still end up logged out.
  Future<void> logout() async {
    try {
      await api.logout();
    } on AppError catch (error) {
      debugPrint('Logout: server revocation failed, clearing locally anyway: $error');
    } finally {
      await forget();
    }
  }

  /// Drops the local session without calling the server. Used when the server
  /// has already rejected the token.
  Future<void> forget() async {
    credentials.clear();
    await storage.clearToken();
  }

  Future<void> requestEmailVerification() => api.requestEmailVerification();

  Future<void> verifyEmail(String code) => api.verifyEmail(code);

  Future<void> requestPasswordReset(String email) => api.requestPasswordReset(email);

  /// Does not sign in: ResetPasswordResponse carries no token. The caller
  /// logs in with the new password.
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) =>
      api.resetPassword(email: email, code: code, newPassword: newPassword);

  /// Records that the email is verified, so a restart does not ask again.
  Future<AuthSession> markEmailVerified(AuthSession session) async {
    final updated = session.copyWith(user: session.user.copyWith(emailVerified: true));
    if (updated.token != devSessionToken) {
      await storage.saveSession(updated);
    }
    return updated;
  }

  // The dev token comes with no account details. Marked verified so the
  // verification screen does not block the screens it is meant to reach.
  static AuthSession _devSession(String token) => AuthSession(
        token: token,
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        user: const AuthUser(
          publicId: '',
          displayName: 'dev',
          email: '',
          emailVerified: true,
        ),
      );
}
