package listc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/netip"
	"strings"

	"antumbra/dnsfilter/internal/blocklist"
)

// Counts says how many entries a source gave.
type Counts struct {
	Valid   int // usable entries (before deduplication)
	Invalid int // entries that are not valid domains or addresses
}

// hostsNames are the names hosts files map to themselves. They are not
// blocklist entries and are skipped without counting as invalid.
var hostsNames = map[string]bool{
	"localhost": true, "localhost.localdomain": true, "local": true,
	"broadcasthost": true, "ip6-localhost": true, "ip6-loopback": true,
	"ip6-localnet": true, "ip6-mcastprefix": true, "ip6-allnodes": true,
	"ip6-allrouters": true, "ip6-allhosts": true, "0.0.0.0": true,
}

// ParseDomains reads a domain list and calls add for each valid, canonical
// domain. It accepts, one entry per line:
//
//	example.com              a plain domain
//	*.example.com            a wildcard (the same as example.com here)
//	||example.com^           an Adblock-style domain rule without options
//	0.0.0.0 a.com b.com      a hosts-file line (any address, many names)
//
// Lines starting with '#' or '!', and text after '#', are comments.
func ParseDomains(r io.Reader, add func(string)) (Counts, error) {
	var c Counts
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			line = strings.TrimPrefix(line, "\uFEFF")
			first = false
		}
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" || line[0] == '!' || line[0] == '[' {
			continue
		}
		fields := strings.Fields(line)
		names := fields
		if len(fields) > 1 {
			if _, err := netip.ParseAddr(fields[0]); err != nil {
				c.Invalid++
				continue
			}
			names = fields[1:]
		}
		for _, n := range names {
			n = strings.TrimPrefix(n, "||")
			n = strings.TrimSuffix(n, "^")
			n = strings.TrimPrefix(n, "*.")
			n = blocklist.Canonical(n)
			if hostsNames[n] {
				continue
			}
			if !blocklist.ValidDomain(n) {
				c.Invalid++
				continue
			}
			c.Valid++
			add(n)
		}
	}
	return c, sc.Err()
}

// ParseETIP reads the Exodus Privacy tracker list (JSON from
// https://reports.exodus-privacy.eu.org/api/trackers, or the ETIP export)
// and calls add for each domain in the trackers' network signatures.
//
// A network signature is a regular expression such as
// "adjust\.com|adj\.st|\.exacttarget\.". Each alternative that is a plain
// domain once its escaped dots are unescaped (and a leading "^", ".*" or
// "." and a trailing "$" are removed) becomes an entry; anything else
// ("mt[0-9]*\.google\.cn", a bare word, an address with a path) is
// counted as invalid and left out.
func ParseETIP(r io.Reader, add func(string)) (Counts, error) {
	var c Counts
	data, err := io.ReadAll(r)
	if err != nil {
		return c, err
	}
	var doc struct {
		Trackers json.RawMessage `json:"trackers"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return c, err
	}
	type tracker struct {
		NetworkSignature string `json:"network_signature"`
	}
	var list []tracker
	raw := bytes.TrimSpace(doc.Trackers)
	switch {
	case len(raw) == 0:
		return c, errors.New(`no "trackers" member`)
	case raw[0] == '[':
		if err := json.Unmarshal(raw, &list); err != nil {
			return c, err
		}
	case raw[0] == '{':
		var byID map[string]tracker
		if err := json.Unmarshal(raw, &byID); err != nil {
			return c, err
		}
		for _, t := range byID {
			list = append(list, t)
		}
	default:
		return c, errors.New(`"trackers" is neither a list nor an object`)
	}
	for _, t := range list {
		if strings.TrimSpace(t.NetworkSignature) == "" {
			continue
		}
		for _, alt := range strings.Split(t.NetworkSignature, "|") {
			d, ok := signatureDomain(alt)
			if !ok {
				c.Invalid++
				continue
			}
			c.Valid++
			add(d)
		}
	}
	return c, nil
}

func signatureDomain(s string) (string, bool) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "^")
	s = strings.TrimSuffix(s, "$")
	s = strings.TrimPrefix(s, ".*")
	s = strings.ReplaceAll(s, `\.`, ".")
	s = strings.ReplaceAll(s, `\-`, "-")
	s = strings.Trim(s, ".")
	s = blocklist.Canonical(s)
	return s, blocklist.ValidDomain(s)
}

// ParseIPv4 reads a list of IPv4 addresses ("192.0.2.1" or "192.0.2.1/32",
// one per line, '#' comments) and calls add for each one that is a public
// unicast address. Wider prefixes are counted as invalid, so that a broken
// or poisoned download cannot make the firewall reject whole ranges for
// every app (today's source lists single addresses only). Special-purpose
// addresses (private, loopback, link-local, shared, multicast, reserved,
// documentation) are counted as invalid too: the firewall must never
// reject the phone's own loopback services or its LAN because of a bad
// download.
func ParseIPv4(r io.Reader, add func(netip.Prefix)) (Counts, error) {
	var c Counts
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := sc.Text()
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var p netip.Prefix
		var err error
		if strings.Contains(line, "/") {
			p, err = netip.ParsePrefix(line)
		} else {
			var a netip.Addr
			a, err = netip.ParseAddr(line)
			if err == nil {
				p = netip.PrefixFrom(a, 32)
			}
		}
		if err != nil || !p.Addr().Is4() || p.Bits() != 32 || special(p) {
			c.Invalid++
			continue
		}
		c.Valid++
		add(p)
	}
	return c, sc.Err()
}

var specialNets = func() []netip.Prefix {
	var out []netip.Prefix
	for _, s := range []string{
		"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
		"169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
		"192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24",
		"203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
	} {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}()

func special(p netip.Prefix) bool {
	for _, n := range specialNets {
		if n.Overlaps(p) {
			return true
		}
	}
	return false
}
