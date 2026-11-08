// Lifecycle: scheduled -> live -> ended, `ended` terminal. The host's first
// play (playNext, playback.go) makes an event live; EndEvent ends it from
// any state (docs/permissions.md §13). Pausing is the music's, not the
// event's: SetEventPlayback. event#can_change_status (host or admin) is
// already checked by the interceptor; each query in db/query/events.sql is
// its own compare-and-swap on the legal source state(s), so a rejected
// transition surfaces as FailedPrecondition -- the request was well-formed
// and allowed, the event just is not in a state where it makes sense.
package event

import (
	"context"
	"errors"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/realtime"
	"github.com/jackc/pgx/v5"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// EndEvent is legal from scheduled or live (db/query/events.sql):
// the app's End event also closes an event that never started.
func (s *Service) EndEvent(ctx context.Context, req *pb.EndEventRequest) (*pb.EndEventResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	updated, err := db.New(s.pool).EndEvent(ctx, req.GetEventId())
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, status.Error(codes.FailedPrecondition, "this event has already ended")
		}
		return nil, databaseError(err)
	}
	s.cancelAutoAdvance(req.GetEventId())
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.EndEventResponse{Event: eventDTO(updated)}, nil
}

// DeleteEvent marque l'événement supprimé (deleted_at). Host-only
// (event#can_delete, contrairement à can_change_status qui admet aussi
// admin) et légal depuis N'IMPORTE quel statut -- docs/permissions.md §13
// n'y met aucune restriction, contrairement aux quatre transitions
// ci-dessus.
//
// Pas de cascade : deleted_at IS NULL filtre déjà toute lecture et toute
// résolution d'id (GetEventIDByPublicID), donc l'événement devient
// inatteignable par toutes les autres RPC dès ce commit, tuples compris --
// même raisonnement que PlaylistService.DeletePlaylist. Le seul état qui ne
// passe PAS par une requête Postgres, le minuteur d'auto-advance en mémoire
// (scheduler.go), est annulé explicitement : sans ça, un événement supprimé
// en plein morceau laisserait un minuteur vivant échouer silencieusement
// plus tard contre une ligne qu'il ne peut plus lire.
func (s *Service) DeleteEvent(ctx context.Context, req *pb.DeleteEventRequest) (*pb.DeleteEventResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	deleted, err := db.New(s.pool).DeleteEvent(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	s.cancelAutoAdvance(req.GetEventId())
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.DeleteEventResponse{Event: eventDTO(deleted)}, nil
}
