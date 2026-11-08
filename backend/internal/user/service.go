package user

import (
	"context"
	"errors"
	"strings"
	"time"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/media"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// avatarSize : un seul thumbnail carré, pas de variante "medium" -- rien
// dans le sujet (V.1) ne demande plusieurs tailles d'avatar.
const avatarSize = 512

// Service implémente UserService : profil (V.1), préférences musicales
// (V.1), graphe social (V.1 amis) et avatar (V.1, via image-service). Ne pas
// confondre avec Repository, qui sert les besoins internes de
// l'inscription/connexion.
type Service struct {
	pb.UnimplementedUserServiceServer
	pool    *pgxpool.Pool
	repo    *Repository
	images  *media.Client
	avatars *media.Store
}

// NewService partage le Repository avec l'inscription et la connexion. Ce n'est
// pas un accident de câblage : le profil, l'avatar et le graphe social écrivent
// tous des tuples sur l'objet `user`, et les mettre ailleurs voudrait dire deux
// endroits qui savent quels tuples un compte possède.
func NewService(pool *pgxpool.Pool, repo *Repository, images *media.Client, avatars *media.Store) *Service {
	return &Service{pool: pool, repo: repo, images: images, avatars: avatars}
}

func (s *Service) beginTx(ctx context.Context) (pgx.Tx, *db.Queries, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, nil, status.Error(codes.Internal, "could not start transaction")
	}
	return tx, db.New(tx), nil
}

func commitTx(ctx context.Context, tx pgx.Tx, failureMsg string) error {
	if err := tx.Commit(ctx); err != nil {
		return status.Error(codes.Internal, failureMsg)
	}
	return nil
}

// GetUser renvoie le profil d'un utilisateur, filtré champ par champ selon
// la visibilité configurée et la relation avec viewer_id (V.1 : "4 niveaux
// de confidentialité" -- ici self / friends / public, private se résolvant
// à "personne d'autre que le propriétaire").
func (s *Service) GetUser(ctx context.Context, req *pb.GetUserRequest) (*pb.GetUserResponse, error) {
	if req.GetId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "id is required")
	}
	queries := db.New(s.pool)

	target, err := queries.GetUserByID(ctx, req.GetId())
	if err != nil {
		return nil, databaseError(err, "user not found")
	}

	// user#can_view_profile a été vérifié en amont (la carte de base :
	// display_name et avatar, refusée si l'un a bloqué l'autre). Les sept
	// champs à visibilité propre sont triés ici, depuis user_profiles.*_visibility
	// et la ligne friendships : ce n'est pas un contrôle d'accès mais une
	// rédaction, qui décide ce que la réponse contient (voir access.go).
	rel, err := s.relationFor(ctx, queries, req.GetViewerId(), req.GetId())
	if err != nil {
		return nil, err
	}

	dto, err := s.buildUserDTO(ctx, queries, target, rel)
	if err != nil {
		return nil, err
	}
	return &pb.GetUserResponse{User: dto}, nil
}

// relationFor ne consulte friendships que quand c'est nécessaire : self et
// anonyme (viewer_id = 0) se répondent sans requête.
func (s *Service) relationFor(ctx context.Context, queries *db.Queries, viewerID, targetID int64) (relation, error) {
	if viewerID == 0 || viewerID == targetID {
		return resolveRelation(viewerID, targetID, false), nil
	}
	areFriends, err := queries.AreFriends(ctx, db.AreFriendsParams{UserID: viewerID, OtherUserID: targetID})
	if err != nil {
		return relationStranger, status.Error(codes.Internal, "could not check friendship")
	}
	return resolveRelation(viewerID, targetID, areFriends), nil
}

