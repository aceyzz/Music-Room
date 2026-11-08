package event

import (
	"context"
	"log"
	"sync"
	"time"

	db "example.com/music-app/db/sqlc"
	"example.com/music-app/internal/realtime"
)

// La musique d'un événement sort du téléphone de son hôte, et de lui seul.
// Quand l'hôte n'a plus la page ouverte, rien ne s'entend : la lecture se met
// en pause, pour que les invités le voient et que la file ne défile pas dans
// le vide. Elle ne repart pas toute seule : l'hôte appuie sur Play.
//
// "La page ouverte", c'est un WatchEvent ouvert par l'hôte. En mémoire, comme
// le hub : un seul processus.

// speakerGrace : combien de temps l'hôte peut manquer avant la pause, pour
// un changement de page ou une courte coupure réseau (l'app retente après 1
// puis 2 s). Avec le balayage toutes les 2 s (cmd/main.go), la pause arrive 5
// à 9 s après le départ.
const speakerGrace = 5 * time.Second

type presence struct {
	mu sync.Mutex
	// open compte les WatchEvent ouverts par (événement, utilisateur).
	open map[[2]int64]int
	// missing : depuis quand le balayage voit un hôte absent.
	missing map[int64]time.Time
}

func newPresence() *presence {
	return &presence{open: map[[2]int64]int{}, missing: map[int64]time.Time{}}
}

// watch note un flux ouvert par userID sur eventID ; la fonction rendue le
// ferme.
func (p *presence) watch(eventID, userID int64) func() {
	key := [2]int64{eventID, userID}
	p.mu.Lock()
	p.open[key]++
	p.mu.Unlock()
	return func() {
		p.mu.Lock()
		defer p.mu.Unlock()
		if p.open[key]--; p.open[key] <= 0 {
			delete(p.open, key)
		}
	}
}

// absentFor dit depuis combien de temps l'hôte manque, vu par le balayage :
// 0 s'il est là, ou la première fois qu'il manque.
func (p *presence) absentFor(eventID, hostID int64, now time.Time) time.Duration {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.open[[2]int64{eventID, hostID}] > 0 {
		delete(p.missing, eventID)
		return 0
	}
	since, seen := p.missing[eventID]
	if !seen {
		p.missing[eventID] = now
		return 0
	}
	return now.Sub(since)
}

// keepOnly oublie les absences notées pour les événements qui ne jouent plus :
// relancé plus tard, l'un d'eux repartirait sinon avec une vieille absence.
func (p *presence) keepOnly(playing map[int64]bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for eventID := range p.missing {
		if !playing[eventID] {
			delete(p.missing, eventID)
		}
	}
}

// PauseAbsentSpeakers met en pause la musique de chaque événement qui joue
// alors que son hôte n'a plus la page ouverte depuis speakerGrace. Après un
// redémarrage, la mémoire est vide : la musique d'un hôte qui ne revient pas
// est mise en pause pareil.
// Renvoie combien l'ont été.
func (s *Service) PauseAbsentSpeakers(ctx context.Context) (int, error) {
	queries := db.New(s.pool)
	rows, err := queries.ListPlayingEventHosts(ctx)
	if err != nil {
		return 0, err
	}
	now := time.Now()
	playing := map[int64]bool{}
	for _, row := range rows {
		playing[row.EventID] = true
	}
	s.presence.keepOnly(playing)
	paused := 0
	for _, row := range rows {
		if s.presence.absentFor(row.EventID, row.HostID, now) < speakerGrace {
			continue
		}
		if _, err := queries.SetEventPlaybackState(ctx, db.SetEventPlaybackStateParams{
			EventID: row.EventID, IsPaused: true, PositionMs: row.PositionMs,
			ControllerUserID: row.HostID,
		}); err != nil {
			return paused, err
		}
		s.cancelAutoAdvance(row.EventID)
		s.hub.Publish(realtime.Event(row.EventID))
		paused++
	}
	return paused, nil
}

// RunSpeakerCheck appelle PauseAbsentSpeakers toutes les [every], jusqu'à ce
// que ctx soit annulé. À lancer dans sa propre goroutine.
func (s *Service) RunSpeakerCheck(ctx context.Context, every time.Duration) {
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if paused, err := s.PauseAbsentSpeakers(ctx); err != nil {
				log.Printf("event: could not pause events whose host left: %v", err)
			} else if paused > 0 {
				log.Printf("event: paused %d event(s) whose host left the page", paused)
			}
		}
	}
}
