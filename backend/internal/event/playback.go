package event

import (
	"context"
	"errors"

	db "example.com/music-app/db/sqlc"
	pb "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/realtime"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// GetEventPlayback est la "radio station" : ce qui joue actuellement pour cet
// événement, avec la position de lecture au moment de updated_at.
// Si aucun morceau n'est en cours, current_queue_entry_id vaut 0 et current_song est nil.
//
// is_paused dans la réponse n'est PAS un simple miroir de la colonne
// event_playback_states.is_paused -- voir playbackStateDTO plus bas pour
// pourquoi.
func (s *Service) GetEventPlayback(ctx context.Context, req *pb.GetEventPlaybackRequest) (*pb.GetEventPlaybackResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	// event#can_view a déjà répondu, et l'événement existe : son UUID vient
	// d'être résolu -- loadPlaybackDTO relit quand même la ligne events,
	// mais pour calculer is_paused (voir plus haut), plus pour décider quoi
	// que ce soit ici.
	queries := db.New(s.pool)
	dto, err := s.loadPlaybackDTO(ctx, queries, req.GetEventId())
	if err != nil {
		return nil, err
	}
	// viewer_can_control : l'app n'affiche les commandes qu'à qui peut s'en
	// servir -- l'hôte, et un ami qui tient une licence sur l'enceinte.
	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	canControl, err := s.canControlPlayback(ctx, queries, event, req.GetViewerId())
	if err != nil {
		return nil, err
	}
	return &pb.GetEventPlaybackResponse{Playback: dto, ViewerCanControl: canControl}, nil
}

// PlayNextInEventQueue termine le morceau en cours (s'il y en a un) et lance
// le morceau le mieux voté de la file, faisant réellement jouer la playlist
// en direct.
func (s *Service) PlayNextInEventQueue(ctx context.Context, req *pb.PlayNextInEventQueueRequest) (*pb.PlayNextInEventQueueResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	queries := db.New(s.pool)
	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	canControl, err := s.canControlPlayback(ctx, queries, event, req.GetUserId())
	if err != nil {
		return nil, err
	}
	if !canControl {
		return nil, status.Error(codes.PermissionDenied, "not allowed to control playback for this event")
	}
	// Avant playNext, pour que la réponse et le push portent déjà l'enceinte.
	if err := s.claimSpeaker(ctx, queries, event, req.GetUserId()); err != nil {
		return nil, err
	}

	playback, queueDto, err := s.playNext(ctx, req.GetEventId(), req.GetUserId())
	if err != nil {
		return nil, err
	}
	return &pb.PlayNextInEventQueueResponse{Playback: playback, Queue: queueDto}, nil
}

// playNext contient la logique partagée entre l'appel manuel (RPC) et
// l'avancement automatique du minuteur (scheduler.go).
func (s *Service) playNext(ctx context.Context, eventID, controllerUserID int64) (*pb.EventPlaybackDTO, []*pb.EventQueueEntryDTO, error) {
	tx, queries, err := s.beginTx(ctx)
	if err != nil {
		return nil, nil, err
	}
	// Déclaré avant le Rollback, donc exécuté après lui : la transaction est
	// close quand les WatchEvent relisent. Sur tous les chemins, échecs
	// compris -- une relecture de trop ne coûte rien, et Next comme le
	// minuteur d'auto-advance passent tous deux par ici.
	defer s.hub.Publish(realtime.Event(eventID))
	defer tx.Rollback(ctx)

	// `ended` est terminal (docs/permissions.md §13) : rien ne doit plus
	// avancer la lecture d'un événement terminé, ni un skip manuel, ni le
	// minuteur d'auto-advance -- les deux passent par ici.
	event, err := queries.GetEventByID(ctx, eventID)
	if err != nil {
		return nil, nil, databaseError(err)
	}
	if event.Status == db.EventStatusEnded {
		return nil, nil, status.Error(codes.FailedPrecondition, "this event has ended")
	}

	// Verrouille la ligne : deux avancées concurrentes pour le même événement
	// (le minuteur d'auto-advance face à un skip manuel, ou deux skips) se
	// sérialisent au lieu de démarrer chacune un morceau.
	current, err := queries.GetEventPlaybackStateForUpdate(ctx, eventID)
	if err != nil {
		return nil, nil, databaseError(err)
	}
	next, err := queries.GetNextQueuedEntry(ctx, eventID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			// La file est à sec : si un morceau était en cours, on arrête
			// proprement la radio plutôt que de le laisser affiché comme
			// "en cours" avec une position qui dérive au-delà de sa durée.
			if current.CurrentEntryID.Valid {
				if err := queries.MarkQueueEntryPlayed(ctx, current.CurrentEntryID.Int64); err != nil {
					return nil, nil, databaseError(err)
				}
				if _, err := queries.StopEventPlayback(ctx, eventID); err != nil {
					return nil, nil, databaseError(err)
				}
				if err := commitTx(ctx, tx, "could not stop the event playback"); err != nil {
					return nil, nil, err
				}
				s.cancelAutoAdvance(eventID)
			}
			return nil, nil, status.Error(codes.FailedPrecondition, "the queue is empty")
		}
		return nil, nil, databaseError(err)
	}

	if current.CurrentEntryID.Valid {
		if err := queries.MarkQueueEntryPlayed(ctx, current.CurrentEntryID.Int64); err != nil {
			return nil, nil, databaseError(err)
		}
	}
	if err := queries.MarkQueueEntryPlaying(ctx, next.ID); err != nil {
		return nil, nil, databaseError(err)
	}
	playback, err := queries.StartEventPlayback(ctx, db.StartEventPlaybackParams{
		EventID: eventID, CurrentEntryID: pgtype.Int8{Int64: next.ID, Valid: true},
		ControllerUserID: controllerUserID,
	})
	if err != nil {
		return nil, nil, databaseError(err)
	}
	// A song actually starting is what makes the event live -- the first
	// time, scheduled -> live: no request does it otherwise. `live` itself
	// never reaches this branch (guarded below), and MarkEventLive's own
	// WHERE only matches scheduled, so this call is never a spurious no-op
	// once we get here -- UNLESS an EndEvent raced this same
	// transition concurrently (it does not share the row lock above, which
	// is only on event_playback_states): that is a real conflict, not
	// something to paper over, so it aborts the whole advance rather than
	// committing playback against a status nobody agreed on.
	if event.Status != db.EventStatusLive {
		if _, err := queries.MarkEventLive(ctx, eventID); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return nil, nil, status.Error(codes.Aborted, "event status changed concurrently, retry")
			}
			return nil, nil, databaseError(err)
		}
	}
	if err := commitTx(ctx, tx, "could not advance the event playback"); err != nil {
		return nil, nil, err
	}

	queueDto, err := s.listQueue(ctx, eventID, controllerUserID)
	if err != nil {
		return nil, nil, err
	}

	// Programme la fin de ce morceau : la radio avancera toute seule.
	s.scheduleAutoAdvance(eventID, remainingPlayback(0, next.Song.DurationSeconds))

	// db.EventStatusLive, pas event.Status : ce dernier peut encore lire
	// scheduled (valeur lue avant la promotion plus haut), alors
	// qu'à ce point de la fonction l'événement EST live, par construction
	// (MarkEventLive vient de le garantir, ou il l'était déjà).
	song := s.withFreshPreview(ctx, next.Song)
	return playbackStateDTO(playback, db.EventStatusLive, &song), queueDto, nil
}