// buildUserDTO assemble le UserDTO pour `rel` : chaque champ de profil ne
// passe que si sa visibilité l'autorise, l'avatar et les préférences suivent
// la même règle que le reste (docs/data-model.md 6).
func (s *Service) buildUserDTO(ctx context.Context, queries *db.Queries, target db.GetUserByIDRow, rel relation) (*pb.UserDTO, error) {
	profile, err := queries.GetUserProfile(ctx, target.ID)
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, status.Error(codes.Internal, "could not load profile")
		}
		profile = defaultProfile(target.ID)
	}

	avatarKey := ""
	if profile.AvatarImageID.Valid {
		if img, err := queries.GetImageByID(ctx, profile.AvatarImageID.Int64); err == nil {
			avatarKey = img.StorageKey
		}
	}

	dto := &pb.UserDTO{
		Id: target.ID, PublicId: publicIDText(target.PublicID), DisplayName: target.DisplayName,
		AvatarStorageKey:      avatarKey,
		FirstNameVisibility:   string(profile.FirstNameVisibility),
		LastNameVisibility:    string(profile.LastNameVisibility),
		BioVisibility:         string(profile.BioVisibility),
		BirthDateVisibility:   string(profile.BirthDateVisibility),
		LocationVisibility:    string(profile.LocationVisibility),
		PhoneVisibility:       string(profile.PhoneVisibility),
		PreferencesVisibility: string(profile.PreferencesVisibility),
	}

	if visibleTo(profile.FirstNameVisibility, rel) {
		dto.FirstName = textOrEmpty(profile.FirstName)
	}
	if visibleTo(profile.LastNameVisibility, rel) {
		dto.LastName = textOrEmpty(profile.LastName)
	}
	if visibleTo(profile.BioVisibility, rel) {
		dto.Bio = textOrEmpty(profile.Bio)
	}
	if visibleTo(profile.BirthDateVisibility, rel) {
		dto.BirthDate = formatDate(profile.BirthDate)
	}
	if visibleTo(profile.LocationVisibility, rel) {
		dto.City = textOrEmpty(profile.City)
		dto.CountryCode = textOrEmpty(profile.CountryCode)
	}
	if visibleTo(profile.PhoneVisibility, rel) {
		dto.PhoneNumber = textOrEmpty(profile.PhoneNumber)
	}
	if visibleTo(profile.PreferencesVisibility, rel) {
		prefs, err := queries.ListUserMusicPreferences(ctx, target.ID)
		if err != nil {
			return nil, status.Error(codes.Internal, "could not load music preferences")
		}
		dto.MusicPreferences = musicPreferencesDTO(prefs)
	}

	return dto, nil
}

// UpdateUserProfile : mise à jour partielle (champ absent = inchangé, champ
// présent et vide = effacé, voir profileParams). Toujours vu par son propre
// propriétaire, donc la réponse renvoie le profil sans aucun filtrage.
func (s *Service) UpdateUserProfile(ctx context.Context, req *pb.UpdateUserProfileRequest) (*pb.UpdateUserProfileResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	params, err := profileParams(req)
	if err != nil {
		return nil, err
	}
	queries := db.New(s.pool)

	target, err := queries.GetUserByID(ctx, req.GetUserId())
	if err != nil {
		return nil, databaseError(err, "user not found")
	}

	if _, err := s.repo.UpdateProfile(ctx, params); err != nil {
		return nil, translateProfileError(err)
	}

	dto, err := s.buildUserDTO(ctx, queries, target, relationSelf)
	if err != nil {
		return nil, err
	}
	return &pb.UpdateUserProfileResponse{User: dto}, nil
}

// profileParams traduit la requête en paramètres d'UpsertUserProfile.
//
// Les sept champs du profil sont `optional` dans le proto : absent (nil) =
// Set<Champ> false, la colonne garde sa valeur ; présent = Set<Champ> true, et
// une chaîne vide devient NULL, ce qui efface le champ. Sans cette présence,
// "" voulait dire à la fois "pas envoyé" et "vidé", et un champ rempli ne
// pouvait plus jamais redevenir vide (db/query/profiles.sql).
//
// Les visibilités restent des chaînes simples, "" = inchangé : une portée a
// toujours une valeur, il n'y a rien à effacer.
func profileParams(req *pb.UpdateUserProfileRequest) (db.UpsertUserProfileParams, error) {
	p := db.UpsertUserProfileParams{UserID: req.GetUserId()}

	p.SetFirstName, p.FirstName = presentText(req.FirstName)
	p.SetLastName, p.LastName = presentText(req.LastName)
	p.SetBio, p.Bio = presentText(req.Bio)
	p.SetCity, p.City = presentText(req.City)
	p.SetCountryCode, p.CountryCode = presentText(req.CountryCode)
	p.SetPhoneNumber, p.PhoneNumber = presentText(req.PhoneNumber)
	if req.BirthDate != nil {
		birthDate, err := optionalDate(*req.BirthDate)
		if err != nil {
			return db.UpsertUserProfileParams{}, err
		}
		p.SetBirthDate, p.BirthDate = true, birthDate
	}

	scopes := []struct {
		value string
		dest  *db.NullVisibilityScope
	}{
		{req.GetFirstNameVisibility(), &p.FirstNameVisibility},
		{req.GetLastNameVisibility(), &p.LastNameVisibility},
		{req.GetBioVisibility(), &p.BioVisibility},
		{req.GetBirthDateVisibility(), &p.BirthDateVisibility},
		{req.GetLocationVisibility(), &p.LocationVisibility},
		{req.GetPhoneVisibility(), &p.PhoneVisibility},
		{req.GetPreferencesVisibility(), &p.PreferencesVisibility},
	}
	for _, scope := range scopes {
		v, err := optionalVisibility(scope.value)
		if err != nil {
			return db.UpsertUserProfileParams{}, err
		}
		*scope.dest = v
	}
	return p, nil
}

