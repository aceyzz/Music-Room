import 'dart:convert';

import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/storage/secure_token_storage.dart';

class TokenStorageService {

  static final SecureTokenStorage _storage = SecureTokenStorage(); 

  /// Save session token across any platform
  Future<void> saveToken(String token) async {
    await _storage.saveSessionToken(token);
  }

  /// Retrieve session token across any platform
  Future<String?> getToken() async {
    return await _storage.getSessionToken();
  }

  /// Delete session token on logout, and the account stored with it.
  Future<void> clearToken() async {
    await _storage.deleteSessionToken();
    await _storage.deleteSessionUser();
  }

  /// Persists a whole session: the token, and who it belongs to.
  Future<void> saveSession(AuthSession session) async {
    await _storage.saveSessionToken(session.token);
    await _storage.saveSessionUser(jsonEncode({
      ...session.user.toJson(),
      'expiresAt': session.expiresAt.millisecondsSinceEpoch,
    }));
  }

  /// The stored session, or null when there is none or it is unreadable.
  ///
  /// Only the absolute expiry is checked here. An idle or revoked session
  /// still comes back, and the first call that returns `UNAUTHENTICATED`
  /// ends it (core/network/auth/auth_interceptor.dart).
  Future<AuthSession?> readSession({DateTime? now}) async {
    final token = await _storage.getSessionToken();
    if (token == null || token.isEmpty) {
      return null;
    }

    final raw = await _storage.getSessionUser();
    final Map<String, dynamic> json;
    try {
      json = raw == null ? const {} : jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      await clearToken();
      return null;
    }

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(json['expiresAt'] as int? ?? 0);
    if (!expiresAt.isAfter(now ?? DateTime.now())) {
      await clearToken();
      return null;
    }
    return AuthSession(token: token, expiresAt: expiresAt, user: AuthUser.fromJson(json));
  }
}
