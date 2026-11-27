package dnsfilter

import (
	"net/netip"
	"sync"
	"time"
)

// Limiter is a token-bucket rate limit per client address and port. After
// the firewall's redirect every app's query arrives from the phone's own
// address, so the client port is what tells sockets apart. Android's
// resolver opens a new socket for most queries; one socket sending many
// queries quickly is a misbehaving or hostile app.
type Limiter struct {
	mu      sync.Mutex
	rate    float64 // tokens per second
	burst   float64
	maxKeys int
	m       map[netip.AddrPort]*bucket
	now     func() time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// NewLimiter returns a limiter that allows rate queries per second per
// client port, with bursts of up to burst queries. It tracks at most
// maxKeys client ports; when that many are tracked, idle ones are
// forgotten. A rate of 0 or less disables the limit.
func NewLimiter(rate float64, burst, maxKeys int) *Limiter {
	if burst < 1 {
		burst = 1
	}
	if maxKeys < 16 {
		maxKeys = 16
	}
	return &Limiter{rate: rate, burst: float64(burst), maxKeys: maxKeys,
		m: map[netip.AddrPort]*bucket{}, now: time.Now}
}

// Allow takes one token for key and reports whether there was one.
func (l *Limiter) Allow(key netip.AddrPort) bool {
	if l == nil || l.rate <= 0 {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	b := l.m[key]
	if b == nil {
		if len(l.m) >= l.maxKeys {
			l.sweep(now)
		}
		b = &bucket{tokens: l.burst, last: now}
		l.m[key] = b
	} else {
		b.tokens += now.Sub(b.last).Seconds() * l.rate
		if b.tokens > l.burst {
			b.tokens = l.burst
		}
		b.last = now
	}
	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// sweep forgets buckets that have refilled completely: forgetting them
// changes nothing. If that frees too little, it forgets everything; the
// limit is then briefly looser, and the cap on queries waiting for tor
// still holds.
func (l *Limiter) sweep(now time.Time) {
	for k, b := range l.m {
		if b.tokens+now.Sub(b.last).Seconds()*l.rate >= l.burst {
			delete(l.m, k)
		}
	}
	if len(l.m) >= l.maxKeys*3/4 {
		clear(l.m)
	}
}

// Len returns the number of tracked client ports.
func (l *Limiter) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.m)
}