// presentText : (false, NULL) pour un champ absent, (true, NULL) pour un
// champ envoyé vide -- l'effacer --, (true, valeur) sinon.
func presentText(field *string) (bool, pgtype.Text) {
	if field == nil {
		return false, pgtype.Text{}
	}
	return true, optionalText(*field)
}

// UploadAvatar stocke l'original envoyé, en dérive un thumbnail carré via
// image-service, et remplace l'avatar existant s'il y en avait un (fichiers
// ET lignes `images` de l'ancien avatar supprimés). Les deux nouveaux
// fichiers sont écrits sur disque AVANT le commit -- une ligne `images` ne
// doit jamais pointer vers un fichier qui n'existe pas encore -- et les
// anciens fichiers ne sont supprimés qu'APRÈS, une fois la transaction
// commitée : un rollback ne doit pas laisser le profil sans avatar valide.
func (s *Service) UploadAvatar(ctx context.Context, req *pb.UploadAvatarRequest) (*pb.UploadAvatarResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	ext, err := validAvatarUpload(req.GetContentType(), req.GetImageData())
	if err != nil {
		return nil, err
	}

	queries := db.New(s.pool)
	target, err := queries.GetUserByID(ctx, req.GetUserId())
	if err != nil {
		return nil, databaseError(err, "user not found")
	}

	thumb, err := s.images.Resize(ctx, req.GetImageData(), avatarSize, avatarSize)
	if err != nil {
		if errors.Is(err, media.ErrInvalidImage) {
			return nil, status.Error(codes.InvalidArgument, "invalid image data")
		}
		return nil, status.Error(codes.Internal, "could not process image")
	}

	originalKey, err := media.NewObjectKey("avatars", ext)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not generate storage key")
	}
	thumbKey, err := media.NewObjectKey("avatars", "png")
	if err != nil {
		return nil, status.Error(codes.Internal, "could not generate storage key")
	}
	if err := s.avatars.Save(originalKey, req.GetImageData()); err != nil {
		return nil, status.Error(codes.Internal, "could not save image")
	}
	if err := s.avatars.Save(thumbKey, thumb); err != nil {
		return nil, status.Error(codes.Internal, "could not save image")
	}

	// L'avatar précédent est lu hors transaction : c'est un pointeur que seul son
	// propriétaire modifie, et la transaction n'a pas à couvrir la lecture.
	previousProfile, err := queries.GetUserProfile(ctx, req.GetUserId())
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, status.Error(codes.Internal, "could not load profile")
	}
	var previousAvatar pgtype.Int8
	if err == nil {
		previousAvatar = previousProfile.AvatarImageID
	}

	staleFiles, err := s.repo.SetAvatar(ctx, AvatarUpload{
		UserID:                req.GetUserId(),
		ContentType:           req.GetContentType(),
		OriginalKey:           originalKey,
		OriginalSize:          len(req.GetImageData()),
		ThumbKey:              thumbKey,
		ThumbSize:             len(thumb),
		ThumbPixels:           avatarSize,
		PreviousAvatarImageID: previousAvatar,
	})
	if err != nil {
		return nil, translateProfileError(err)
	}
	// Seulement après le commit : un rollback ne doit pas laisser le profil sans
	// avatar valide.
	for _, key := range staleFiles {
		s.avatars.Delete(key)
	}

	dto, err := s.buildUserDTO(ctx, queries, target, relationSelf)
	if err != nil {
		return nil, err
	}
	return &pb.UploadAvatarResponse{User: dto}, nil
}

