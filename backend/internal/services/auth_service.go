package services

import (
	"context"
	"errors"
	"example.com/music-app/internal/clientip"
	"log"

	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/auth/authn"
	"example.com/music-app/internal/auth/emailverif"
	"example.com/music-app/internal/auth/login"
	"example.com/music-app/internal/auth/logout"
	"example.com/music-app/internal/auth/oauth"
	"example.com/music-app/internal/auth/onetimecode"
	"example.com/music-app/internal/auth/passwordreset"
	"example.com/music-app/internal/auth/register"
	"example.com/music-app/internal/user"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// AuthServer traduit entre le protobuf et le domaine, et transforme les
// erreurs métier en codes gRPC. Aucune règle métier, aucun SQL.
type AuthServer struct {
	pb.UnimplementedAuthServiceServer
	register      *register.Service
	login         *login.Service
	logout        *logout.Service
	emailVerif    *emailverif.Service
	oauth         *oauth.Service
	passwordReset *passwordreset.Service
}

func NewAuthServer(registerSvc *register.Service, loginSvc *login.Service, logoutSvc *logout.Service, emailVerifSvc *emailverif.Service, oauthSvc *oauth.Service, passwordResetSvc *passwordreset.Service) *AuthServer {
	return &AuthServer{
		register:      registerSvc,
		login:         loginSvc,
		logout:        logoutSvc,
		emailVerif:    emailVerifSvc,
		oauth:         oauthSvc,
		passwordReset: passwordResetSvc,
	}
}

func (s *AuthServer) Register(ctx context.Context, req *pb.RegisterRequest) (*pb.RegisterResponse, error) {
	created, err := s.register.Register(ctx, req.GetEmail(), req.GetPassword(), req.GetDisplayName())
	if err != nil {
		return nil, toGRPCError(err)
	}

	// Le premier code part a l'inscription (sujet V.1 : "the application must
	// demand a mail validation"). Un echec d'envoi ne defait pas le compte :
	// il existe, et RequestEmailVerification renvoie un code une fois connecte.
	if err := s.emailVerif.RequestCode(ctx, created.ID, created.Email); err != nil {
		log.Printf("auth: register: verification code for user %d: %v", created.ID, err)
	}

	return &pb.RegisterResponse{
		UserPublicId: created.PublicID,
		DisplayName:  created.DisplayName,
		Email:        created.Email,
	}, nil
}

// toGRPCError est la frontière : les erreurs du domaine deviennent des codes
// que le client comprend. Une erreur inconnue reste volontairement opaque.
func toGRPCError(err error) error {
	switch {
	case errors.Is(err, user.ErrEmailTaken),
		errors.Is(err, user.ErrDisplayNameTaken):
		return status.Error(codes.AlreadyExists, err.Error())
	case errors.Is(err, register.ErrEmailInvalid),
		errors.Is(err, register.ErrPasswordTooShort),
		errors.Is(err, register.ErrDisplayNameInvalid):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, login.ErrInvalidCredentials):
		return status.Error(codes.Unauthenticated, err.Error())
	case errors.Is(err, login.ErrTooManyAttempts),
		errors.Is(err, onetimecode.ErrTooManyRequests):
		return status.Error(codes.ResourceExhausted, err.Error())
	case errors.Is(err, logout.ErrMissingToken):
		return status.Error(codes.Unauthenticated, err.Error())
	case errors.Is(err, emailverif.ErrInvalidCode):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, emailverif.ErrAlreadyVerified):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, oauth.ErrUnknownProvider):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, oauth.ErrNoEmail):
		return status.Error(codes.FailedPrecondition, "provider did not return an email")
	case errors.Is(err, oauth.ErrExchangeFailed),
		errors.Is(err, user.ErrIdentityAlreadyLinked),
		errors.Is(err, user.ErrProviderAlreadyLinked):
		return status.Error(codes.Unauthenticated, "oauth login failed")
	default:
		return status.Error(codes.Internal, "internal error")
	}
}

func (s *AuthServer) Login(ctx context.Context, req *pb.LoginRequest) (*pb.LoginResponse, error) {
	res, err := s.login.Login(ctx, req.GetEmail(), req.GetPassword(), clientip.FromContext(ctx))
	if err != nil {
		return nil, toGRPCError(err)
	}

	return &pb.LoginResponse{
		SessionToken:  res.SessionToken,
		ExpiresAtUnix: res.ExpiresAt.Unix(),
		UserPublicId:  res.UserPublicID,
		DisplayName:   res.DisplayName,
		Email:         res.Email,
		EmailVerified: res.EmailVerified,
	}, nil
}

func (s *AuthServer) Logout(ctx context.Context, req *pb.LogoutRequest) (*pb.LogoutResponse, error) {
	token, err := bearerToken(ctx)
	if err != nil {
		return nil, status.Error(codes.Unauthenticated, "missing session token")
	}

	if err := s.logout.Logout(ctx, token); err != nil {
		return nil, toGRPCError(err)
	}

	return &pb.LogoutResponse{}, nil
}

