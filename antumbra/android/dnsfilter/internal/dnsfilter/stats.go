// Package dnsfilter is the DNS side of antumbra-dnsfilter: it answers
// queries for blocked and local names itself and forwards the rest to
// tor's DNSPort, failing closed when tor does not answer.
package dnsfilter

import (
	"sync/atomic"
	"time"
)

// Stats are the filter's counters. They hold no names and no addresses.
// All fields are safe for concurrent use.
type Stats struct {
	Queries        atomic.Uint64 // well-formed query messages received
	Blocked        atomic.Uint64 // answered as blocked (by the list)
	Forwarded      atomic.Uint64 // answered from tor's reply
	Local          atomic.Uint64 // answered here by policy (local names, AAAA, other types)
	ServFail       atomic.Uint64 // answered SERVFAIL (tor down, slow or wrong; overload)
	Refused        atomic.Uint64 // answered REFUSED (ANY, AXFR, other classes)
	FormErr        atomic.Uint64 // answered FORMERR (malformed question)
	NotImp         atomic.Uint64 // answered NOTIMP (opcodes other than QUERY)
	RateLimited    atomic.Uint64 // dropped by the per-client-port rate limit
	Dropped        atomic.Uint64 // dropped: not a query, too short, or overload
	UpstreamErrors atomic.Uint64 // failed exchanges with tor

	lastUpstream atomic.Pointer[upstreamState]
}

type upstreamState struct {
	ok   bool
	err  string
	when time.Time
}

// noteUpstream records the outcome of the latest exchange with tor. err
// must be a fixed short code, never text that could hold a name.
func (s *Stats) noteUpstream(ok bool, err string) {
	s.lastUpstream.Store(&upstreamState{ok: ok, err: err, when: time.Now()})
}

// Upstream returns whether the latest exchange with tor succeeded, its
// error code if not, and when it happened. known is false before the first
// exchange.
func (s *Stats) Upstream() (known, ok bool, err string, when time.Time) {
	u := s.lastUpstream.Load()
	if u == nil {
		return false, false, "", time.Time{}
	}
	return true, u.ok, u.err, u.when
}