// SetEventPlayback met en pause, reprend ou déplace la tête de lecture du
// morceau en cours.
func (s *Service) SetEventPlayback(ctx context.Context, req *pb.SetEventPlaybackRequest) (*pb.SetEventPlaybackResponse, error) {
	if req.GetEventId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "event_id is required")
	}
	queries := db.New(s.pool)
	event, err := queries.GetEventByID(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	canControl, err := s.canControlPlayback(ctx, queries, event, req.GetUserId())
	if err != nil {
		return nil, err
	}
	if !canControl {
		return nil, status.Error(codes.PermissionDenied, "not allowed to control playback for this event")
	}
	// docs/permissions.md §12 : pause/reprise/seek exigent un événement live --
	// contrairement à PlayNextInEventQueue (playNext, plus haut), qui LUI
	// promeut scheduled vers live en démarrant un morceau, cette RPC ne fait
	// qu'agir sur un morceau déjà en cours : rien à mettre en pause ou à
	// repositionner sur un événement jamais démarré (`scheduled`) ou terminé
	// (`ended`).
	if event.Status != db.EventStatusLive {
		return nil, status.Error(codes.FailedPrecondition, "this event is not open for playback control")
	}
	if err := s.claimSpeaker(ctx, queries, event, req.GetUserId()); err != nil {
		return nil, err
	}

	if _, err := queries.SetEventPlaybackState(ctx, db.SetEventPlaybackStateParams{
		EventID: req.GetEventId(), IsPaused: req.GetIsPaused(), PositionMs: req.GetPositionMs(),
		ControllerUserID: req.GetUserId(),
	}); err != nil {
		return nil, databaseError(err)
	}
	row, err := queries.GetEventPlaybackState(ctx, req.GetEventId())
	if err != nil {
		return nil, databaseError(err)
	}
	if !row.CurrentEntryID.Valid {
		s.cancelAutoAdvance(req.GetEventId())
		s.hub.Publish(realtime.Event(req.GetEventId()))
		return &pb.SetEventPlaybackResponse{Playback: playbackStateDTO(row, event.Status, nil)}, nil
	}
	// The song goes out paused too, not only playing: without it, a paused
	// answer read as "nothing is playing", and the app's play button then
	// started the NEXT song instead of resuming this one.
	song, err := queries.GetQueueEntrySong(ctx, row.CurrentEntryID.Int64)
	if err != nil {
		return nil, databaseError(err)
	}
	// The event is live (guarded above): the music's own pause decides
	// whether the auto-advance timer runs.
	if row.IsPaused {
		s.cancelAutoAdvance(req.GetEventId())
	} else {
		s.scheduleAutoAdvance(req.GetEventId(), remainingPlayback(row.PositionMs, song.DurationSeconds))
	}
	song = s.withFreshPreview(ctx, song)
	s.hub.Publish(realtime.Event(req.GetEventId()))
	return &pb.SetEventPlaybackResponse{Playback: playbackStateDTO(row, event.Status, &song)}, nil
}

