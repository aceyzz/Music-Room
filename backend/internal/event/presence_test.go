package event

import (
	"testing"
	"time"
)

func TestPresence(t *testing.T) {
	const event, host = int64(1), int64(7)
	start := time.Date(2026, 10, 17, 20, 0, 0, 0, time.UTC)

	t.Run("a host with the page open is never absent", func(t *testing.T) {
		p := newPresence()
		leave := p.watch(event, host)
		defer leave()
		if got := p.absentFor(event, host, start.Add(time.Hour)); got != 0 {
			t.Fatalf("absent for %v, want 0", got)
		}
	})

	t.Run("absence counts from the first sweep that sees it", func(t *testing.T) {
		p := newPresence()
		p.watch(event, host)() // came and left
		if got := p.absentFor(event, host, start); got != 0 {
			t.Fatalf("first sweep: %v, want 0", got)
		}
		if got := p.absentFor(event, host, start.Add(12*time.Second)); got != 12*time.Second {
			t.Fatalf("second sweep: %v, want 12s", got)
		}
	})

	t.Run("two pages: closing one keeps the host there", func(t *testing.T) {
		p := newPresence()
		leaveA, leaveB := p.watch(event, host), p.watch(event, host)
		leaveA()
		defer leaveB()
		p.absentFor(event, host, start)
		if got := p.absentFor(event, host, start.Add(time.Minute)); got != 0 {
			t.Fatalf("absent for %v, want 0", got)
		}
	})

	t.Run("coming back, or the event stopping, forgets the absence", func(t *testing.T) {
		p := newPresence()
		p.absentFor(event, host, start)
		leave := p.watch(event, host)
		p.absentFor(event, host, start.Add(5*time.Second))
		leave()
		if got := p.absentFor(event, host, start.Add(20*time.Second)); got != 0 {
			t.Fatalf("after coming back: %v, want 0 (a new absence)", got)
		}

		p.keepOnly(map[int64]bool{}) // no longer playing
		if got := p.absentFor(event, host, start.Add(time.Hour)); got != 0 {
			t.Fatalf("after stopping: %v, want 0 (a new absence)", got)
		}
	})
}
