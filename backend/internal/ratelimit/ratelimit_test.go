package ratelimit

import (
	"testing"
	"time"
)

func TestBurstThenRefill(t *testing.T) {
	l := New(2, 3)
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	l.now = func() time.Time { return now }

	for i := range 3 {
		if !l.Allow("198.51.100.1") {
			t.Fatalf("request %d of the burst refused", i+1)
		}
	}
	if l.Allow("198.51.100.1") {
		t.Fatal("a request past the burst was allowed")
	}
	if !l.Allow("198.51.100.2") {
		t.Fatal("another address shares the first one's bucket")
	}

	now = now.Add(500 * time.Millisecond) // 2 per second: one token back
	if !l.Allow("198.51.100.1") {
		t.Fatal("the bucket did not refill")
	}
	if l.Allow("198.51.100.1") {
		t.Fatal("refilled more than the rate")
	}
}

func TestIdleAddressesAreForgotten(t *testing.T) {
	l := New(1, 1)
	now := time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)
	l.now = func() time.Time { return now }

	l.Allow("198.51.100.1")
	now = now.Add(idleAfter + time.Second)
	l.Allow("198.51.100.2")
	if _, ok := l.keys["198.51.100.1"]; ok {
		t.Error("an idle address kept its bucket")
	}
}