// loadPlaybackDTO charge l'état de lecture et le statut de l'événement (dont
// playbackStateDTO a besoin, voir son commentaire), puis, s'il y a un
// morceau courant, le récupère séparément (pas de LEFT JOIN à scanner en
// NULL).
func (s *Service) loadPlaybackDTO(ctx context.Context, queries *db.Queries, eventID int64) (*pb.EventPlaybackDTO, error) {
	event, err := queries.GetEventByID(ctx, eventID)
	if err != nil {
		return nil, databaseError(err)
	}
	row, err := queries.GetEventPlaybackState(ctx, eventID)
	if err != nil {
		return nil, databaseError(err)
	}
	if !row.CurrentEntryID.Valid {
		return playbackStateDTO(row, event.Status, nil), nil
	}
	song, err := queries.GetQueueEntrySong(ctx, row.CurrentEntryID.Int64)
	if err != nil {
		return nil, databaseError(err)
	}
	song = s.withFreshPreview(ctx, song)
	return playbackStateDTO(row, event.Status, &song), nil
}

// playbackStateDTO convertit un état de lecture, avec le morceau courant s'il
// y en a un (nil sinon).
//
// IsPaused n'est PAS un miroir brut de p.IsPaused : il est vrai aussi dès que
// l'événement n'est pas `live` (scheduled ou ended). C'est une
// DÉRIVATION à la lecture, pas une synchronisation à l'écriture --
// MarkEventLive et EndEvent ne touchent
// jamais event_playback_states, et n'ont pas besoin de le faire : is_paused
// affiché est toujours recalculé ici à partir de la colonne ET du statut, ce
// qui rend une désynchronisation entre les deux structurellement impossible
// (il n'y a rien à garder synchronisé).
func playbackStateDTO(p db.EventPlaybackState, eventStatus db.EventStatus, song *db.Song) *pb.EventPlaybackDTO {
	dto := &pb.EventPlaybackDTO{
		EventId: p.EventID, CurrentQueueEntryId: p.CurrentEntryID.Int64,
		IsPaused:   p.IsPaused || eventStatus != db.EventStatusLive,
		PositionMs: p.PositionMs, ControllerUserId: p.ControllerUserID.Int64,
		SpeakerDeviceId: p.SpeakerDeviceID.Int64,
		StartedAt:       unixOrZero(p.StartedAt), UpdatedAt: unixOrZero(p.UpdatedAt),
	}
	if song != nil {
		dto.CurrentSong = songDTO(*song)
	}
	return dto
}

func unixOrZero(t pgtype.Timestamptz) int64 {
	if !t.Valid {
		return 0
	}
	return t.Time.Unix()
}
