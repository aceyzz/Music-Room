import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/gen/music_room/v1/services/auth_service.pb.dart';

// AuthService is gRPC-only (no REST mapping on the gateway), so unlike the
// other models there is no OpenAPI/JSON mapper to keep in step with this one.

extension LoginResponseMapping on LoginResponse {
  AuthSession toDomain() => AuthSession(
        token: sessionToken,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtUnix.toInt() * 1000),
        user: AuthUser(
          publicId: userPublicId,
          displayName: displayName,
          email: email,
          emailVerified: emailVerified,
        ),
      );
}

extension OAuthLoginResponseMapping on OAuthLoginResponse {
  AuthSession toDomain() => AuthSession(
        token: sessionToken,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAtUnix.toInt() * 1000),
        user: AuthUser(
          publicId: userPublicId,
          displayName: displayName,
          email: email,
          emailVerified: emailVerified,
        ),
      );
}

extension ListOAuthAccountsResponseMapping on ListOAuthAccountsResponse {
  /// A provider this build does not know is dropped: the page has no row for
  /// it. It still counts in [LinkedAccounts.canUnlink]'s favour on the
  /// server, which is the side that decides.
  LinkedAccounts toDomain() => LinkedAccounts(
        accounts: [
          for (final account in accounts)
            if (OAuthProvider.fromWireName(account.provider) case final provider?)
              LinkedAccount(
                provider: provider,
                email: account.providerEmail.isEmpty ? null : account.providerEmail,
                linkedAt: DateTime.fromMillisecondsSinceEpoch(
                  account.linkedAtUnix.toInt() * 1000,
                ),
              ),
        ],
        hasPassword: hasPassword,
      );
}
