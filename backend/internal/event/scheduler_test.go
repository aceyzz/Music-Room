package event

import (
	"testing"
	"time"

	db "example.com/music-app/db/sqlc"
)

// A song playing with no timer (seeded after the backend started, or a
// failed advance) gets one; a timer already set is left as it is, or the
// event would advance twice and skip a song.
func TestRearmArmsOnlyEventsWithoutATimer(t *testing.T) {
	s := &Service{sched: newScheduler()}
	hour := int64(time.Hour / time.Millisecond)
	s.scheduleAutoAdvance(1, time.Hour)
	before := s.sched.timers[1]
	t.Cleanup(func() {
		for _, timer := range s.sched.timers {
			timer.Stop()
		}
	})

	armed := s.rearmMissing([]db.ListPlayingEventsRow{
		{EventID: 1, RemainingMs: hour},
		{EventID: 2, RemainingMs: hour},
	})

	if armed != 1 {
		t.Errorf("armed %d timers, want 1 (only event 2)", armed)
	}
	if s.sched.timers[1] != before {
		t.Error("event 1 already had a timer, and it was replaced")
	}
	if s.sched.timers[2] == nil {
		t.Error("event 2 played without a timer, and still has none")
	}
}