// DeleteAvatar retire l'avatar courant, s'il y en a un -- pas d'erreur si
// l'utilisateur n'en avait pas (une suppression sans effet reste un succès).
func (s *Service) DeleteAvatar(ctx context.Context, req *pb.DeleteAvatarRequest) (*pb.DeleteAvatarResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	queries := db.New(s.pool)

	target, err := queries.GetUserByID(ctx, req.GetUserId())
	if err != nil {
		return nil, databaseError(err, "user not found")
	}

	profile, err := queries.GetUserProfile(ctx, req.GetUserId())
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, status.Error(codes.Internal, "could not load profile")
	}
	var currentAvatar pgtype.Int8
	if err == nil {
		currentAvatar = profile.AvatarImageID
	}

	staleFiles, err := s.repo.ClearAvatar(ctx, req.GetUserId(), currentAvatar)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not remove avatar")
	}
	for _, key := range staleFiles {
		s.avatars.Delete(key)
	}

	dto, err := s.buildUserDTO(ctx, queries, target, relationSelf)
	if err != nil {
		return nil, err
	}
	return &pb.DeleteAvatarResponse{User: dto}, nil
}

// SetMusicPreferences remplace tout l'ensemble (delete + reinsert dans une
// transaction) : le client envoie l'état complet de son sélecteur de genres,
// jamais un delta.
func (s *Service) SetMusicPreferences(ctx context.Context, req *pb.SetMusicPreferencesRequest) (*pb.SetMusicPreferencesResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	for _, p := range req.GetPreferences() {
		if p.GetDeezerGenreId() <= 0 {
			return nil, status.Error(codes.InvalidArgument, "deezer_genre_id is required")
		}
		if p.GetWeight() < 1 || p.GetWeight() > 5 {
			return nil, status.Error(codes.InvalidArgument, "weight must be between 1 and 5")
		}
	}

	tx, queries, err := s.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	exists, err := queries.UserExists(ctx, req.GetUserId())
	if err != nil {
		return nil, status.Error(codes.Internal, "could not check user")
	}
	if !exists {
		return nil, status.Error(codes.NotFound, "user not found")
	}

	if err := queries.DeleteUserMusicPreferences(ctx, req.GetUserId()); err != nil {
		return nil, status.Error(codes.Internal, "could not save music preferences")
	}
	for _, p := range req.GetPreferences() {
		if _, err := queries.CreateUserMusicPreference(ctx, db.CreateUserMusicPreferenceParams{
			UserID: req.GetUserId(), DeezerGenreID: p.GetDeezerGenreId(), GenreName: p.GetGenreName(), Weight: int16(p.GetWeight()),
		}); err != nil {
			return nil, status.Error(codes.Internal, "could not save music preferences")
		}
	}
	if err := commitTx(ctx, tx, "could not save music preferences"); err != nil {
		return nil, err
	}

	prefs, err := db.New(s.pool).ListUserMusicPreferences(ctx, req.GetUserId())
	if err != nil {
		return nil, status.Error(codes.Internal, "could not load music preferences")
	}
	return &pb.SetMusicPreferencesResponse{Preferences: musicPreferencesDTO(prefs)}, nil
}

func (s *Service) GetFriends(ctx context.Context, req *pb.GetFriendsRequest) (*pb.GetFriendsResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	rows, err := db.New(s.pool).ListFriends(ctx, req.GetUserId())
	if err != nil {
		return nil, status.Error(codes.Internal, "could not load friends")
	}
	friends := make([]*pb.FriendDTO, len(rows))
	for i, r := range rows {
		friends[i] = &pb.FriendDTO{
			Id: r.ID, PublicId: publicIDText(r.PublicID), DisplayName: r.DisplayName,
			AvatarStorageKey: textOrEmpty(r.AvatarStorageKey), FriendsSinceUnix: r.FriendsSince.Time.Unix(),
		}
	}
	return &pb.GetFriendsResponse{Friends: friends}, nil
}

