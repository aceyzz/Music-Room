// Package realtime tells open streams that something they show has changed.
//
// A signal carries no data, only "topic X changed". Each stream then rereads
// the state through the same queries as the unary reads and sends it to its
// own viewer: the fields that differ per viewer (viewer_has_voted,
// viewer_can_control, viewer_can_edit_songs) stay right, and what a client
// receives is always a committed state, never a delta to merge.
//
// In memory, so one backend process. Several would need the signal to cross
// processes (Redis pub/sub, already connected in cmd/main.go) behind the same
// two methods.
package realtime

import (
	"fmt"
	"sync"
)

// Topic names one object whose viewers want to hear about changes.
type Topic string

func Playlist(id int64) Topic { return Topic(fmt.Sprintf("playlist:%d", id)) }
func Event(id int64) Topic    { return Topic(fmt.Sprintf("event:%d", id)) }

type Hub struct {
	mu   sync.Mutex
	subs map[Topic]map[chan struct{}]struct{}
}

func NewHub() *Hub {
	return &Hub{subs: map[Topic]map[chan struct{}]struct{}{}}
}

// Publish wakes every subscriber of topic. Call it after the commit, never
// inside the transaction: a stream woken early would reread the old state.
//
// It never blocks. Each subscriber's channel holds one pending signal, and one
// is all it needs since it rereads everything: a burst of 100 votes during one
// send collapses into a single reread. A nil Hub does nothing, so services
// built without one (tests) need no special case.
func (h *Hub) Publish(topic Topic) {
	if h == nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs[topic] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}

// Subscribe returns a channel signalled after each Publish on topic, and the
// function that ends the subscription. Call it before the first read, so a
// change committed between the two is not missed.
func (h *Hub) Subscribe(topic Topic) (<-chan struct{}, func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	if h.subs[topic] == nil {
		h.subs[topic] = map[chan struct{}]struct{}{}
	}
	h.subs[topic][ch] = struct{}{}
	h.mu.Unlock()

	return ch, func() {
		h.mu.Lock()
		defer h.mu.Unlock()
		delete(h.subs[topic], ch)
		if len(h.subs[topic]) == 0 {
			delete(h.subs, topic)
		}
	}
}
