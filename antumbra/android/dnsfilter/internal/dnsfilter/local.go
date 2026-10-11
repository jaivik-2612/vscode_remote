package dnsfilter

import (
	"sort"
	"strconv"
	"strings"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
)

// localZones are names that only mean something on the phone or on a
// local network. Sent through Tor, a lookup of one would tell the exit
// about the person's network: the name of their router or printer, or a
// private address they talk to. The filter answers them itself with "no
// such name". ".onion" and ".exit" are not here: tor maps those itself.
var localZones = func() []string {
	z := []string{
		// Special-use names (RFC 6761, 6762, 8375, 9476), ICANN's private-use
		// top-level domain, and suffixes home routers use that the DNS root
		// does not delegate.
		"alt", "corp", "home", "home.arpa", "internal", "invalid", "lan",
		"local", "localdomain", "test",
		// Reverse zones of private and special IPv4 ranges (RFC 6303,
		// RFC 7793, RFC 5737).
		"0.in-addr.arpa", "10.in-addr.arpa", "127.in-addr.arpa",
		"254.169.in-addr.arpa", "168.192.in-addr.arpa",
		"2.0.192.in-addr.arpa", "100.51.198.in-addr.arpa",
		"113.0.203.in-addr.arpa", "255.255.255.255.in-addr.arpa",
		// Reverse zones of IPv6 unique-local, link-local and documentation
		// addresses.
		"c.f.ip6.arpa", "d.f.ip6.arpa", "8.e.f.ip6.arpa", "9.e.f.ip6.arpa",
		"a.e.f.ip6.arpa", "b.e.f.ip6.arpa", "8.b.d.0.1.0.0.2.ip6.arpa",
		// :: and ::1.
		strings.Repeat("0.", 32) + "ip6.arpa",
		"1." + strings.Repeat("0.", 31) + "ip6.arpa",
	}
	for i := 16; i <= 31; i++ { // 172.16.0.0/12
		z = append(z, strconv.Itoa(i)+".172.in-addr.arpa")
	}
	for i := 64; i <= 127; i++ { // 100.64.0.0/10, shared address space
		z = append(z, strconv.Itoa(i)+".100.in-addr.arpa")
	}
	sort.Strings(z)
	return z
}()

// local answers names for the phone itself ("localhost", RFC 6761) and
// the local zones above. ok is false for every other name.
func (h *Handler) local(q dnsmessage.Question, name string) (r result, ok bool) {
	if name == "localhost" || strings.HasSuffix(name, ".localhost") {
		rh := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: h.cfg.BlockedTTL}
		switch {
		case q.Type == dnsmessage.TypeA:
			rh.Type = dnsmessage.TypeA
			return result{answers: []dnsmessage.Resource{{Header: rh,
				Body: &dnsmessage.AResource{A: [4]byte{127, 0, 0, 1}}}}}, true
		case q.Type == dnsmessage.TypeAAAA && !h.cfg.FilterAAAA:
			rh.Type = dnsmessage.TypeAAAA
			return result{answers: []dnsmessage.Resource{{Header: rh,
				Body: &dnsmessage.AAAAResource{AAAA: [16]byte{15: 1}}}}}, true
		}
		return result{rcode: dnsmessage.RCodeSuccess, soa: true}, true
	}
	if blocklist.Covers(localZones, name) {
		return result{rcode: dnsmessage.RCodeNameError, soa: true}, true
	}
	return result{}, false
}
