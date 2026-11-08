import 'package:flutter_test/flutter_test.dart';
import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/models/auth/oauth_provider.dart';
import 'package:app/core/network/auth/auth_interceptor.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/data/auth_source.dart';
import 'package:app/gen/music_room/v1/services/auth_service.pbgrpc.dart';

/// A real gRPC server on a loopback port, so the interceptor and the source
/// are tested over the wire, metadata and status codes included.
class FakeAuthService extends AuthServiceBase {
  /// The `authorization` header each method received, by method name.
  final Map<String, String?> headers = {};

  /// Methods that answer UNAUTHENTICATED.
  final Set<String> rejecting = {};

  void _record(String method, ServiceCall call) {
    headers[method] = call.clientMetadata?['authorization'];
    if (rejecting.contains(method)) {
      throw const GrpcError.unauthenticated('invalid session token');
    }
  }

  @override
  Future<RegisterResponse> register(ServiceCall call, RegisterRequest request) async {
    _record('register', call);
    if (request.email == 'taken@example.test') {
      throw const GrpcError.alreadyExists('email already taken');
    }
    return RegisterResponse(userPublicId: 'u-1', email: request.email);
  }

  @override
  Future<LoginResponse> login(ServiceCall call, LoginRequest request) async {
    _record('login', call);
    if (request.password != 'password1234') {
      throw const GrpcError.unauthenticated('invalid credentials');
    }
    return LoginResponse(
      sessionToken: 'fresh-token',
      expiresAtUnix: Int64(2000000000),
      userPublicId: 'u-1',
      displayName: 'neo',
      email: request.email,
      emailVerified: false,
    );
  }

  @override
  Future<LogoutResponse> logout(ServiceCall call, LogoutRequest request) async {
    _record('logout', call);
    return LogoutResponse();
  }

  @override
  Future<RequestEmailVerificationResponse> requestEmailVerification(
    ServiceCall call,
    RequestEmailVerificationRequest request,
  ) async {
    _record('requestEmailVerification', call);
    return RequestEmailVerificationResponse();
  }

  @override
  Future<VerifyEmailResponse> verifyEmail(ServiceCall call, VerifyEmailRequest request) async {
    _record('verifyEmail', call);
    if (request.code != '123456') {
      throw const GrpcError.invalidArgument('invalid code');
    }
    return VerifyEmailResponse();
  }

  @override
  Future<OAuthLoginResponse> oAuthLogin(ServiceCall call, OAuthLoginRequest request) async {
    _record('oAuthLogin', call);
    if (request.provider != 'intra42') {
      throw const GrpcError.invalidArgument('unknown provider');
    }
    return OAuthLoginResponse(
      sessionToken: 'oauth-token',
      expiresAtUnix: Int64(2000000000),
      userPublicId: 'u-2',
      displayName: 'trinity',
      email: 'trinity@example.test',
      emailVerified: true,
    );
  }

  @override
  Future<RequestPasswordResetResponse> requestPasswordReset(
    ServiceCall call,
    RequestPasswordResetRequest request,
  ) async {
    _record('requestPasswordReset', call);
    return RequestPasswordResetResponse();
  }

  @override
  Future<ResetPasswordResponse> resetPassword(
    ServiceCall call,
    ResetPasswordRequest request,
  ) async {
    _record('resetPassword', call);
    if (request.code != '123456') {
      throw const GrpcError.invalidArgument('invalid code');
    }
    return ResetPasswordResponse();
  }

  /// The provider of the last link / unlink request, as sent on the wire.
  String? linkedProvider;
  String? unlinkedProvider;

  @override
  Future<LinkOAuthAccountResponse> linkOAuthAccount(
    ServiceCall call,
    LinkOAuthAccountRequest request,
  ) async {
    _record('linkOAuthAccount', call);
    linkedProvider = request.provider;
    if (request.code == 'taken') {
      throw const GrpcError.alreadyExists('identity already linked to another account');
    }
    return LinkOAuthAccountResponse();
  }

  @override
  Future<UnlinkOAuthAccountResponse> unlinkOAuthAccount(
    ServiceCall call,
    UnlinkOAuthAccountRequest request,
  ) async {
    _record('unlinkOAuthAccount', call);
    unlinkedProvider = request.provider;
    if (request.provider == 'google') {
      throw const GrpcError.failedPrecondition('cannot remove the last login method');
    }
    return UnlinkOAuthAccountResponse();
  }

  @override
  Future<ListOAuthAccountsResponse> listOAuthAccounts(
    ServiceCall call,
    ListOAuthAccountsRequest request,
  ) async {
    _record('listOAuthAccounts', call);
    return ListOAuthAccountsResponse(
      accounts: [
        LinkedOAuthAccountDTO(
          provider: 'google',
          providerEmail: 'neo@example.test',
          linkedAtUnix: Int64(1700000000),
        ),
        LinkedOAuthAccountDTO(provider: 'intra42', linkedAtUnix: Int64(1800000000)),
        // A provider added on the server before this build knows it.
        LinkedOAuthAccountDTO(provider: 'myspace', linkedAtUnix: Int64(1900000000)),
      ],
      hasPassword: false,
    );
  }
}

