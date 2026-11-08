import 'package:flutter/foundation.dart';

/// The signed-in account, as the login response describes it.
///
/// Persisted next to the session token (JSON in secure storage) so a restart
/// knows who is signed in and whether the email still needs verifying without
/// a network call.
@immutable
class AuthUser {
  final String publicId;
  final String displayName;
  final String email;
  final bool emailVerified;

  const AuthUser({
    required this.publicId,
    required this.displayName,
    required this.email,
    required this.emailVerified,
  });

  AuthUser copyWith({
    String? publicId,
    String? displayName,
    String? email,
    bool? emailVerified,
  }) {
    return AuthUser(
      publicId: publicId ?? this.publicId,
      displayName: displayName ?? this.displayName,
      email: email ?? this.email,
      emailVerified: emailVerified ?? this.emailVerified,
    );
  }

  Map<String, Object> toJson() => {
        'publicId': publicId,
        'displayName': displayName,
        'email': email,
        'emailVerified': emailVerified,
      };

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        publicId: json['publicId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        email: json['email'] as String? ?? '',
        emailVerified: json['emailVerified'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.publicId == publicId &&
      other.displayName == displayName &&
      other.email == email &&
      other.emailVerified == emailVerified;

  @override
  int get hashCode => Object.hash(publicId, displayName, email, emailVerified);
}

/// A live session: the opaque token the server issued, and whose it is.
@immutable
class AuthSession {
  final String token;

  /// Absolute expiry. The server also ends a session after a week without
  /// use, which slides and so is not known here: an `UNAUTHENTICATED` answer
  /// is the only reliable signal.
  final DateTime expiresAt;
  final AuthUser user;

  const AuthSession({required this.token, required this.expiresAt, required this.user});

  AuthSession copyWith({AuthUser? user}) =>
      AuthSession(token: token, expiresAt: expiresAt, user: user ?? this.user);
}
