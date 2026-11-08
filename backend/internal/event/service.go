// Package event implémente le service "Music Track Vote" : une playlist en
// direct où les membres suggèrent des morceaux et votent pour la suite de la
// file d'écoute (docs/data-model.md §10).
//
// Le package est découpé par responsabilité : service.go (plomberie commune),
// queue.go (file de vote), playback.go (radio station), dto.go (conversions
// et validations).
package event

import (
	"context"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/music_provider"
	"example.com/music-app/internal/realtime"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type Service struct {
	pb.UnimplementedEventServiceServer
	pool   *pgxpool.Pool
	repo   *Repository
	deezer *music_provider.DeezerClient
	sched  *scheduler
	authz  *authz.Client
	// hub réveille les WatchEvent ouverts : chaque écriture qui réussit
	// publie l'événement qu'elle a changé, après son commit.
	hub *realtime.Hub
	// presence : qui a la page ouverte (presence.go).
	presence *presence
}

// NewService : le pool pour les lectures et la lecture en cours, le repository
// pour les écritures qui doivent des tuples au graphe de permissions (voir
// repository.go). authz est un accès direct en lecture au client OpenFGA, à
// part du Repository (qui n'expose qu'Apply, l'écriture -- voir
// playlist.Repository pour le même raisonnement) : seule GetMusicEvents s'en
// sert, pour ListObjects.
func NewService(pool *pgxpool.Pool, repo *Repository, deezer *music_provider.DeezerClient, authzClient *authz.Client, hub *realtime.Hub) *Service {
	return &Service{pool: pool, repo: repo, deezer: deezer, sched: newScheduler(), authz: authzClient, hub: hub, presence: newPresence()}
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
