// Package delegation implémente "Music Control Delegation" (sujet V.2.2) :
// un utilisateur enregistre les appareils rattachés à son compte et peut
// déléguer le contrôle de la lecture sur l'un d'eux à un ami, en licence
// permanente ou limitée à un événement.
package delegation

import (
	"context"
	"errors"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/auth/authn"
	"example.com/music-app/internal/realtime"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Service struct {
	pb.UnimplementedDelegationServiceServer
	pool *pgxpool.Pool
	repo *Repository
	hub  *realtime.Hub
}

// NewService : le pool pour les lectures, le repository pour les écritures qui
// doivent des tuples au graphe de permissions (voir repository.go), et le hub
// des WatchEvent ouverts (nil dans les tests).
func NewService(pool *pgxpool.Pool, repo *Repository, hub *realtime.Hub) *Service {
	return &Service{pool: pool, repo: repo, hub: hub}
}

// publishEvent réveille les WatchEvent d'un événement après une délégation
// limitée à lui, accordée ou retirée : viewer_can_control est recalculé pour
// chaque spectateur, donc les boutons de l'ami apparaissent ou disparaissent
// tout de suite, sans attendre le prochain vote ou morceau. Une licence
// permanente ne réveille rien : elle vaut pour tous les événements de l'hôte,
// et l'app ne propose que des licences par événement.
func (s *Service) publishEvent(license db.DeviceControlLicense) {
	if license.EventID.Valid {
		s.hub.Publish(realtime.Event(license.EventID.Int64))
	}
}

// RegisterDevice attache un appareil au compte de l'utilisateur (ré-appeler
// avec le même device_identifier met juste à jour la ligne existante).
func (s *Service) RegisterDevice(ctx context.Context, req *pb.RegisterDeviceRequest) (*pb.RegisterDeviceResponse, error) {
	if req.GetUserId() <= 0 || req.GetDeviceIdentifier() == "" || req.GetName() == "" {
		return nil, status.Error(codes.InvalidArgument, "user_id, device_identifier and name are required")
	}
	platform, err := validPlatform(req.GetPlatform())
	if err != nil {
		return nil, err
	}
	// La session de l'appel est rattachée à l'appareil : c'est ce qui donne aux
	// journaux d'activité (V.6) l'appareil de chaque requête suivante.
	identity, _ := authn.FromContext(ctx)
	device, err := s.repo.RegisterDevice(ctx, db.UpsertDeviceParams{
		UserID: req.GetUserId(), DeviceIdentifier: req.GetDeviceIdentifier(),
		Name: req.GetName(), Platform: platform,
		Model: optionalText(req.GetModel()), OsVersion: optionalText(req.GetOsVersion()),
		AppVersion: optionalText(req.GetAppVersion()),
	}, identity.SessionID)
	if err != nil {
		return nil, databaseError(err)
	}
	return &pb.RegisterDeviceResponse{Device: deviceDTO(device)}, nil
}

// ListMyDevices liste les appareils actifs rattachés au compte.
func (s *Service) ListMyDevices(ctx context.Context, req *pb.ListMyDevicesRequest) (*pb.ListMyDevicesResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	devices, err := db.New(s.pool).ListDevicesByUser(ctx, req.GetUserId())
	if err != nil {
		return nil, databaseError(err)
	}
	dtos := make([]*pb.DeviceDTO, len(devices))
	for i, d := range devices {
		dtos[i] = deviceDTO(d)
	}
	return &pb.ListMyDevicesResponse{Devices: dtos}, nil
}

// GrantDeviceControl délègue le contrôle d'un appareil à un ami (sujet
// V.2.2 : "give the music control to different friends"). Seul le
// propriétaire de l'appareil peut déléguer, et seulement à un ami.
func (s *Service) GrantDeviceControl(ctx context.Context, req *pb.GrantDeviceControlRequest) (*pb.GrantDeviceControlResponse, error) {
	if req.GetDeviceId() <= 0 || req.GetGranterUserId() <= 0 || req.GetGranteeUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "device_id, granter_user_id and grantee_user_id are required")
	}
	if req.GetGranterUserId() == req.GetGranteeUserId() {
		return nil, status.Error(codes.InvalidArgument, "cannot delegate control to yourself")
	}
	// Une licence vaut pour un événement, jamais pour tous (00021).
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_public_id is required: a licence is for one event")
	}
	// device#can_grant_control (le propriétaire) est déjà vérifié. L'amitié ne
	// l'est pas et ne peut pas l'être : c'est une précondition d'ÉCRITURE, il
	// n'y a rien à réévaluer au moment du Check -- ce qui est exactement
	// pourquoi bloquer ou retirer un ami doit activement révoquer les
	// délégations (docs/permissions.md §14).
	queries := db.New(s.pool)
	areFriends, err := queries.AreFriends(ctx, db.AreFriendsParams{
		UserID: req.GetGranterUserId(), OtherUserID: req.GetGranteeUserId(),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	if !areFriends {
		return nil, status.Error(codes.PermissionDenied, "device control can only be delegated to a friend")
	}

	license, err := s.repo.Grant(ctx, db.GrantDeviceControlParams{
		DeviceID: req.GetDeviceId(), GranteeUserID: req.GetGranteeUserId(),
		GrantedByID: req.GetGranterUserId(), EventID: req.GetEventId(),
	})
	if err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" {
			return nil, status.Error(codes.AlreadyExists, "this friend already controls this device for this scope")
		}
		return nil, databaseError(err)
	}
	s.publishEvent(license)
	dto := licenseDTO(license)
	dto.GranteeUserPublicId, dto.EventPublicId = req.GetGranteeUserPublicId(), req.GetEventPublicId()
	return &pb.GrantDeviceControlResponse{License: dto}, nil
}

