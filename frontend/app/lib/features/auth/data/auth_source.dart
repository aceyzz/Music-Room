import 'package:app/core/mapping/auth.mapping.dart';
import 'package:app/core/models/auth/auth_user.dart';
import 'package:app/core/models/auth/linked_account.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/network/app_network.dart';
import 'package:app/core/sources/grpc_source.dart';
import 'package:app/features/auth/data/commands/auth_grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/auth_service.pbgrpc.dart';

/// What the auth feature needs from the server. An interface so the store and
/// repository can be tested without a channel.
abstract interface class AuthApi {
  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  });
  Future<AuthSession> login({required String email, required String password});
  Future<void> logout();
  Future<void> requestEmailVerification();
  Future<void> verifyEmail(String code);

  /// Exchanges a provider's authorization [code] for a session. [redirectUri]
  /// must be the one the code was issued for, or the provider refuses it.
  Future<AuthSession> oauthLogin({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  });

  /// Emails a reset code. Succeeds whether or not the address has an account.
  Future<void> requestPasswordReset(String email);

  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  });
}

/// The providers linked to the signed-in account (Profile, Linked accounts).
/// Apart from [AuthApi] because nothing about the session goes through it:
/// the session store and its fakes have no use for these.
abstract interface class LinkedAccountsApi {
  Future<LinkedAccounts> listOAuthAccounts();

  /// Links the identity behind [code] to the signed-in account. Throws
  /// ConflictError if that identity belongs to another account, or the
  /// account already has one from this provider.
  Future<void> linkOAuthAccount({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  });

  /// Throws PreconditionFailedError if it is the account's last way to sign
  /// in, NotFoundError if the provider was not linked.
  Future<void> unlinkOAuthAccount(OAuthProvider provider);
}

/// Native gRPC implementation of [AuthApi] and [LinkedAccountsApi].
///
/// Native only: AuthService has no REST mapping on the gateway, so there is
/// no web half to swap in by conditional import yet.
///
/// The session token is not passed here. The client is built with the
/// network's interceptors, which attach whatever token [SessionCredentials]
/// holds (core/network/auth/auth_interceptor.dart).
class AuthGrpcSource extends GrpcSource<AuthSession, AuthServiceClient>
    implements AuthApi, LinkedAccountsApi {
  @override
  final AuthServiceClient client;

  AuthGrpcSource(super.channel, super.interceptors)
      : client = AuthServiceClient(channel, interceptors: interceptors);

  static AuthGrpcSource from(AppNetwork appNetwork) =>
      GrpcSource.create(appNetwork, AuthGrpcSource.new);

  @override
  Future<void> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    await RegisterCommand(
      RegisterRequest(email: email, password: password, displayName: displayName),
    )(client);
  }

  @override
  Future<AuthSession> login({required String email, required String password}) async {
    final response = await LoginCommand(LoginRequest(email: email, password: password))(client);
    return response.toDomain();
  }

  @override
  Future<void> logout() async {
    await LogoutCommand(LogoutRequest())(client);
  }

  @override
  Future<void> requestEmailVerification() async {
    await RequestEmailVerificationCommand(RequestEmailVerificationRequest())(client);
  }

  @override
  Future<void> verifyEmail(String code) async {
    await VerifyEmailCommand(VerifyEmailRequest(code: code))(client);
  }

  @override
  Future<AuthSession> oauthLogin({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  }) async {
    final response = await OAuthLoginCommand(
      OAuthLoginRequest(provider: provider.wireName, code: code, redirectUri: redirectUri),
    )(client);
    return response.toDomain();
  }

  @override
  Future<void> requestPasswordReset(String email) async {
    await RequestPasswordResetCommand(RequestPasswordResetRequest(email: email))(client);
  }

  @override
  Future<void> resetPassword({
    required String email,
    required String code,
    required String newPassword,
  }) async {
    await ResetPasswordCommand(
      ResetPasswordRequest(email: email, code: code, newPassword: newPassword),
    )(client);
  }

  @override
  Future<LinkedAccounts> listOAuthAccounts() async {
    final response = await ListOAuthAccountsCommand(ListOAuthAccountsRequest())(client);
    return response.toDomain();
  }

  @override
  Future<void> linkOAuthAccount({
    required OAuthProvider provider,
    required String code,
    required String redirectUri,
  }) async {
    await LinkOAuthAccountCommand(
      LinkOAuthAccountRequest(provider: provider.wireName, code: code, redirectUri: redirectUri),
    )(client);
  }

  @override
  Future<void> unlinkOAuthAccount(OAuthProvider provider) async {
    await UnlinkOAuthAccountCommand(UnlinkOAuthAccountRequest(provider: provider.wireName))(client);
  }
}