// SendFriendRequest : le blocage (dans les deux sens) est vérifié en amont par
// user#can_send_friend_request ; ici on vérifie qu'ils ne sont pas déjà amis,
// puis on laisse l'index unique partiel friend_requests_one_open_per_pair
// rejeter une demande croisée.
func (s *Service) SendFriendRequest(ctx context.Context, req *pb.SendFriendRequestRequest) (*pb.SendFriendRequestResponse, error) {
	if req.GetRequesterId() <= 0 || req.GetAddresseeId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "requester_id and addressee_id are required")
	}
	if req.GetRequesterId() == req.GetAddresseeId() {
		return nil, status.Error(codes.InvalidArgument, "cannot send a friend request to yourself")
	}
	queries := db.New(s.pool)

	// user#can_send_friend_request (`anyone but not blocked`) a déjà répondu,
	// dans les deux sens : un blocage dans un sens ou dans l'autre arrête la
	// demande. L'existence du destinataire est garantie par la résolution de
	// son UUID. Reste ce qui n'est pas une question de graphe : être déjà
	// amis, et une demande déjà en attente (l'index unique partiel de §7 la
	// refuse, translateFriendRequestError la rapporte).
	alreadyFriends, err := queries.AreFriends(ctx, db.AreFriendsParams{UserID: req.GetRequesterId(), OtherUserID: req.GetAddresseeId()})
	if err != nil {
		return nil, status.Error(codes.Internal, "could not check friendship")
	}
	if alreadyFriends {
		return nil, status.Error(codes.AlreadyExists, "already friends")
	}

	created, err := queries.CreateFriendRequest(ctx, db.CreateFriendRequestParams{
		RequesterID: req.GetRequesterId(), AddresseeID: req.GetAddresseeId(), Message: optionalText(req.GetMessage()),
	})
	if err != nil {
		return nil, translateFriendRequestError(err)
	}
	return &pb.SendFriendRequestResponse{
		Request: friendRequestDTO(created.ID, created.RequesterID, created.AddresseeID, string(created.Status), created.Message, created.CreatedAt),
	}, nil
}

func (s *Service) ListFriendRequests(ctx context.Context, req *pb.ListFriendRequestsRequest) (*pb.ListFriendRequestsResponse, error) {
	if req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id is required")
	}
	direction := req.GetDirection()
	if direction == "" {
		direction = "incoming"
	}

	queries := db.New(s.pool)
	var requests []*pb.FriendRequestDTO
	switch direction {
	case "incoming":
		rows, err := queries.ListIncomingFriendRequests(ctx, req.GetUserId())
		if err != nil {
			return nil, status.Error(codes.Internal, "could not list friend requests")
		}
		requests = make([]*pb.FriendRequestDTO, len(rows))
		for i, r := range rows {
			requests[i] = friendRequestDTO(r.ID, r.RequesterID, r.AddresseeID, string(r.Status), r.Message, r.CreatedAt)
			requests[i].OtherUser = userSummaryDTO(r.OtherPublicID, r.OtherDisplayName, r.OtherAvatarStorageKey)
		}
	case "outgoing":
		rows, err := queries.ListOutgoingFriendRequests(ctx, req.GetUserId())
		if err != nil {
			return nil, status.Error(codes.Internal, "could not list friend requests")
		}
		requests = make([]*pb.FriendRequestDTO, len(rows))
		for i, r := range rows {
			requests[i] = friendRequestDTO(r.ID, r.RequesterID, r.AddresseeID, string(r.Status), r.Message, r.CreatedAt)
			requests[i].OtherUser = userSummaryDTO(r.OtherPublicID, r.OtherDisplayName, r.OtherAvatarStorageKey)
		}
	default:
		return nil, status.Error(codes.InvalidArgument, "direction must be incoming or outgoing")
	}
	return &pb.ListFriendRequestsResponse{Requests: requests}, nil
}

// AcceptFriendRequest : les deux moitiés de la transaction décrite en tête de
// db/query/social.sql -- accepter la demande, puis créer la ligne
// friendships canonique -- dans la même transaction.
func (s *Service) AcceptFriendRequest(ctx context.Context, req *pb.AcceptFriendRequestRequest) (*pb.AcceptFriendRequestResponse, error) {
	if req.GetRequestId() <= 0 || req.GetAddresseeId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "request_id and addressee_id are required")
	}
	accepted, err := s.repo.AcceptFriendRequest(ctx, req.GetRequestId(), req.GetAddresseeId())
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, databaseError(err, "request not found, not yours, or already answered")
		}
		return nil, translateFriendRequestError(err)
	}

	friend, err := db.New(s.pool).GetFriend(ctx, db.GetFriendParams{ViewerID: accepted.AddresseeID, FriendID: accepted.RequesterID})
	if err != nil {
		return nil, status.Error(codes.Internal, "friendship created but could not reload it")
	}
	return &pb.AcceptFriendRequestResponse{Friend: &pb.FriendDTO{
		Id: friend.ID, PublicId: publicIDText(friend.PublicID), DisplayName: friend.DisplayName,
		AvatarStorageKey: textOrEmpty(friend.AvatarStorageKey), FriendsSinceUnix: friend.FriendsSince.Time.Unix(),
	}}, nil
}