func (s *AuthServer) RequestEmailVerification(ctx context.Context, req *pb.RequestEmailVerificationRequest) (*pb.RequestEmailVerificationResponse, error) {
	identity, ok := authn.FromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing session token")
	}
	if err := s.emailVerif.Resend(ctx, identity.UserID); err != nil {
		return nil, toGRPCError(err)
	}
	return &pb.RequestEmailVerificationResponse{}, nil
}

func (s *AuthServer) VerifyEmail(ctx context.Context, req *pb.VerifyEmailRequest) (*pb.VerifyEmailResponse, error) {
	identity, ok := authn.FromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing session token")
	}
	if err := s.emailVerif.Verify(ctx, identity.UserID, req.GetCode()); err != nil {
		return nil, toGRPCError(err)
	}
	return &pb.VerifyEmailResponse{}, nil
}

func (s *AuthServer) OAuthLogin(ctx context.Context, req *pb.OAuthLoginRequest) (*pb.OAuthLoginResponse, error) {
	res, err := s.oauth.Login(ctx, req.GetProvider(), req.GetCode(), req.GetRedirectUri())
	if err != nil {
		return nil, toGRPCError(err)
	}

	return &pb.OAuthLoginResponse{
		SessionToken:  res.SessionToken,
		ExpiresAtUnix: res.ExpiresAt.Unix(),
		UserPublicId:  res.UserPublicID,
		DisplayName:   res.DisplayName,
		Email:         res.Email,
		EmailVerified: res.EmailVerified,
	}, nil
}

func (s *AuthServer) RequestPasswordReset(ctx context.Context, req *pb.RequestPasswordResetRequest) (*pb.RequestPasswordResetResponse, error) {
	if err := s.passwordReset.RequestReset(ctx, req.GetEmail()); err != nil {
		log.Printf("auth: password reset request: %v", err)
	}
	return &pb.RequestPasswordResetResponse{}, nil
}

func (s *AuthServer) ResetPassword(ctx context.Context, req *pb.ResetPasswordRequest) (*pb.ResetPasswordResponse, error) {
	if err := s.passwordReset.Reset(ctx, req.GetEmail(), req.GetCode(), req.GetNewPassword()); err != nil {
		return nil, toGRPCError(err)
	}
	return &pb.ResetPasswordResponse{}, nil
}

func (s *AuthServer) LinkOAuthAccount(ctx context.Context, req *pb.LinkOAuthAccountRequest) (*pb.LinkOAuthAccountResponse, error) {
	identity, ok := authn.FromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing session token")
	}

	err := s.oauth.Link(ctx, identity.UserID, req.GetProvider(), req.GetCode(), req.GetRedirectUri())
	switch {
	case err == nil:
		return &pb.LinkOAuthAccountResponse{}, nil
	case errors.Is(err, user.ErrIdentityAlreadyLinked),
		errors.Is(err, user.ErrProviderAlreadyLinked):
		return nil, status.Error(codes.AlreadyExists, err.Error())
	case errors.Is(err, oauth.ErrExchangeFailed):
		return nil, status.Error(codes.InvalidArgument, "oauth exchange failed")
	default:
		return nil, toGRPCError(err)
	}
}

func (s *AuthServer) UnlinkOAuthAccount(ctx context.Context, req *pb.UnlinkOAuthAccountRequest) (*pb.UnlinkOAuthAccountResponse, error) {
	identity, ok := authn.FromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing session token")
	}

	err := s.oauth.Unlink(ctx, identity.UserID, req.GetProvider())
	switch {
	case err == nil:
		return &pb.UnlinkOAuthAccountResponse{}, nil
	case errors.Is(err, user.ErrLastLoginMethod):
		return nil, status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, user.ErrProviderNotLinked):
		return nil, status.Error(codes.NotFound, err.Error())
	default:
		return nil, toGRPCError(err)
	}
}

func (s *AuthServer) ListOAuthAccounts(ctx context.Context, _ *pb.ListOAuthAccountsRequest) (*pb.ListOAuthAccountsResponse, error) {
	identity, ok := authn.FromContext(ctx)
	if !ok {
		return nil, status.Error(codes.Unauthenticated, "missing session token")
	}

	identities, hasPassword, err := s.oauth.List(ctx, identity.UserID)
	if err != nil {
		return nil, toGRPCError(err)
	}

	accounts := make([]*pb.LinkedOAuthAccountDTO, 0, len(identities))
	for _, li := range identities {
		accounts = append(accounts, &pb.LinkedOAuthAccountDTO{
			Provider:      li.Provider,
			ProviderEmail: li.Email,
			LinkedAtUnix:  li.LinkedAt.Unix(),
		})
	}
	return &pb.ListOAuthAccountsResponse{Accounts: accounts, HasPassword: hasPassword}, nil
}
