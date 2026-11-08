package playlist

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"strconv"
	"strings"
	"time"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/media"
	"example.com/music-app/internal/music_provider"
	"example.com/music-app/internal/realtime"
	songservice "example.com/music-app/internal/songs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// coverSize : un seul thumbnail carré, même choix que l'avatar
// (internal/user/service.go) -- rien dans le sujet ne demande plusieurs tailles.
const coverSize = 512

// permissionChecker est la partie d'authz.Client dont ce service a besoin
// directement (pas via Repository, qui n'expose que Apply -- l'écriture, via
// l'outbox -- jamais une lecture) : Check répond à GetPlaylist's
// viewer_can_edit_songs, ListObjects énumère ce que ListPlaylists peut
// montrer (can_view). Une interface, pas le type concret, pour ne pas
// exiger OpenFGA dans les tests.
type permissionChecker interface {
	Check(ctx context.Context, req authz.CheckRequest) (bool, error)
	ListObjects(ctx context.Context, subject string, permission authz.Permission, objectType authz.ObjectType) ([]string, error)
}

type Service struct {
	pb.UnimplementedPlaylistServiceServer
	pool   *pgxpool.Pool
	repo   *Repository
	deezer *music_provider.DeezerClient
	images *media.Client
	covers *media.Store
	perms  permissionChecker
	// hub réveille les WatchPlaylist ouverts : chaque écriture qui réussit
	// publie la playlist qu'elle a changée, après son commit.
	hub *realtime.Hub
}

// NewService prend le pool ET un Repository : le pool pour les lectures et pour
// les écritures que le graphe de permissions ignore (ajout/retrait de morceaux),
// le repository pour celles qui doivent écrire des tuples. Voir repository.go
// pour la raison de ce partage plutôt qu'un déplacement complet.
func NewService(pool *pgxpool.Pool, repo *Repository, deezer *music_provider.DeezerClient, images *media.Client, covers *media.Store, perms permissionChecker, hub *realtime.Hub) *Service {
	return &Service{pool: pool, repo: repo, deezer: deezer, images: images, covers: covers, perms: perms, hub: hub}
}

// beginTx démarre une transaction et retourne un Queries qui y est lié.
// L'appelant doit faire `defer tx.Rollback(ctx)` puis appeler commitTx en cas de succès.
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