func (s *Service) DeclineFriendRequest(ctx context.Context, req *pb.DeclineFriendRequestRequest) (*pb.DeclineFriendRequestResponse, error) {
	if req.GetRequestId() <= 0 || req.GetAddresseeId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "request_id and addressee_id are required")
	}
	_, err := db.New(s.pool).DeclineFriendRequest(ctx, db.DeclineFriendRequestParams{ID: req.GetRequestId(), AddresseeID: req.GetAddresseeId()})
	if err != nil {
		return nil, databaseError(err, "request not found, not yours, or already answered")
	}
	return &pb.DeclineFriendRequestResponse{}, nil
}

// BlockUser rompt d'abord toute amitié et annule toute demande en attente
// entre les deux comptes, avant de poser le blocage -- pour qu'un blocage ne
// laisse jamais une amitié ou une demande active derrière lui. L'insertion
// elle-même est idempotente : bloquer quelqu'un de déjà bloqué n'est pas une
// erreur.
func (s *Service) BlockUser(ctx context.Context, req *pb.BlockUserRequest) (*pb.BlockUserResponse, error) {
	if req.GetBlockerId() <= 0 || req.GetBlockedId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "blocker_id and blocked_id are required")
	}
	if req.GetBlockerId() == req.GetBlockedId() {
		return nil, status.Error(codes.InvalidArgument, "cannot block yourself")
	}

	// Bloquer est inconditionnel (docs/permissions.md §5) : il n'y a pas de
	// permission à vérifier, et l'existence du compte visé est garantie par la
	// résolution de son UUID. Tout le travail est dans la cascade, côté
	// repository -- amitié supprimée, demandes annulées, délégations révoquées
	// en base ET dans le graphe.
	if err := s.repo.Block(ctx, req.GetBlockerId(), req.GetBlockedId()); err != nil {
		return nil, status.Error(codes.Internal, "could not block user")
	}
	return &pb.BlockUserResponse{}, nil
}

func (s *Service) UnblockUser(ctx context.Context, req *pb.UnblockUserRequest) (*pb.UnblockUserResponse, error) {
	if req.GetBlockerId() <= 0 || req.GetBlockedId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "blocker_id and blocked_id are required")
	}
	if err := s.repo.Unblock(ctx, req.GetBlockerId(), req.GetBlockedId()); err != nil {
		return nil, status.Error(codes.Internal, "could not unblock user")
	}
	return &pb.UnblockUserResponse{}, nil
}

func (s *Service) ListBlockedUsers(ctx context.Context, req *pb.ListBlockedUsersRequest) (*pb.ListBlockedUsersResponse, error) {
	if req.GetBlockerId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "blocker_id is required")
	}
	rows, err := db.New(s.pool).ListBlockedUsers(ctx, req.GetBlockerId())
	if err != nil {
		return nil, status.Error(codes.Internal, "could not list blocked users")
	}
	blocked := make([]*pb.BlockedUserDTO, len(rows))
	for i, r := range rows {
		blocked[i] = &pb.BlockedUserDTO{
			Id: r.ID, PublicId: publicIDText(r.PublicID), DisplayName: r.DisplayName, BlockedAtUnix: r.BlockedAt.Time.Unix(),
		}
	}
	return &pb.ListBlockedUsersResponse{BlockedUsers: blocked}, nil
}

// Bornes de SearchUsers : une recherche sans limite renvoie searchDefaultLimit
// résultats, et jamais plus de searchMaxLimit. Pas de pagination : au-delà, on
// affine la recherche.
const (
	searchDefaultLimit = 20
	searchMaxLimit     = 50
)

