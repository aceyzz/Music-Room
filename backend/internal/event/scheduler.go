package event

import (
	"context"
	"log"
	"sync"
	"time"

	db "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/realtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// L'avancement automatique de la file : un minuteur par événement en direct
// qui appelle playNext quand le morceau en cours se termine, sans dépendre
// d'un client pour déclencher l'appel (sinon la "radio" resterait bloquée sur
// le dernier morceau joué).
type scheduler struct {
	mu     sync.Mutex
	timers map[int64]*time.Timer
}

func newScheduler() *scheduler {
	return &scheduler{timers: make(map[int64]*time.Timer)}
}

func (s *Service) scheduleAutoAdvance(eventID int64, remaining time.Duration) {
	s.sched.mu.Lock()
	defer s.sched.mu.Unlock()
	if t, ok := s.sched.timers[eventID]; ok {
		t.Stop()
	}
	var timer *time.Timer
	timer = time.AfterFunc(remaining, func() {
		// Hors de la table dès qu'il sonne : la table ne liste que les
		// minuteurs encore à venir, ce que rearmMissing lit. Pas si un autre
		// l'a remplacé entre-temps. (Le verrou, tenu par scheduleAutoAdvance
		// jusqu'à l'affectation plus bas, garantit que timer est déjà posé.)
		s.sched.mu.Lock()
		if s.sched.timers[eventID] == timer {
			delete(s.sched.timers, eventID)
		}
		s.sched.mu.Unlock()
		s.autoAdvance(eventID)
	})
	s.sched.timers[eventID] = timer
}

func (s *Service) cancelAutoAdvance(eventID int64) {
	s.sched.mu.Lock()
	defer s.sched.mu.Unlock()
	if t, ok := s.sched.timers[eventID]; ok {
		t.Stop()
		delete(s.sched.timers, eventID)
	}
}

// EndOverdueEvents termine les événements dont l'heure de fin prévue est
// passée et où rien ne joue (lancés ou non) -- ce que ferait EndEvent, sans
// attendre qu'un hôte appuie dessus -- et arrête leur minuteur. Une soirée
// qui joue continue jusqu'à ce que l'hôte appuie sur End event, ou que la
// musique s'arrête. Sans ça, un événement que personne ne termine reste "en
// cours" pour toujours dans les listes. Renvoie combien ont été terminés.
func (s *Service) EndOverdueEvents(ctx context.Context) (int, error) {
	ids, err := db.New(s.pool).EndOverdueEvents(ctx)
	if err != nil {
		return 0, err
	}
	for _, id := range ids {
		s.cancelAutoAdvance(id)
		s.hub.Publish(realtime.Event(id))
	}
	return len(ids), nil
}

// RunEventEnder appelle EndOverdueEvents toutes les [every], jusqu'à ce que
// ctx soit annulé. À lancer dans sa propre goroutine.
func (s *Service) RunEventEnder(ctx context.Context, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if ended, err := s.EndOverdueEvents(ctx); err != nil {
				log.Printf("event: could not end overdue events: %v", err)
			} else if ended > 0 {
				log.Printf("event: ended %d event(s) past their planned end", ended)
			}
			// Un morceau qui joue sans minuteur ne passerait jamais au suivant :
			// lancé avant ce processus (le seed écrit la base APRÈS le démarrage
			// du backend, dans make eval), ou dont le passage a échoué.
			if armed, err := s.RearmAutoAdvance(ctx); err != nil {
				log.Printf("event: could not re-arm auto-advance timers: %v", err)
			} else if armed > 0 {
				log.Printf("event: re-armed the auto-advance timer of %d playing event(s)", armed)
			}
		}
	}
}

// RearmAutoAdvance arme le minuteur de chaque événement en direct qui joue un
// morceau sans en avoir : les minuteurs vivent en mémoire, un redémarrage du
// backend les perd tous, et des morceaux peuvent jouer sans qu'aucun n'ait été
// armé ici (le seed). Sans lui, l'événement resterait sur son morceau une fois
// celui-ci fini (barre à 30/30) jusqu'à un Next manuel. Un morceau déjà
// terminé passe au suivant tout de suite. Au démarrage, puis toutes les 10 s
// (RunEventEnder). Renvoie le nombre de minuteurs armés.
func (s *Service) RearmAutoAdvance(ctx context.Context) (int, error) {
	rows, err := db.New(s.pool).ListPlayingEvents(ctx)
	if err != nil {
		return 0, err
	}
	return s.rearmMissing(rows), nil
}

// rearmMissing arme ceux de [rows] qui n'ont pas de minuteur à venir. Un
// minuteur déjà armé n'est pas touché : le réarmer avancerait ou retarderait
// un passage déjà prévu, et deux passages feraient sauter un morceau.
func (s *Service) rearmMissing(rows []db.ListPlayingEventsRow) int {
	armed := 0
	for _, row := range rows {
		s.sched.mu.Lock()
		_, pending := s.sched.timers[row.EventID]
		s.sched.mu.Unlock()
		if pending {
			continue
		}
		s.scheduleAutoAdvance(row.EventID, max(0, time.Duration(row.RemainingMs)*time.Millisecond))
		armed++
	}
	return armed
}

// autoAdvance tourne dans la goroutine du minuteur : aucune requête cliente
// ne l'a déclenché, controllerUserID reste donc à 0 (personne).
func (s *Service) autoAdvance(eventID int64) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, err := s.playNext(ctx, eventID, 0); err != nil {
		// File vide (FailedPrecondition) : la radio s'est arrêtée proprement,
		// c'est prévu. Le reste se voit dans les logs, et la vérification
		// suivante (RearmAutoAdvance, toutes les 10 s) réessaiera.
		if status.Code(err) != codes.FailedPrecondition {
			log.Printf("event: auto-advance of event %d failed: %v", eventID, err)
		}
	}
}

func remainingPlayback(positionMs int32, durationSeconds int32) time.Duration {
	remaining := time.Duration(durationSeconds)*time.Second - time.Duration(positionMs)*time.Millisecond
	if remaining < 0 {
		return 0
	}
	return remaining
}