func (s *Service) CreatePlaylist(ctx context.Context, req *pb.CreatePlaylistRequest) (*pb.CreatePlaylistResponse, error) {
	if req.GetOwnerId() <= 0 || req.GetName() == "" {
		return nil, status.Error(codes.InvalidArgument, "owner_id and name are required")
	}
	visibility, err := validVisibility(req.GetVisibility())
	if err != nil {
		return nil, err
	}
	editLicense, err := validEditLicense(req.GetEditLicense())
	if err != nil {
		return nil, err
	}

	// Pas de contrôle d'existence du propriétaire : owner_id est rempli à
	// partir de la session, donc le compte existe et est actif -- c'est ce que
	// l'authentification vient de vérifier.
	queries := db.New(s.pool)
	created, err := s.repo.Create(ctx, CreateParams{
		OwnerID:     req.GetOwnerId(),
		Name:        req.GetName(),
		Visibility:  db.ResourceVisibility(visibility),
		EditLicense: db.EditLicense(editLicense),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	return &pb.CreatePlaylistResponse{Playlist: playlistDTO(ctx, queries, created)}, nil
}

func (s *Service) SetPlaylistVisibility(ctx context.Context, req *pb.SetPlaylistVisibilityRequest) (*pb.SetPlaylistVisibilityResponse, error) {
	if req.GetPlaylistId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	visibility, err := validVisibility(req.GetVisibility())
	if err != nil {
		return nil, err
	}
	updated, err := s.repo.SetVisibility(ctx, req.GetPlaylistId(), db.ResourceVisibility(visibility))
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.SetPlaylistVisibilityResponse{Playlist: playlistDTO(ctx, db.New(s.pool), updated)}, nil
}

// SetPlaylistEditLicense change edit_license -- miroir exact de
// SetPlaylistVisibility, sur l'autre wildcard indépendant (playlist#can_view
// et playlist#can_edit_songs restent découplés, voir authz/playlist.go).
// playlist#can_change_license est déjà vérifié par l'intercepteur
// (owner ou admin).
func (s *Service) SetPlaylistEditLicense(ctx context.Context, req *pb.SetPlaylistEditLicenseRequest) (*pb.SetPlaylistEditLicenseResponse, error) {
	if req.GetPlaylistId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	editLicense, err := validEditLicense(req.GetEditLicense())
	if err != nil {
		return nil, err
	}
	updated, err := s.repo.SetEditLicense(ctx, req.GetPlaylistId(), db.EditLicense(editLicense))
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.SetPlaylistEditLicenseResponse{Playlist: playlistDTO(ctx, db.New(s.pool), updated)}, nil
}

// RenamePlaylist change le nom. playlist#can_rename (owner ou admin) est
// déjà vérifié par l'intercepteur.
//
// Pas de Repository ici, contrairement à SetPlaylistVisibility/
// SetPlaylistEditLicense juste au-dessus : le nom n'entre dans aucune
// relation du modèle (authz/model.fga), donc rien à écrire dans le graphe --
// même raison que MoveSongInPlaylist pour utiliser une transaction brute
// (beginTx/commitTx) plutôt que outbox.InTx. Une transaction quand même,
// et pas juste RenamePlaylist seule : il faut que le bump de revision et
// l'AppendPlaylistOp (rename) commitent ensemble.
func (s *Service) RenamePlaylist(ctx context.Context, req *pb.RenamePlaylistRequest) (*pb.RenamePlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetName() == "" {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and name are required")
	}
	tx, queries, err := s.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	updated, err := queries.RenamePlaylist(ctx, db.RenamePlaylistParams{ID: req.GetPlaylistId(), Name: req.GetName()})
	if err != nil {
		return nil, databaseError(err)
	}
	// No actor: RenamePlaylist has no CallerPublicIDField either, same
	// reasoning as SetPlaylistVisibility/SetPlaylistEditLicense.
	if err := appendPlaylistOp(ctx, queries, req.GetPlaylistId(), updated.Revision, 0,
		db.PlaylistOpTypeRename, map[string]any{"name": updated.Name}); err != nil {
		return nil, err
	}
	if err := commitTx(ctx, tx, "could not rename playlist"); err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.RenamePlaylistResponse{Playlist: playlistDTO(ctx, db.New(s.pool), updated)}, nil
}

// ListPlaylistMembers liste les membres d'une playlist, propriétaire d'abord,
// pour sa page de réglages. playlist#can_view a déjà répondu : qui peut voir
// la playlist peut voir qui y participe.
func (s *Service) ListPlaylistMembers(ctx context.Context, req *pb.ListPlaylistMembersRequest) (*pb.ListPlaylistMembersResponse, error) {
	if req.GetPlaylistId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	rows, err := db.New(s.pool).ListPlaylistMembers(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	members := make([]*pb.PlaylistMemberDTO, len(rows))
	for i, row := range rows {
		members[i] = &pb.PlaylistMemberDTO{
			UserId: row.UserID, UserPublicId: row.PublicID.String(),
			DisplayName: row.DisplayName, AvatarStorageKey: row.AvatarStorageKey.String,
			Role: string(row.Role), JoinedAt: row.JoinedAt.Time.Unix(),
		}
	}
	return &pb.ListPlaylistMembersResponse{Members: members}, nil
}

// InviteToPlaylist ajoute invitee_user_id aux membres d'une playlist, pour
// qu'il puisse la trouver si elle est privée et l'éditer si sa licence est
// invited_only (V.2.3). Seul le propriétaire peut inviter ; pas de flux
// d'acceptation séparé, comme pour InviteToEvent.
func (s *Service) InviteToPlaylist(ctx context.Context, req *pb.InviteToPlaylistRequest) (*pb.InviteToPlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetInviterUserId() <= 0 || req.GetInviteeUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id, inviter_user_id and invitee_user_id are required")
	}
	// Deux contrôles ont déjà eu lieu, sur deux objets : playlist#can_invite
	// (le propriétaire, un admin OU un editor -- c'est voulu, §9.1) et
	// user#can_receive_invitation sur l'invité, qui est l'endroit où un blocage
	// entre les deux arrête l'invitation. L'existence de l'invité est garantie
	// par la résolution de son UUID.
	if err := s.repo.AddMember(ctx, req.GetPlaylistId(), req.GetInviteeUserId()); err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.InviteToPlaylistResponse{}, nil
}

// SetPlaylistCover stocke l'original envoyé, en dérive un thumbnail carré
// via image-service, et remplace la cover existante s'il y en avait une
// (fichiers ET lignes `images` de l'ancienne supprimés) -- même séquence que
// UserService.UploadAvatar (internal/user/service.go), à qui ce commentaire
// renvoie pour le détail du raisonnement (écriture avant commit, suppression
// des anciens fichiers seulement après).
func (s *Service) SetPlaylistCover(ctx context.Context, req *pb.SetPlaylistCoverRequest) (*pb.SetPlaylistCoverResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and user_id are required")
	}
	ext, err := validCoverUpload(req.GetContentType(), req.GetImageData())
	if err != nil {
		return nil, err
	}

	queries := db.New(s.pool)
	current, err := queries.GetPlaylistByID(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	// playlist#can_set_cover est déjà vérifié (propriétaire ou admin). La ligne
	// est relue ici pour la cover courante et pour le propriétaire, à qui
	// appartiennent les lignes `images` -- pas pour décider du droit.

	thumb, err := s.images.Resize(ctx, req.GetImageData(), coverSize, coverSize)
	if err != nil {
		if errors.Is(err, media.ErrInvalidImage) {
			return nil, status.Error(codes.InvalidArgument, "invalid image data")
		}
		return nil, status.Error(codes.Internal, "could not process image")
	}

	originalKey, err := media.NewObjectKey("playlists", ext)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not generate storage key")
	}
	thumbKey, err := media.NewObjectKey("playlists", "png")
	if err != nil {
		return nil, status.Error(codes.Internal, "could not generate storage key")
	}
	if err := s.covers.Save(originalKey, req.GetImageData()); err != nil {
		return nil, status.Error(codes.Internal, "could not save image")
	}
	if err := s.covers.Save(thumbKey, thumb); err != nil {
		return nil, status.Error(codes.Internal, "could not save image")
	}

	updated, staleFiles, err := s.repo.SetCover(ctx, CoverUpload{
		PlaylistID:           req.GetPlaylistId(),
		OwnerID:              current.OwnerID,
		ContentType:          req.GetContentType(),
		OriginalKey:          originalKey,
		OriginalSize:         len(req.GetImageData()),
		ThumbKey:             thumbKey,
		ThumbSize:            len(thumb),
		ThumbPixels:          coverSize,
		PreviousCoverImageID: current.CoverImageID,
	})
	if err != nil {
		return nil, databaseError(err)
	}
	// Après le commit seulement : un rollback ne doit pas laisser la playlist
	// pointer sur un fichier déjà supprimé.
	for _, key := range staleFiles {
		s.covers.Delete(key)
	}

	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.SetPlaylistCoverResponse{Playlist: playlistDTO(ctx, db.New(s.pool), updated)}, nil
}

// DeletePlaylistCover retire la cover courante, s'il y en a une -- pas
// d'erreur si la playlist n'en avait pas.
func (s *Service) DeletePlaylistCover(ctx context.Context, req *pb.DeletePlaylistCoverRequest) (*pb.DeletePlaylistCoverResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and user_id are required")
	}
	queries := db.New(s.pool)
	current, err := queries.GetPlaylistByID(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	staleFiles, err := s.repo.ClearCover(ctx, req.GetPlaylistId(), current.OwnerID, current.CoverImageID)
	if err != nil {
		return nil, databaseError(err)
	}
	for _, key := range staleFiles {
		s.covers.Delete(key)
	}

	updated, err := db.New(s.pool).GetPlaylistByID(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.DeletePlaylistCoverResponse{Playlist: playlistDTO(ctx, db.New(s.pool), updated)}, nil
}

func (s *Service) AddSongToPlaylist(ctx context.Context, req *pb.AddSongToPlaylistRequest) (*pb.AddSongToPlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetDeezerSongId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and deezer_song_id are required")
	}
	tx, queries, err := s.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// playlist#can_edit_songs est déjà vérifié par l'intercepteur, licence
	// d'édition comprise : `owner or admin or editor or (can_view and
	// open_edit)`. Ce qui reste ici est la transaction en trois temps
	// (BumpPlaylistRevision -> changement -> AppendPlaylistOp), qui n'est pas
	// une question de droits mais de revisions sans trou.

	// Vérifie si le song existe déjà dans la base de données. Si ce n'est pas le cas, on le récupère depuis Deezer et on l'ajoute à la base.
	songService := songservice.NewService(s.deezer, tx)
	storedSong, err := songService.GetSongByDeezerID(ctx, req.GetDeezerSongId())
	if err != nil {
		// Si le song n'existe pas, on le récupère depuis Deezer et on l'ajoute à la DB.
		storedSong, err = songService.AddSongFromDeezer(ctx, req.GetDeezerSongId())
		if err != nil {
			return nil, status.Errorf(codes.Internal, "could not add song from Deezer: %v", err)
		}
	}

	// Sérialise les éditeurs concurrents de cette playlist (prend le verrou de
	// ligne) avant d'appliquer le changement, pour que revision reste sans
	// trou et totalement ordonnée -- voir le commentaire en tête de
	// db/query/playlists.sql.
	revision, err := queries.BumpPlaylistRevision(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}

	// Doublon : le schéma l'autorise (un DJ set peut repasser un morceau),
	// donc on ne refuse que si le client ne l'a pas demandé -- l'app pose
	// alors la question "l'ajouter quand même ?" et renvoie allow_duplicate.
	//
	// APRÈS le verrou, pas avant : en READ COMMITTED chaque instruction lit un
	// nouvel instantané, donc celle-ci voit la ligne qu'un ajout concurrent du
	// même morceau vient de valider pendant qu'on attendait le verrou. Avant,
	// les deux ajouts passaient le contrôle et la playlist avait le doublon
	// sans que personne ne l'ait voulu.
	if !req.GetAllowDuplicate() {
		exists, err := queries.PlaylistSongExists(ctx, db.PlaylistSongExistsParams{
			PlaylistID: req.GetPlaylistId(), SongID: storedSong.ID,
		})
		if err != nil {
			return nil, databaseError(err)
		}
		if exists {
			return nil, status.Error(codes.AlreadyExists, "song already exists in the playlist")
		}
	}

	// Ajoute le song à la playlist.
	song, err := queries.AppendSongToPlaylist(ctx, db.AppendSongToPlaylistParams{
		PlaylistID: req.GetPlaylistId(), SongID: storedSong.ID, AddedByID: optionalInt8(req.GetUserId()),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	if err := queries.IncrementPlaylistStats(ctx, db.IncrementPlaylistStatsParams{
		ID: song.PlaylistID, ID_2: song.SongID,
	}); err != nil {
		return nil, databaseError(err)
	}
	if err := appendPlaylistOp(ctx, queries, req.GetPlaylistId(), revision, req.GetUserId(),
		db.PlaylistOpTypeAddSong, map[string]any{"playlist_song_id": song.ID, "song_id": storedSong.ID}); err != nil {
		return nil, err
	}
	if err := commitTx(ctx, tx, "could not save playlist song"); err != nil {
		return nil, err
	}

	// La liste entière, comme RemoveSongFromPlaylist : l'app remplace la
	// sienne par la réponse, et voit du même coup les ajouts des autres.
	playlistDto, songsDto, err := s.fetchPlaylistWithSongs(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.AddSongToPlaylistResponse{Playlist: playlistDto, Songs: songsDto}, nil
}

func (s *Service) RemoveSongFromPlaylist(ctx context.Context, req *pb.RemoveSongFromPlaylistRequest) (*pb.RemoveSongFromPlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetPlaylistSongId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and playlist_song_id are required")
	}
	tx, queries, err := s.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	duration, err := queries.GetPlaylistSongDuration(ctx, db.GetPlaylistSongDurationParams{
		ID: req.GetPlaylistSongId(), PlaylistID: req.GetPlaylistId(),
	})
	if err != nil {
		return nil, databaseError(err)
	}

	revision, err := queries.BumpPlaylistRevision(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	if err := queries.RemovePlaylistSong(ctx, db.RemovePlaylistSongParams{
		ID: req.GetPlaylistSongId(), PlaylistID: req.GetPlaylistId(),
	}); err != nil {
		return nil, databaseError(err)
	}
	if err := queries.DecrementPlaylistStats(ctx, db.DecrementPlaylistStatsParams{
		ID: req.GetPlaylistId(), TotalDurationSeconds: duration,
	}); err != nil {
		return nil, databaseError(err)
	}
	if err := appendPlaylistOp(ctx, queries, req.GetPlaylistId(), revision, req.GetUserId(),
		db.PlaylistOpTypeRemoveSong, map[string]any{"playlist_song_id": req.GetPlaylistSongId()}); err != nil {
		return nil, err
	}
	if err := commitTx(ctx, tx, "could not remove playlist song"); err != nil {
		return nil, err
	}

	playlistDto, songsDto, err := s.fetchPlaylistWithSongs(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.RemoveSongFromPlaylistResponse{
		Playlist: playlistDto,
		Songs:    songsDto,
	}, nil
}

// ListPlaylistOpsSince expose le journal playlist_ops pour qu'un client
// reconnecté rejoue les mutations manquées plutôt que de tout recharger --
// voir le commentaire en tête de db/query/playlists.sql. Même garde que
// GetPlaylist (playlist#can_view, déjà vérifié par l'intercepteur) : le
// journal n'est pas plus exposé que la playlist elle-même.
func (s *Service) ListPlaylistOpsSince(ctx context.Context, req *pb.ListPlaylistOpsSinceRequest) (*pb.ListPlaylistOpsSinceResponse, error) {
	if req.GetPlaylistId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	ops, err := db.New(s.pool).ListPlaylistOpsSince(ctx, db.ListPlaylistOpsSinceParams{
		PlaylistID:    req.GetPlaylistId(),
		SinceRevision: req.GetSinceRevision(),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	return &pb.ListPlaylistOpsSinceResponse{Ops: playlistOpsDTO(ops)}, nil
}

// MoveSongInPlaylist place playlist_song_id juste après
// after_playlist_song_id (0 = en tête), dans la transaction en trois temps.
//
// Le déplacement est relatif, sans base_revision (docs/todo.md §2 demandait
// de trancher) : "après Y" garde son sens quand d'autres ont modifié la liste
// ailleurs entre-temps, alors qu'un contrôle de revision refuserait tout
// déplacement fait pendant qu'un autre édite -- c'est-à-dire tout le temps,
// sur une playlist collaborative. Le seul cas refusé est celui où le morceau
// ou son ancre a été retiré : NotFound, et l'app recharge.
//
// Deux personnes qui déplacent le même morceau en même temps sont sérialisées
// par le verrou : le second déplacement l'emporte, sur la liste que le premier
// a laissée.
func (s *Service) MoveSongInPlaylist(ctx context.Context, req *pb.MoveSongInPlaylistRequest) (*pb.MoveSongInPlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetPlaylistSongId() <= 0 || req.GetAfterPlaylistSongId() < 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and playlist_song_id are required")
	}
	if req.GetAfterPlaylistSongId() == req.GetPlaylistSongId() {
		return nil, status.Error(codes.InvalidArgument, "a song cannot be moved after itself")
	}
	tx, queries, err := s.beginTx(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// Verrouille la ligne playlists (même verrou que toute autre mutation)
	// avant de lire quoi que ce soit d'autre.
	revision, err := queries.BumpPlaylistRevision(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	moved, err := queries.MovePlaylistSong(ctx, db.MovePlaylistSongParams{
		ID: req.GetPlaylistSongId(), AfterID: req.GetAfterPlaylistSongId(), PlaylistID: req.GetPlaylistId(),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	if moved == 0 {
		return nil, status.Error(codes.NotFound, "the song or the one it goes after is no longer in the playlist")
	}
	if err := appendPlaylistOp(ctx, queries, req.GetPlaylistId(), revision, req.GetUserId(),
		db.PlaylistOpTypeMoveSong, map[string]any{
			"playlist_song_id": req.GetPlaylistSongId(), "after_playlist_song_id": req.GetAfterPlaylistSongId(),
		}); err != nil {
		return nil, err
	}
	if err := commitTx(ctx, tx, "could not move playlist song"); err != nil {
		return nil, err
	}

	playlistDto, songsDto, err := s.fetchPlaylistWithSongs(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, err
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.MoveSongInPlaylistResponse{Playlist: playlistDto, Songs: songsDto}, nil
}

func (s *Service) GetPlaylist(ctx context.Context, req *pb.GetPlaylistRequest) (*pb.GetPlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	// playlist#can_view a déjà répondu (publique, ou propriétaire/admin/editor/
	// viewer), et une playlist supprimée n'a pas passé la résolution de son
	// UUID -- deleted_at n'est pas un tuple et ne le sera pas.
	queries := db.New(s.pool)
	found, err := queries.GetPlaylistByID(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	songs, err := queries.GetPlaylistSongsByPlaylistID(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	return &pb.GetPlaylistResponse{
		Playlist: playlistDTO(ctx, queries, found), Songs: playlistSongsDTO(songs),
		ViewerCanEditSongs: s.canEditSongs(ctx, req.GetViewerPublicId(), req.GetPlaylistPublicId()),
	}, nil
}

// WatchPlaylist envoie la playlist tout de suite, puis à nouveau après chaque
// changement publié sur le hub.
//
// Chaque envoi relit tout avec GetPlaylist : un état complet et enregistré,
// avec le viewer_can_edit_songs de CE viewer. playlist#can_view est vérifié à
// nouveau avant chaque envoi, l'intercepteur ne l'ayant vérifié qu'à
// l'ouverture : une playlist passée en privée, ou supprimée, ferme le flux
// des viewers qui n'y ont plus droit, avec le même NotFound que GetPlaylist.
func (s *Service) WatchPlaylist(req *pb.WatchPlaylistRequest, stream pb.PlaylistService_WatchPlaylistServer) error {
	if req.GetPlaylistId() <= 0 {
		return status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	ctx := stream.Context()
	// Avant la première lecture : un changement commité entre les deux
	// réveillera quand même la boucle.
	changed, stop := s.hub.Subscribe(realtime.Playlist(req.GetPlaylistId()))
	defer stop()

	read := &pb.GetPlaylistRequest{
		PlaylistId: req.GetPlaylistId(), ViewerId: req.GetViewerId(),
		PlaylistPublicId: req.GetPlaylistPublicId(), ViewerPublicId: req.GetViewerPublicId(),
	}
	// Toutes les accessRecheck aussi, sans changement publié : juste après un
	// passage en privé, le Check peut encore répondre "oui" depuis le cache
	// d'OpenFGA, et rien d'autre ne le reposerait.
	recheck := time.NewTicker(accessRecheck)
	defer recheck.Stop()

	for first := true; ; first = false {
		// À l'ouverture, l'intercepteur vient de répondre.
		if !first {
			if err := s.requireView(ctx, req); err != nil {
				return err
			}
		}
		state, err := s.GetPlaylist(ctx, read)
		if err != nil {
			return err
		}
		if err := stream.Send(&pb.WatchPlaylistResponse{
			Playlist: state.GetPlaylist(), Songs: state.GetSongs(), ViewerCanEditSongs: state.GetViewerCanEditSongs(),
		}); err != nil {
			return err
		}
	wait:
		for {
			select {
			case <-changed:
				break wait
			case <-recheck.C:
				if err := s.requireView(ctx, req); err != nil {
					return err
				}
			case <-ctx.Done():
				return nil
			}
		}
	}
}

// accessRecheck : tous les combien un flux ouvert revérifie playlist#can_view
// sans qu'aucun changement n'ait été publié (même valeur que WatchEvent).
const accessRecheck = 5 * time.Second

// requireView ferme le flux de qui ne peut plus voir la playlist (passée en
// privé, supprimée) avec le NotFound de GetPlaylist. Une erreur d'OpenFGA
// n'est pas un refus : Unavailable, et l'app se reconnecte simplement.
func (s *Service) requireView(ctx context.Context, req *pb.WatchPlaylistRequest) error {
	allowed, err := s.canView(ctx, req.GetViewerPublicId(), req.GetPlaylistPublicId())
	if err != nil {
		return status.Error(codes.Unavailable, "could not check access, retry")
	}
	if !allowed {
		return status.Error(codes.NotFound, "playlist not found")
	}
	return nil
}

// canView pose la question de l'intercepteur (playlist#can_view) pour un flux
// déjà ouvert. Une erreur d'OpenFGA remonte (requireView).
func (s *Service) canView(ctx context.Context, viewerPublicID, playlistPublicID string) (bool, error) {
	publicID, err := authz.NormalizePublicID(playlistPublicID)
	if err != nil || s.perms == nil {
		return false, nil
	}
	allowed, err := s.perms.Check(ctx, authz.CheckRequest{
		Subject:    authz.UserRef(viewerPublicID),
		Permission: authz.PermPlaylistView,
		Object:     authz.Object(authz.TypePlaylist, publicID),
	})
	if err != nil {
		log.Printf("playlist: watch can_view: %v", err)
		return false, err
	}
	return allowed, nil
}

// canEditSongs répond à viewer_can_edit_songs avec la même question que
// l'intercepteur pose avant AddSongToPlaylist / Move / Remove
// (playlist#can_edit_songs), pour que l'app n'affiche pas des boutons qui
// seraient refusés. Une erreur d'OpenFGA répond "non" sans faire échouer la
// lecture : ce n'est qu'un affichage, et l'intercepteur garde les écritures.
func (s *Service) canEditSongs(ctx context.Context, viewerPublicID, playlistPublicID string) bool {
	if s.perms == nil || viewerPublicID == "" {
		return false
	}
	// L'intercepteur a validé playlist_public_id mais ne le réécrit pas sous
	// sa forme canonique (le viewer, lui, l'est) : même normalisation que la
	// sienne, sinon l'objet demandé ne correspondrait à aucun tuple.
	publicID, err := authz.NormalizePublicID(playlistPublicID)
	if err != nil {
		return false
	}
	allowed, err := s.perms.Check(ctx, authz.CheckRequest{
		Subject:    authz.UserRef(viewerPublicID),
		Permission: authz.PermPlaylistEditSongs,
		Object:     authz.Object(authz.TypePlaylist, publicID),
		// No context: no condition is reachable from can_edit_songs, and a
		// timestamp would only defeat OpenFGA's check cache (authz.NeedsRequestTime).
	})
	if err != nil {
		log.Printf("playlist: viewer_can_edit_songs: %v", err)
		return false
	}
	return allowed
}

// ListPlaylists renvoie toute playlist que l'appelant peut voir : les siennes
// (propriétaire, admin, éditeur ou simple viewer -- n'importe quel rôle) plus
// toutes les playlists publiques, tous propriétaires confondus.
//
// L'intercepteur n'a rien vérifié ici -- il n'y a pas d'objet unique à
// checker avant de lancer le handler (policy.go). C'est ListObjects,
// juste en dessous, qui EST l'autorisation : il rend exactement les
// playlist_id sur lesquels playlist#can_view répond oui pour cet
// utilisateur, ni plus ni moins. Un utilisateur sans aucune playlist
// visible (aucune playlist publique n'existe encore, aucune appartenance)
// reçoit une liste vide, pas une erreur.
func (s *Service) ListPlaylists(ctx context.Context, req *pb.ListPlaylistsRequest) (*pb.ListPlaylistsResponse, error) {
	if req.GetViewerId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "viewer_public_id is required")
	}
	publicIDs, err := s.perms.ListObjects(ctx, authz.UserRef(req.GetViewerPublicId()), authz.PermPlaylistView, authz.TypePlaylist)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not list visible playlists")
	}
	if len(publicIDs) == 0 {
		return &pb.ListPlaylistsResponse{Playlists: []*pb.PlaylistDTO{}}, nil
	}

	ids := make([]pgtype.UUID, 0, len(publicIDs))
	for _, id := range publicIDs {
		var parsed pgtype.UUID
		if err := parsed.Scan(id); err != nil {
			// Un id que ListObjects a rendu mais que Postgres ne reconnaît pas
			// comme un UUID ne peut venir que d'une tuple écrite à la main
			// (fixture de test, `fga tuple write` manuel) -- l'ignorer plutôt
			// que de faire échouer toute la liste pour les autres.
			continue
		}
		ids = append(ids, parsed)
	}

	queries := db.New(s.pool)
	found, err := queries.GetPlaylistsByPublicIDs(ctx, ids)
	if err != nil {
		return nil, databaseError(err)
	}
	playlists := make([]*pb.PlaylistDTO, len(found))
	for i, p := range found {
		playlists[i] = playlistDTO(ctx, queries, p)
	}
	return &pb.ListPlaylistsResponse{Playlists: playlists}, nil
}

// ListLibraryPlaylists renvoie la bibliothèque de l'appelant (onglet
// Playlists de l'app) : ses playlists, celles dont il est membre, et les
// playlists publiques de ses amis. Même autorisation que ListPlaylists --
// ListObjects(can_view) -- puis réduite à la bibliothèque : la requête SQL
// ne peut donc jamais lister une playlist que l'appelant ne peut pas voir.
// Les propriétaires bloqués (dans un sens ou l'autre) sont écartés par la
// requête.
func (s *Service) ListLibraryPlaylists(ctx context.Context, req *pb.ListLibraryPlaylistsRequest) (*pb.ListLibraryPlaylistsResponse, error) {
	if req.GetViewerId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "viewer_public_id is required")
	}
	publicIDs, err := s.perms.ListObjects(ctx, authz.UserRef(req.GetViewerPublicId()), authz.PermPlaylistView, authz.TypePlaylist)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not list visible playlists")
	}
	ids := make([]pgtype.UUID, 0, len(publicIDs))
	for _, id := range publicIDs {
		var parsed pgtype.UUID
		if err := parsed.Scan(id); err != nil {
			continue // même tolérance que ListPlaylists
		}
		ids = append(ids, parsed)
	}
	if len(ids) == 0 {
		return &pb.ListLibraryPlaylistsResponse{Playlists: []*pb.PlaylistListItemDTO{}}, nil
	}

	rows, err := db.New(s.pool).ListLibraryPlaylists(ctx, db.ListLibraryPlaylistsParams{
		ViewerID: req.GetViewerId(), PublicIds: ids,
	})
	if err != nil {
		return nil, databaseError(err)
	}
	playlists := make([]*pb.PlaylistListItemDTO, 0, len(rows))
	for _, row := range rows {
		relation := libraryRelation(row)
		if relation == "" {
			continue // visible (publique), mais hors de la bibliothèque
		}
		playlists = append(playlists, &pb.PlaylistListItemDTO{
			PublicId: row.PublicID.String(), Name: row.Name, SongCount: row.SongCount,
			EditorCount: row.EditorCount, OwnerPublicId: row.OwnerPublicID.String(),
			OwnerDisplayName: row.OwnerDisplayName, FirstSongCoverUrl: row.FirstSongCoverUrl,
			Relation: relation, OwnerIsFriend: row.OwnerIsFriend, Visibility: string(row.Visibility),
		})
	}
	return &pb.ListLibraryPlaylistsResponse{Playlists: playlists}, nil
}

// libraryRelation : mine / shared / friend, premier qui s'applique, ou ""
// pour une playlist qui n'est pas dans la bibliothèque (publique, d'un
// inconnu). Une playlist d'ami n'y entre que publique : une privée dont
// l'appelant n'est pas membre, il ne peut de toute façon pas la voir.
func libraryRelation(row db.ListLibraryPlaylistsRow) string {
	return relation(row.IsOwner, row.IsMember, row.OwnerIsFriend && row.Visibility == db.ResourceVisibilityPublic)
}

// relation : mine / shared / friend, premier qui s'applique, "" sinon.
// friendsPublic : un ami en est propriétaire et elle est publique.
func relation(isOwner, isMember, friendsPublic bool) string {
	switch {
	case isOwner:
		return "mine"
	case isMember:
		return "shared"
	case friendsPublic:
		return "friend"
	default:
		return ""
	}
}

const (
	defaultSearchPageSize = 30
	maxSearchPageSize     = 100
)

// SearchPublicPlaylists cherche parmi toutes les playlists publiques (filtre
// Public de l'app), par nom, les plus récentes d'abord, page par page. Pas de
// ListObjects ici : une playlist publique est visible de tous par définition,
// et la tuple wildcard OpenFGA est écrite depuis playlists.visibility -- le
// WHERE visibility = 'public' EST l'autorisation. relation dit tout de même
// ce que la playlist est pour l'appelant (la sienne, partagée, d'un ami), sinon
// "public".
//
// page_token est l'offset de la page suivante, en décimal : la pagination par
// offset peut sauter ou répéter une playlist créée entre deux pages, ce qui
// est sans conséquence pour une liste qu'on fait défiler.
func (s *Service) SearchPublicPlaylists(ctx context.Context, req *pb.SearchPublicPlaylistsRequest) (*pb.SearchPublicPlaylistsResponse, error) {
	if req.GetViewerId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "viewer_public_id is required")
	}
	size := req.GetPageSize()
	if size <= 0 {
		size = defaultSearchPageSize
	}
	if size > maxSearchPageSize {
		size = maxSearchPageSize
	}
	offset := 0
	if token := req.GetPageToken(); token != "" {
		parsed, err := strconv.Atoi(token)
		if err != nil || parsed < 0 {
			return nil, status.Error(codes.InvalidArgument, "invalid page_token")
		}
		offset = parsed
	}

	// Une ligne de plus que la page : sa présence dit qu'il y a une suite.
	rows, err := db.New(s.pool).SearchPublicPlaylists(ctx, db.SearchPublicPlaylistsParams{
		ViewerID: req.GetViewerId(), Query: strings.TrimSpace(req.GetQuery()),
		MyTaste:  req.GetMyTaste(),
		RowLimit: size + 1, RowOffset: int32(offset),
	})
	if err != nil {
		return nil, databaseError(err)
	}
	next := ""
	if len(rows) > int(size) {
		rows = rows[:size]
		next = strconv.Itoa(offset + int(size))
	}
	playlists := make([]*pb.PlaylistListItemDTO, len(rows))
	for i, row := range rows {
		rel := relation(row.IsOwner, row.IsMember, row.OwnerIsFriend)
		if rel == "" {
			rel = "public"
		}
		playlists[i] = &pb.PlaylistListItemDTO{
			PublicId: row.PublicID.String(), Name: row.Name, SongCount: row.SongCount,
			EditorCount: row.EditorCount, OwnerPublicId: row.OwnerPublicID.String(),
			OwnerDisplayName: row.OwnerDisplayName, FirstSongCoverUrl: row.FirstSongCoverUrl,
			// The search lists public playlists only.
			Relation: rel, OwnerIsFriend: row.OwnerIsFriend, Visibility: "public",
		}
	}
	return &pb.SearchPublicPlaylistsResponse{Playlists: playlists, NextPageToken: next}, nil
}

// DeletePlaylist marque la playlist supprimée (deleted_at). playlist#can_delete
// (propriétaire seulement -- n'inclut pas admin, contrairement à la plupart
// des autres permissions de ce service) est déjà vérifié par l'intercepteur.
//
// Pas de transaction BumpPlaylistRevision -> AppendPlaylistOp ici : c'est une
// opération terminale, pas une mutation à rejouer, et personne ne pourrait
// de toute façon lire ce journal après coup -- ListPlaylistOpsSince résout
// playlist_public_id via le même filtre deleted_at IS NULL, donc il devient
// lui aussi inatteignable dès ce commit. Pas de nettoyage de tuples non plus
// pour la même raison : voir le commentaire de la requête DeletePlaylist
// (db/query/playlists.sql).
func (s *Service) DeletePlaylist(ctx context.Context, req *pb.DeletePlaylistRequest) (*pb.DeletePlaylistResponse, error) {
	if req.GetPlaylistId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id is required")
	}
	deleted, err := db.New(s.pool).DeletePlaylist(ctx, req.GetPlaylistId())
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.DeletePlaylistResponse{Playlist: playlistDTO(ctx, db.New(s.pool), deleted)}, nil
}

// TransferPlaylistOwnership passe la propriété à un membre existant.
// playlist#can_transfer_ownership (propriétaire seulement) est déjà vérifié
// par l'intercepteur. L'ancien propriétaire devient admin -- pas retiré de
// la playlist, pas sans rôle : il garde la gestion au quotidien, seulement
// plus can_delete/can_transfer_ownership.
func (s *Service) TransferPlaylistOwnership(ctx context.Context, req *pb.TransferPlaylistOwnershipRequest) (*pb.TransferPlaylistOwnershipResponse, error) {
	if req.GetPlaylistId() <= 0 || req.GetNewOwnerUserId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "playlist_id and new_owner_user_id are required")
	}
	if req.GetNewOwnerUserId() == req.GetCurrentOwnerUserId() {
		return nil, status.Error(codes.InvalidArgument, "cannot transfer ownership to yourself")
	}
	updated, err := s.repo.TransferOwnership(ctx, req.GetPlaylistId(), req.GetCurrentOwnerUserId(), req.GetNewOwnerUserId())
	if err != nil {
		return nil, databaseError(err)
	}
	s.hub.Publish(realtime.Playlist(req.GetPlaylistId()))
	return &pb.TransferPlaylistOwnershipResponse{Playlist: playlistDTO(ctx, db.New(s.pool), updated)}, nil
}

// appendPlaylistOp journalise une mutation dans playlist_ops, à la revision
// que BumpPlaylistRevision vient de retourner (étape 3 du schéma décrit en
// tête de db/query/playlists.sql).
func appendPlaylistOp(ctx context.Context, queries *db.Queries, playlistID, revision, actorID int64, opType db.PlaylistOpType, payload map[string]any) error {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return status.Error(codes.Internal, "could not encode playlist op payload")
	}
	if _, err := queries.AppendPlaylistOp(ctx, db.AppendPlaylistOpParams{
		PlaylistID: playlistID, Revision: revision, ActorID: optionalInt8(actorID),
		OpType: opType, Payload: encoded,
	}); err != nil {
		return databaseError(err)
	}
	return nil
}

// fetchPlaylistWithSongs charge une playlist et ses chansons, déjà converties en DTO.
func (s *Service) fetchPlaylistWithSongs(ctx context.Context, playlistID int64) (*pb.PlaylistDTO, []*pb.PlaylistSongDTO, error) {
	queries := db.New(s.pool)
	playlist, err := queries.GetPlaylistByID(ctx, playlistID)
	if err != nil {
		return nil, nil, databaseError(err)
	}
	songs, err := queries.GetPlaylistSongsByPlaylistID(ctx, playlistID)
	if err != nil {
		return nil, nil, databaseError(err)
	}
	return playlistDTO(ctx, queries, playlist), playlistSongsDTO(songs), nil
}

func playlistSongsDTO(songs []db.GetPlaylistSongsByPlaylistIDRow) []*pb.PlaylistSongDTO {
	dtos := make([]*pb.PlaylistSongDTO, len(songs))
	for i, song := range songs {
		dtos[i] = &pb.PlaylistSongDTO{
			Id: song.ID, PlaylistId: song.PlaylistID, AddedById: song.AddedByID.Int64,
			SongId: song.SongID, Position: int32(song.Position), CreatedAt: song.CreatedAt.Time.Unix(),
			Song: songDTO(song.Song),
		}
	}
	return dtos
}

func playlistOpsDTO(ops []db.PlaylistOp) []*pb.PlaylistOpDTO {
	dtos := make([]*pb.PlaylistOpDTO, len(ops))
	for i, op := range ops {
		dtos[i] = &pb.PlaylistOpDTO{
			Id: op.ID, PlaylistId: op.PlaylistID, Revision: op.Revision,
			ActorId: op.ActorID.Int64, OpType: string(op.OpType),
			Payload: string(op.Payload), CreatedAt: op.CreatedAt.Time.Unix(),
		}
	}
	return dtos
}

func songDTO(song db.Song) *pb.SongDTO {
	return &pb.SongDTO{
		Id: song.ID, DeezerSongId: song.DeezerSongID, Title: song.Title,
		DurationSeconds: int64(song.DurationSeconds), ArtistName: song.ArtistName,
		DeezerArtistId: song.DeezerArtistID.Int64, AlbumTitle: song.AlbumTitle,
		DeezerAlbumId: song.DeezerAlbumID.Int64, CoverUrl: song.CoverUrl.String,
		PreviewUrl: song.PreviewUrl.String,
	}
}

// playlistDTO résout la clé de stockage de la cover (si `p` en a une) avant
// de construire le DTO -- même geste que buildUserDTO pour l'avatar
// (internal/user/service.go) : un échec de cette lecture annexe ne doit pas
// faire échouer la réponse entière.
func playlistDTO(ctx context.Context, queries *db.Queries, p db.Playlist) *pb.PlaylistDTO {
	coverKey := ""
	if p.CoverImageID.Valid {
		if img, err := queries.GetImageByID(ctx, p.CoverImageID.Int64); err == nil {
			coverKey = img.StorageKey
		}
	}
	return &pb.PlaylistDTO{
		Id: p.ID, PublicId: p.PublicID.String(), OwnerId: p.OwnerID,
		Name: p.Name, Visibility: string(p.Visibility), EditLicense: string(p.EditLicense),
		SongCount: p.SongCount, TotalDurationSeconds: p.TotalDurationSeconds, Revision: p.Revision,
		CoverStorageKey: coverKey,
		// DeletedAt/CreatedAt/UpdatedAt manquaient ici avant DeletePlaylist --
		// invisible tant que rien ne posait jamais deleted_at, mais
		// CreatedAt/UpdatedAt étaient tout autant absents pour toute autre
		// RPC malgré le .proto qui les documente comme de vrais champs. Corrigé au passage plutôt que de laisser
		// DeletePlaylist être la seule RPC à s'en soucier.
		DeletedAt: unixOrZero(p.DeletedAt), CreatedAt: unixOrZero(p.CreatedAt), UpdatedAt: unixOrZero(p.UpdatedAt),
	}
}

// unixOrZero convertit un timestamp nullable en secondes Unix, 0 si absent
// -- même geste que son homonyme non exporté dans internal/event/playback.go.
func unixOrZero(t pgtype.Timestamptz) int64 {
	if !t.Valid {
		return 0
	}
	return t.Time.Unix()
}

func validVisibility(value string) (string, error) {
	if value == "" {
		return "public", nil
	}
	if value != "public" && value != "private" {
		return "", status.Error(codes.InvalidArgument, "visibility must be public or private")
	}
	return value, nil
}

// optionalInt8 convertit un id facultatif en pgtype.Int8. 0 est traité comme
// "non fourni", par cohérence avec le reste du code (added_by_id, actor_id...).
func optionalInt8(id int64) pgtype.Int8 {
	return pgtype.Int8{Int64: id, Valid: id > 0}
}

func databaseError(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return status.Error(codes.NotFound, "playlist or playlist song not found")
	}
	return status.Error(codes.Internal, "playlist database operation failed")
}