// SearchUsers cherche des comptes par display_name, pour trouver quelqu'un à
// ajouter en ami. Une recherche vide ne renvoie personne (pas une erreur) :
// le champ de recherche de l'app est vide la plupart du temps. Le filtrage
// (soi-même, comptes inactifs, blocages dans les deux sens) est dans la
// requête SearchUsers, qui explique pourquoi.
func (s *Service) SearchUsers(ctx context.Context, req *pb.SearchUsersRequest) (*pb.SearchUsersResponse, error) {
	if req.GetViewerId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "viewer_id is required")
	}
	query := strings.TrimSpace(req.GetQuery())
	if query == "" {
		return &pb.SearchUsersResponse{}, nil
	}
	limit := req.GetLimit()
	switch {
	case limit <= 0:
		limit = searchDefaultLimit
	case limit > searchMaxLimit:
		limit = searchMaxLimit
	}
	rows, err := db.New(s.pool).SearchUsers(ctx, db.SearchUsersParams{
		ViewerID: req.GetViewerId(), Pattern: likePattern(query), MaxResults: limit,
	})
	if err != nil {
		return nil, status.Error(codes.Internal, "could not search users")
	}
	users := make([]*pb.UserSummaryDTO, len(rows))
	for i, r := range rows {
		users[i] = userSummaryDTO(r.PublicID, r.DisplayName, r.AvatarStorageKey)
	}
	return &pb.SearchUsersResponse{Users: users}, nil
}

// likeEscaper échappe les trois caractères spéciaux d'un motif LIKE, avec le
// caractère d'échappement que déclare la requête (ESCAPE '\').
var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// likePattern rend un texte saisi utilisable tel quel dans un ILIKE : "%"
// cherche un signe pourcent au lieu de tout renvoyer.
func likePattern(text string) string {
	return likeEscaper.Replace(text)
}

// Les valeurs de GetUserRelationshipResponse.status.
const (
	relationshipSelf            = "self"
	relationshipNone            = "none"
	relationshipFriends         = "friends"
	relationshipRequestSent     = "request_sent"
	relationshipRequestReceived = "request_received"
)

// GetUserRelationship dit où en est l'appelant avec un autre compte, pour
// qu'une page de profil choisisse ses boutons. Aucune permission n'est
// vérifiée en amont (comme BlockUser) : la réponse ne porte que sur les
// propres lignes de l'appelant, et elle doit répondre même quand un blocage
// existe -- GetUser est alors refusé, et c'est ici que la page apprend
// qu'elle peut proposer "Débloquer".
//
// Un blocage par l'AUTRE compte n'est jamais révélé : GetRelationship ne
// lit user_blocks que dans le sens appelant -> cible, et le blocage a déjà
// supprimé l'amitié et annulé les demandes, donc la réponse est "none".
func (s *Service) GetUserRelationship(ctx context.Context, req *pb.GetUserRelationshipRequest) (*pb.GetUserRelationshipResponse, error) {
	if req.GetViewerId() <= 0 || req.GetTargetId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "viewer_id and target_id are required")
	}
	if req.GetViewerId() == req.GetTargetId() {
		return &pb.GetUserRelationshipResponse{Status: relationshipSelf}, nil
	}
	queries := db.New(s.pool)

	row, err := queries.GetRelationship(ctx, db.GetRelationshipParams{
		ViewerID: req.GetViewerId(), TargetID: req.GetTargetId(),
	})
	if err != nil {
		return nil, status.Error(codes.Internal, "could not load relationship")
	}

	resp := &pb.GetUserRelationshipResponse{Status: relationshipNone, Blocked: row.BlockedByViewer}
	switch {
	case row.Friends:
		resp.Status = relationshipFriends
	case row.OutgoingRequestID != 0:
		resp.Status = relationshipRequestSent
	case row.IncomingRequestID != 0:
		resp.Status = relationshipRequestReceived
		resp.IncomingRequestId = row.IncomingRequestID
	}

	// GetUser refuse la carte de base dès qu'un blocage existe ; l'appelant a
	// besoin du nom pour savoir qui il débloque, et le voit déjà dans
	// ListBlockedUsers.
	if row.BlockedByViewer {
		target, err := queries.GetUserByID(ctx, req.GetTargetId())
		if err != nil {
			return nil, databaseError(err, "user not found")
		}
		resp.DisplayName = target.DisplayName
	}
	return resp, nil
}

