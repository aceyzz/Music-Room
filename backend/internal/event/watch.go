package event

import (
	"context"
	"log"
	"time"

	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/authz"
	"example.com/music-app/internal/realtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// WatchEvent envoie l'événement en direct tout de suite, puis à nouveau après
// chaque changement publié sur le hub (vote, suggestion, lecture, statut).
//
// Chaque envoi relit tout avec les lectures unaires : un état complet et
// enregistré, avec le viewer_has_voted et le viewer_can_control de CE viewer.
// event#can_view est vérifié à nouveau avant chaque envoi, l'intercepteur ne
// l'ayant vérifié qu'à l'ouverture : un événement supprimé ferme le flux avec
// le même NotFound que GetMusicEvent.
func (s *Service) WatchEvent(req *pb.WatchEventRequest, stream pb.EventService_WatchEventServer) error {
	if req.GetEventId() <= 0 {
		return status.Error(codes.InvalidArgument, "event_id is required")
	}
	ctx := stream.Context()
	// Avant la première lecture : un changement commité entre les deux
	// réveillera quand même la boucle.
	changed, stop := s.hub.Subscribe(realtime.Event(req.GetEventId()))
	defer stop()
	// L'hôte qui a la page ouverte est celui dont le téléphone joue (presence.go).
	defer s.presence.watch(req.GetEventId(), req.GetViewerId())()

	// Toutes les accessRecheck aussi, sans changement publié : juste après un
	// passage en privé, le Check peut encore répondre "oui" depuis le cache
	// d'OpenFGA (jusqu'à son TTL), et rien d'autre ne le reposerait.
	recheck := time.NewTicker(accessRecheck)
	defer recheck.Stop()
	// What was last sent: the recheck sends again when it changes (a vote
	// window opening or closing, with nothing published).
	var sentCanVote bool

	for first := true; ; first = false {
		// À l'ouverture, l'intercepteur vient de répondre.
		if !first {
			if err := s.requireView(ctx, req); err != nil {
				return err
			}
		}
		state, err := s.readLiveEvent(ctx, req)
		if err != nil {
			return err
		}
		if err := stream.Send(state); err != nil {
			return err
		}
		sentCanVote = state.GetViewerCanVote()
	wait:
		for {
			select {
			case <-changed:
				break wait
			case <-recheck.C:
				if err := s.requireView(ctx, req); err != nil {
					return err
				}
				if s.canVote(ctx, req) != sentCanVote {
					break wait
				}
			case <-ctx.Done():
				return nil
			}
		}
	}
}

// accessRecheck : tous les combien un flux ouvert revérifie event#can_view
// sans qu'aucun changement n'ait été publié. Avec le cache d'OpenFGA
// (10 s de TTL, docker-compose.yaml), quelqu'un qui perd l'accès est coupé en
// 5 à 15 s.
const accessRecheck = 5 * time.Second

// requireView ferme le flux de qui ne peut plus voir l'événement (passé en
// privé, supprimé) avec le NotFound de GetMusicEvent : l'app quitte la page.
// Une erreur d'OpenFGA n'est pas un refus : Unavailable, et l'app se
// reconnecte simplement.
func (s *Service) requireView(ctx context.Context, req *pb.WatchEventRequest) error {
	allowed, err := s.canView(ctx, req.GetViewerPublicId(), req.GetEventPublicId())
	if err != nil {
		return status.Error(codes.Unavailable, "could not check access, retry")
	}
	if !allowed {
		return status.Error(codes.NotFound, "event not found")
	}
	return nil
}

// readLiveEvent est GetMusicEvent + GetEventPlayback + ListEventQueue en une
// réponse : les mêmes lectures, donc les mêmes règles.
func (s *Service) readLiveEvent(ctx context.Context, req *pb.WatchEventRequest) (*pb.WatchEventResponse, error) {
	event, err := s.GetMusicEvent(ctx, &pb.GetMusicEventRequest{
		Id: req.GetEventId(), ViewerId: req.GetViewerId(),
		PublicId: req.GetEventPublicId(), ViewerPublicId: req.GetViewerPublicId(),
	})
	if err != nil {
		return nil, err
	}
	playback, err := s.GetEventPlayback(ctx, &pb.GetEventPlaybackRequest{
		EventId: req.GetEventId(), ViewerId: req.GetViewerId(),
		EventPublicId: req.GetEventPublicId(), ViewerPublicId: req.GetViewerPublicId(),
	})
	if err != nil {
		return nil, err
	}
	queue, err := s.listQueue(ctx, req.GetEventId(), req.GetViewerId())
	if err != nil {
		return nil, err
	}
	return &pb.WatchEventResponse{
		Event: event.GetEvent(), Playback: playback.GetPlayback(),
		ViewerCanControl: playback.GetViewerCanControl(), Queue: queue,
		ViewerCanVote: event.GetEvent().GetStatus() != "ended" && s.canVote(ctx, req),
	}, nil
}

// canVote pose la question de l'intercepteur avant CastVote et SuggestSong
// (event#can_vote, avec l'heure pour la fenêtre de vote d'une licence
// location_time), pour que l'app n'affiche pas des boutons qui seraient
// refusés. Le rayon autour du lieu, lui, ne se vérifie qu'au vote, avec la
// position. Une erreur d'OpenFGA répond "non" : ce n'est qu'un affichage, et
// l'intercepteur garde les écritures.
func (s *Service) canVote(ctx context.Context, req *pb.WatchEventRequest) bool {
	publicID, err := authz.NormalizePublicID(req.GetEventPublicId())
	if err != nil || s.authz == nil {
		return false
	}
	check := authz.CheckRequest{
		Subject:    authz.UserRef(req.GetViewerPublicId()),
		Permission: authz.PermEventVote,
		Object:     authz.Object(authz.TypeEvent, publicID),
	}
	if authz.NeedsRequestTime(authz.TypeEvent, authz.PermEventVote) {
		check.Context = map[string]any{"current_time": authz.RequestTime(time.Now())}
	}
	allowed, err := s.authz.Check(ctx, check)
	if err != nil {
		log.Printf("event: watch can_vote: %v", err)
		return false
	}
	return allowed
}

// canView pose la question de l'intercepteur (event#can_view) pour un flux
// déjà ouvert. Une erreur d'OpenFGA remonte : le flux se ferme quand même,
// plutôt que de continuer à envoyer sans vérification, mais l'app se
// reconnecte au lieu de quitter la page (requireView).
func (s *Service) canView(ctx context.Context, viewerPublicID, eventPublicID string) (bool, error) {
	publicID, err := authz.NormalizePublicID(eventPublicID)
	if err != nil || s.authz == nil {
		return false, nil
	}
	allowed, err := s.authz.Check(ctx, authz.CheckRequest{
		Subject:    authz.UserRef(viewerPublicID),
		Permission: authz.PermEventView,
		Object:     authz.Object(authz.TypeEvent, publicID),
	})
	if err != nil {
		log.Printf("event: watch can_view: %v", err)
		return false, err
	}
	return allowed, nil
}
