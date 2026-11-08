import 'package:app/core/commands/categories/grpc_commands.dart';
import 'package:app/gen/music_room/v1/services/auth_service.pbgrpc.dart';

// One command per AuthService RPC. RpcCallCommand.call maps GrpcError to
// AppError, so nothing above the source sees a raw gRPC error.

class RegisterCommand extends RpcCallCommand<RegisterRequest, RegisterResponse, AuthServiceClient> {
  const RegisterCommand(super.request);

  @override
  Future<RegisterResponse> execute(AuthServiceClient client, RegisterRequest request) =>
      client.register(request);
}

class LoginCommand extends RpcCallCommand<LoginRequest, LoginResponse, AuthServiceClient> {
  const LoginCommand(super.request);

  @override
  Future<LoginResponse> execute(AuthServiceClient client, LoginRequest request) =>
      client.login(request);
}

class LogoutCommand extends RpcCallCommand<LogoutRequest, LogoutResponse, AuthServiceClient> {
  const LogoutCommand(super.request);

  @override
  Future<LogoutResponse> execute(AuthServiceClient client, LogoutRequest request) =>
      client.logout(request);
}

class RequestEmailVerificationCommand extends RpcCallCommand<RequestEmailVerificationRequest,
    RequestEmailVerificationResponse, AuthServiceClient> {
  const RequestEmailVerificationCommand(super.request);

  @override
  Future<RequestEmailVerificationResponse> execute(
    AuthServiceClient client,
    RequestEmailVerificationRequest request,
  ) =>
      client.requestEmailVerification(request);
}

class VerifyEmailCommand
    extends RpcCallCommand<VerifyEmailRequest, VerifyEmailResponse, AuthServiceClient> {
  const VerifyEmailCommand(super.request);

  @override
  Future<VerifyEmailResponse> execute(AuthServiceClient client, VerifyEmailRequest request) =>
      client.verifyEmail(request);
}

class OAuthLoginCommand
    extends RpcCallCommand<OAuthLoginRequest, OAuthLoginResponse, AuthServiceClient> {
  const OAuthLoginCommand(super.request);

  @override
  Future<OAuthLoginResponse> execute(AuthServiceClient client, OAuthLoginRequest request) =>
      client.oAuthLogin(request);
}

class RequestPasswordResetCommand extends RpcCallCommand<RequestPasswordResetRequest,
    RequestPasswordResetResponse, AuthServiceClient> {
  const RequestPasswordResetCommand(super.request);

  @override
  Future<RequestPasswordResetResponse> execute(
    AuthServiceClient client,
    RequestPasswordResetRequest request,
  ) =>
      client.requestPasswordReset(request);
}

class ResetPasswordCommand
    extends RpcCallCommand<ResetPasswordRequest, ResetPasswordResponse, AuthServiceClient> {
  const ResetPasswordCommand(super.request);

  @override
  Future<ResetPasswordResponse> execute(AuthServiceClient client, ResetPasswordRequest request) =>
      client.resetPassword(request);
}

class LinkOAuthAccountCommand extends RpcCallCommand<LinkOAuthAccountRequest,
    LinkOAuthAccountResponse, AuthServiceClient> {
  const LinkOAuthAccountCommand(super.request);

  @override
  Future<LinkOAuthAccountResponse> execute(
    AuthServiceClient client,
    LinkOAuthAccountRequest request,
  ) =>
      client.linkOAuthAccount(request);
}

class UnlinkOAuthAccountCommand extends RpcCallCommand<UnlinkOAuthAccountRequest,
    UnlinkOAuthAccountResponse, AuthServiceClient> {
  const UnlinkOAuthAccountCommand(super.request);

  @override
  Future<UnlinkOAuthAccountResponse> execute(
    AuthServiceClient client,
    UnlinkOAuthAccountRequest request,
  ) =>
      client.unlinkOAuthAccount(request);
}

class ListOAuthAccountsCommand extends RpcCallCommand<ListOAuthAccountsRequest,
    ListOAuthAccountsResponse, AuthServiceClient> {
  const ListOAuthAccountsCommand(super.request);

  @override
  Future<ListOAuthAccountsResponse> execute(
    AuthServiceClient client,
    ListOAuthAccountsRequest request,
  ) =>
      client.listOAuthAccounts(request);
}