void main() {
  late Server server;
  late FakeAuthService service;
  late ClientChannel channel;
  late SessionCredentials credentials;
  late AuthGrpcSource source;

  setUp(() async {
    service = FakeAuthService();
    server = Server.create(services: [service]);
    await server.serve(address: 'localhost', port: 0);
    channel = ClientChannel(
      'localhost',
      port: server.port!,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    credentials = SessionCredentials();
    source = AuthGrpcSource(channel, [AuthInterceptor(credentials)]);
  });

  tearDown(() async {
    await channel.shutdown();
    await server.shutdown();
  });

  group('AuthInterceptor', () {
    test('attaches the bearer token to authenticated calls', () async {
      credentials.set('abc');

      await source.requestEmailVerification();

      expect(service.headers['requestEmailVerification'], 'Bearer abc');
    });

    test('sends no header when signed out', () async {
      await source.requestEmailVerification();

      expect(service.headers['requestEmailVerification'], isNull);
    });

    test('never sends the token on the calls that create a session', () async {
      credentials.set('abc');

      await source.login(email: 'neo@example.test', password: 'password1234');
      await source.register(email: 'neo@example.test', password: 'password1234', displayName: 'neo');

      expect(service.headers['login'], isNull);
      expect(service.headers['register'], isNull);
    });

    test('never sends the token on the password reset calls', () async {
      credentials.set('stale');

      await source.requestPasswordReset('neo@example.test');
      await source.resetPassword(
        email: 'neo@example.test',
        code: '123456',
        newPassword: 'new-password',
      );

      expect(service.headers.containsKey('requestPasswordReset'), isTrue);
      expect(service.headers['requestPasswordReset'], isNull);
      expect(service.headers['resetPassword'], isNull);
    });

    test('reports an UNAUTHENTICATED answer on an authenticated call', () async {
      credentials.set('abc');
      String? rejected;
      credentials.onRejected = (token) => rejected = token;
      service.rejecting.add('logout');

      await expectLater(source.logout(), throwsA(isA<UnauthorizedError>()));
      await pumpEventQueue();

      expect(rejected, 'abc');
    });

    test('does not report a wrong password as a dead session', () async {
      credentials.set('abc');
      var reported = false;
      credentials.onRejected = (_) => reported = true;

      await expectLater(
        source.login(email: 'neo@example.test', password: 'wrong'),
        throwsA(isA<UnauthorizedError>()),
      );
      await pumpEventQueue();

      expect(reported, isFalse);
    });

    test('ignores a rejection of a token that has since been replaced', () async {
      credentials.set('old');
      var reported = false;
      credentials.onRejected = (_) => reported = true;
      service.rejecting.add('logout');

      final call = source.logout();
      credentials.set('new'); // logged in again while the old call was in flight
      await expectLater(call, throwsA(isA<UnauthorizedError>()));
      await pumpEventQueue();

      expect(reported, isFalse);
    });
  });

  group('AuthGrpcSource', () {
    test('login maps the response to a session', () async {
      final session = await source.login(email: 'neo@example.test', password: 'password1234');

      expect(session.token, 'fresh-token');
      expect(session.expiresAt, DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000));
      expect(session.user.displayName, 'neo');
      expect(session.user.emailVerified, isFalse);
    });

    test('oauth login sends the provider wire name and maps the session', () async {
      final session = await source.oauthLogin(
        provider: OAuthProvider.intra42,
        code: 'abc',
        redirectUri: 'musicroom://oauth',
      );

      expect(session.token, 'oauth-token');
      expect(session.user.email, 'trinity@example.test');
      expect(session.user.emailVerified, isTrue);
      expect(service.headers.containsKey('oAuthLogin'), isTrue);
    });

    test('a wrong reset code is invalid input', () async {
      await expectLater(
        source.resetPassword(email: 'neo@example.test', code: '000000', newPassword: 'x' * 8),
        throwsA(isA<InvalidInputError>()),
      );
    });

    test('maps server errors to typed AppErrors', () async {
      await expectLater(
        source.register(email: 'taken@example.test', password: 'password1234', displayName: 'x'),
        throwsA(isA<ConflictError>()),
      );
      await expectLater(source.verifyEmail('000000'), throwsA(isA<InvalidInputError>()));
    });

    test('lists linked accounts, dropping providers this build does not know', () async {
      final linked = await source.listOAuthAccounts();

      expect(linked.hasPassword, isFalse);
      expect(linked.accounts.map((a) => a.provider), [OAuthProvider.google, OAuthProvider.intra42]);
      expect(linked.of(OAuthProvider.google)?.email, 'neo@example.test');
      expect(linked.of(OAuthProvider.intra42)?.email, isNull); // '' on the wire
      expect(
        linked.of(OAuthProvider.google)?.linkedAt,
        DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
      );
    });

    test('link and unlink send the wire name, and map their refusals', () async {
      await source.linkOAuthAccount(
        provider: OAuthProvider.intra42,
        code: 'abc',
        redirectUri: 'musicroom://oauth',
      );
      expect(service.linkedProvider, 'intra42');

      await expectLater(
        source.linkOAuthAccount(
          provider: OAuthProvider.google,
          code: 'taken',
          redirectUri: 'musicroom://oauth',
        ),
        throwsA(isA<ConflictError>()),
      );
      await expectLater(
        source.unlinkOAuthAccount(OAuthProvider.google),
        throwsA(isA<PreconditionFailedError>()),
      );
      await source.unlinkOAuthAccount(OAuthProvider.intra42);
      expect(service.unlinkedProvider, 'intra42');
    });
  });
}
