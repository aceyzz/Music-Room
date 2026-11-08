package realtime

import "testing"

func signalled(ch <-chan struct{}) bool {
	select {
	case <-ch:
		return true
	default:
		return false
	}
}

func TestPublishWakesOnlyThatTopic(t *testing.T) {
	h := NewHub()
	a, stopA := h.Subscribe(Playlist(1))
	defer stopA()
	b, stopB := h.Subscribe(Playlist(2))
	defer stopB()

	h.Publish(Playlist(1))

	if !signalled(a) {
		t.Error("the subscriber of playlist 1 was not woken")
	}
	if signalled(b) {
		t.Error("the subscriber of playlist 2 was woken by playlist 1")
	}
}

// A burst of changes while the stream is busy sending is one reread, not a
// backlog: the stream rereads everything anyway.
func TestBurstCollapsesIntoOneSignal(t *testing.T) {
	h := NewHub()
	ch, stop := h.Subscribe(Event(1))
	defer stop()

	for range 100 {
		h.Publish(Event(1))
	}

	if !signalled(ch) {
		t.Fatal("no signal after 100 publishes")
	}
	if signalled(ch) {
		t.Error("more than one pending signal")
	}
}

func TestStoppedSubscriberHearsNothing(t *testing.T) {
	h := NewHub()
	ch, stop := h.Subscribe(Event(1))
	stop()

	h.Publish(Event(1))

	if signalled(ch) {
		t.Error("a stopped subscriber was woken")
	}
	if len(h.subs) != 0 {
		t.Errorf("topics left behind: %v", h.subs)
	}
}

func TestNilHubPublishIsANoOp(t *testing.T) {
	var h *Hub
	h.Publish(Playlist(1)) // must not panic
}