// RemoveFriend rompt une amitié et retire toutes les délégations entre les
// deux comptes (voir Repository.Unfriend). Idempotent : retirer quelqu'un qui
// n'est pas un ami n'est pas une erreur, c'est l'état voulu.
func (s *Service) RemoveFriend(ctx context.Context, req *pb.RemoveFriendRequest) (*pb.RemoveFriendResponse, error) {
	if req.GetUserId() <= 0 || req.GetFriendId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "user_id and friend_id are required")
	}
	if req.GetUserId() == req.GetFriendId() {
		return nil, status.Error(codes.InvalidArgument, "cannot unfriend yourself")
	}
	if err := s.repo.Unfriend(ctx, req.GetUserId(), req.GetFriendId()); err != nil {
		return nil, status.Error(codes.Internal, "could not remove friend")
	}
	return &pb.RemoveFriendResponse{}, nil
}

func friendRequestDTO(id, requesterID, addresseeID int64, requestStatus string, message pgtype.Text, createdAt pgtype.Timestamptz) *pb.FriendRequestDTO {
	return &pb.FriendRequestDTO{
		Id: id, RequesterId: requesterID, AddresseeId: addresseeID, Status: requestStatus,
		Message: textOrEmpty(message), CreatedAt: createdAt.Time.Unix(),
	}
}

func userSummaryDTO(publicID pgtype.UUID, displayName string, avatarStorageKey pgtype.Text) *pb.UserSummaryDTO {
	return &pb.UserSummaryDTO{PublicId: publicIDText(publicID), DisplayName: displayName, AvatarStorageKey: textOrEmpty(avatarStorageKey)}
}

func musicPreferencesDTO(rows []db.ListUserMusicPreferencesRow) []*pb.MusicPreferenceDTO {
	dtos := make([]*pb.MusicPreferenceDTO, len(rows))
	for i, r := range rows {
		dtos[i] = &pb.MusicPreferenceDTO{DeezerGenreId: r.DeezerGenreID, GenreName: r.GenreName, Weight: int32(r.Weight)}
	}
	return dtos
}

// publicIDText rend l'UUID public sous sa forme canonique (avec tirets), la
// même que celle des tuples et celle que renvoie AuthService.
//
// C'était hex.EncodeToString, ce qui produisait le même UUID sans tirets : un
// client qui renvoyait l'id reçu ici ne parlait pas de la même chaîne que
// celui qui renvoyait l'id reçu de Login. L'intercepteur accepte les deux
// formes (authz.NormalizePublicID), mais l'API n'a plus de raison d'en émettre
// deux.
func publicIDText(id pgtype.UUID) string {
	return id.String()
}

func textOrEmpty(t pgtype.Text) string {
	if !t.Valid {
		return ""
	}
	return t.String
}

// optionalText : chaîne vide -> paramètre NULL : "effacé" pour un champ de
// profil envoyé vide (presentText), "aucun message" pour CreateFriendRequest.
func optionalText(s string) pgtype.Text {
	return pgtype.Text{String: s, Valid: s != ""}
}

func optionalDate(s string) (pgtype.Date, error) {
	if s == "" {
		return pgtype.Date{}, nil
	}
	t, err := time.Parse("2006-01-02", s)
	if err != nil {
		return pgtype.Date{}, status.Error(codes.InvalidArgument, "birth_date must be YYYY-MM-DD")
	}
	return pgtype.Date{Time: t, Valid: true}, nil
}

func formatDate(d pgtype.Date) string {
	if !d.Valid {
		return ""
	}
	return d.Time.Format("2006-01-02")
}

func optionalVisibility(value string) (db.NullVisibilityScope, error) {
	v, err := validVisibilityScope(value)
	if err != nil {
		return db.NullVisibilityScope{}, err
	}
	if v == "" {
		return db.NullVisibilityScope{}, nil
	}
	return db.NullVisibilityScope{VisibilityScope: db.VisibilityScope(v), Valid: true}, nil
}

func databaseError(err error, notFoundMsg string) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return status.Error(codes.NotFound, notFoundMsg)
	}
	return status.Error(codes.Internal, "user database operation failed")
}

// translateFriendRequestError : 23505 ne peut venir ici que de
// friend_requests_one_open_per_pair (demande croisée déjà pendante) ou,
// dans de rares courses, de la clé primaire de friendships.
func translateFriendRequestError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23505" {
		return status.Error(codes.AlreadyExists, "a pending friend request already exists between these users")
	}
	return status.Error(codes.Internal, "could not save friend request")
}

func translateProfileError(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && pgErr.Code == "23514" {
		return status.Error(codes.InvalidArgument, "country_code must be two uppercase letters (ISO 3166-1 alpha-2)")
	}
	return status.Error(codes.Internal, "could not save profile")
}
