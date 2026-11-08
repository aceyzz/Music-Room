// Package ratelimit caps how fast one key -- an IP address, a user -- may
// call: each key gets a token bucket, refilled at a rate and holding burst.
// In memory: there is one backend.
//
// The gRPC interceptor uses it per IP address on every call, and per user on
// the social routes (internal/interceptor/throttle.go).
package ratelimit

import (
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// idleAfter is how long a key keeps its bucket without calling. A bucket
// left alone that long is full again anyway, so forgetting it changes nothing.
const idleAfter = 10 * time.Minute

type Limiter struct {
	limit rate.Limit
	burst int

	mu    sync.Mutex
	keys  map[string]*entry
	swept time.Time
	now   func() time.Time
}

type entry struct {
	bucket *rate.Limiter
	seen   time.Time
}

// New refills each key's bucket at limit tokens a second (rate.Every for
// less than one), up to burst.
func New(limit rate.Limit, burst int) *Limiter {
	return &Limiter{
		limit: limit,
		burst: burst,
		keys:  map[string]*entry{},
		now:   time.Now,
	}
}

// Allow takes one token from key's bucket.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	if now.Sub(l.swept) > idleAfter {
		for key, a := range l.keys {
			if now.Sub(a.seen) > idleAfter {
				delete(l.keys, key)
			}
		}
		l.swept = now
	}
	a, ok := l.keys[key]
	if !ok {
		a = &entry{bucket: rate.NewLimiter(l.limit, l.burst)}
		l.keys[key] = a
	}
	a.seen = now
	return a.bucket.AllowN(now, 1)
}