// RevokeDeviceControl retire une délégation. Seul le propriétaire de
// l'appareil (celui qui l'a accordée) peut la retirer.
func (s *Service) RevokeDeviceControl(ctx context.Context, req *pb.RevokeDeviceControlRequest) (*pb.RevokeDeviceControlResponse, error) {
	if req.GetDeviceId() <= 0 || req.GetLicenseId() <= 0 || req.GetRevokerUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "device_id, license_id and revoker_user_id are required")
	}
	license, err := s.repo.Revoke(ctx, db.RevokeDeviceControlParams{
		ID: req.GetLicenseId(), DeviceID: req.GetDeviceId(), RevokerUserID: req.GetRevokerUserId(),
	})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, status.Error(codes.NotFound, "no such live delegation for this device")
		}
		return nil, databaseError(err)
	}
	s.publishEvent(license)
	return &pb.RevokeDeviceControlResponse{}, nil
}

// ListDeviceControlLicenses liste qui contrôle actuellement cet appareil.
// Réservé au propriétaire de l'appareil.
func (s *Service) ListDeviceControlLicenses(ctx context.Context, req *pb.ListDeviceControlLicensesRequest) (*pb.ListDeviceControlLicensesResponse, error) {
	if req.GetDeviceId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "device_id is required")
	}
	// device#can_view : le propriétaire, et personne d'autre.
	queries := db.New(s.pool)
	licenses, err := queries.ListDeviceControlLicensesByDevice(ctx, req.GetDeviceId())
	if err != nil {
		return nil, databaseError(err)
	}
	dtos := make([]*pb.DeviceControlLicenseDTO, len(licenses))
	for i, l := range licenses {
		dtos[i] = licenseDTO(db.DeviceControlLicense{
			ID: l.ID, DeviceID: l.DeviceID, GranteeUserID: l.GranteeUserID,
			GrantedByID: l.GrantedByID, EventID: l.EventID, CreatedAt: l.CreatedAt,
		})
		dtos[i].GranteeUserPublicId, dtos[i].EventPublicId = l.GranteePublicID.String(), l.EventPublicID.String()
	}
	return &pb.ListDeviceControlLicensesResponse{Licenses: dtos}, nil
}

// SetEventSpeaker fait d'un appareil de l'hôte celui qui joue la musique de
// l'événement (son enceinte), à la place de celui de son premier play. Les
// licences de l'événement suivent l'enceinte (Repository.SetEventSpeaker) :
// un ami qui pilotait l'ancienne pilote la nouvelle.
//
// event#can_change_settings (l'hôte) et device#can_grant_control (le
// propriétaire) sont déjà vérifiés : l'hôte, sur un appareil à lui. Reste
// l'événement terminé, que rien ne joue plus.
func (s *Service) SetEventSpeaker(ctx context.Context, req *pb.SetEventSpeakerRequest) (*pb.SetEventSpeakerResponse, error) {
	if req.GetEventId() <= 0 || req.GetDeviceId() <= 0 || req.GetHostUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id, device_id and host_user_id are required")
	}
	queries := db.New(s.pool)
	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	if event.Status == db.EventStatusEnded {
		return nil, status.Error(codes.FailedPrecondition, "the event has ended")
	}
	device, err := queries.GetDeviceByID(ctx, req.GetDeviceId())
	if err != nil {
		return nil, databaseError(err)
	}
	if err := s.repo.SetEventSpeaker(ctx, req.GetEventId(), req.GetDeviceId(), req.GetHostUserId()); err != nil {
		return nil, databaseError(err)
	}
	// L'enceinte a changé : chaque app ouverte sur l'événement doit savoir
	// si c'est elle qui joue, et les délégués si leur licence a suivi.
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.SetEventSpeakerResponse{Device: deviceDTO(device)}, nil
}

func deviceDTO(d db.Device) *pb.DeviceDTO {
	return &pb.DeviceDTO{
		Id: d.ID, PublicId: d.PublicID.String(), UserId: d.UserID, DeviceIdentifier: d.DeviceIdentifier,
		Name: d.Name, Platform: string(d.Platform), IsActive: d.IsActive,
	}
}

func licenseDTO(l db.DeviceControlLicense) *pb.DeviceControlLicenseDTO {
	return &pb.DeviceControlLicenseDTO{
		Id: l.ID, DeviceId: l.DeviceID, GranteeUserId: l.GranteeUserID,
		GrantedById: l.GrantedByID, EventId: l.EventID.Int64, CreatedAt: l.CreatedAt.Time.Unix(),
	}
}

// optionalText : une chaîne vide du proto devient NULL, pas "".
func optionalText(value string) pgtype.Text {
	return pgtype.Text{String: value, Valid: value != ""}
}

func validPlatform(value string) (db.DevicePlatform, error) {
	switch value {
	case "ios", "android", "web", "desktop":
		return db.DevicePlatform(value), nil
	default:
		return "", status.Error(codes.InvalidArgument, "platform must be ios, android, web or desktop")
	}
}

func databaseError(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return status.Error(codes.NotFound, "device or license not found")
	}
	return status.Error(codes.Internal, "delegation database operation failed")
}
