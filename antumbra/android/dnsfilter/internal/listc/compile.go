package listc

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/netip"
	"os"
	"sort"
	"strings"

	"antumbra/dnsfilter/internal/blocklist"
)

// maxSourceSize is the largest source file accepted (HaGeZi Multi Pro is
// about 4 MB).
const maxSourceSize = 64 << 20

// MaxIPv4Entries is the most addresses the DoH address list may hold.
// antumbra-fw makes one rule of each, checked for every new connection of
// every app, and a list that suddenly grows this much is more likely
// broken than right (1,434 addresses on 2026-10-11). More stops the build,
// as too few does.
const MaxIPv4Entries = 4096

// SourceReport describes what one source contributed.
type SourceReport struct {
	Source
	SHA256   string
	Counts   Counts
	Excluded int // valid entries dropped by "exclude"
}

// Report describes a compilation.
type Report struct {
	Sources    []SourceReport
	Merged     int // distinct blocked domains from all sources
	Allowed    int // of those, removed because an allow entry covers them
	Redundant  int // of those, removed because a parent domain is listed
	Entries    int // blocked domains in the output
	Exceptions int // allow entries kept in the output
}

func (r *Report) String() string {
	var b strings.Builder
	for _, s := range r.Sources {
		fmt.Fprintf(&b, "%-14s %-7s valid=%d invalid=%d excluded=%d sha256=%s\n",
			s.Name, s.Format, s.Counts.Valid, s.Counts.Invalid, s.Excluded, s.SHA256)
	}
	if r.Merged > 0 {
		fmt.Fprintf(&b, "merged=%d allowed=%d redundant=%d entries=%d exceptions=%d\n",
			r.Merged, r.Allowed, r.Redundant, r.Entries, r.Exceptions)
	} else {
		fmt.Fprintf(&b, "entries=%d\n", r.Entries)
	}
	return b.String()
}

// readSource reads a whole source file and returns its bytes and SHA-256.
func readSource(path string) ([]byte, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, "", err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxSourceSize+1))
	if err != nil {
		return nil, "", err
	}
	if len(data) > maxSourceSize {
		return nil, "", fmt.Errorf("%s: larger than %d bytes", path, maxSourceSize)
	}
	sum := sha256.Sum256(data)
	return data, hex.EncodeToString(sum[:]), nil
}

// readDomainFile reads one of Antumbra's own domain files (allow and
// exclude lists). Every entry must be valid.
func readDomainFile(path string) ([]string, string, error) {
	data, sum, err := readSource(path)
	if err != nil {
		return nil, "", err
	}
	var out []string
	c, err := ParseDomains(bytes.NewReader(data), func(d string) { out = append(out, d) })
	if err != nil {
		return nil, "", fmt.Errorf("%s: %w", path, err)
	}
	if c.Invalid > 0 {
		return nil, "", fmt.Errorf("%s: %d invalid entries", path, c.Invalid)
	}
	return out, sum, nil
}

// Compile builds the block list described by cfg, reading downloaded
// sources from the downloads directory, and returns the list file.
func Compile(cfg *Config, downloads, version string) ([]byte, *Report, error) {
	rep := &Report{}
	merged := map[string]struct{}{}
	var comments []string

	for _, s := range cfg.Block {
		exclude := map[string]bool{}
		for _, path := range cfg.Exclude[s.Name] {
			ds, _, err := readDomainFile(path)
			if err != nil {
				return nil, nil, err
			}
			for _, d := range ds {
				exclude[d] = true
			}
		}
		path := cfg.Path(s, downloads)
		data, sum, err := readSource(path)
		if err != nil {
			return nil, nil, fmt.Errorf("source %s: %w", s.Name, err)
		}
		sr := SourceReport{Source: s, SHA256: sum}
		add := func(d string) {
			if exclude[d] {
				sr.Excluded++
				return
			}
			merged[d] = struct{}{}
		}
		switch s.Format {
		case "domains":
			sr.Counts, err = ParseDomains(bytes.NewReader(data), add)
		case "etip":
			sr.Counts, err = ParseETIP(bytes.NewReader(data), add)
		default:
			err = fmt.Errorf("unknown format %q", s.Format)
		}
		if err != nil {
			return nil, nil, fmt.Errorf("source %s: %w", s.Name, err)
		}
		if usable := sr.Counts.Valid - sr.Excluded; usable < s.Min {
			return nil, nil, fmt.Errorf("source %s: only %d usable entries, at least %d expected (broken download?)",
				s.Name, usable, s.Min)
		}
		rep.Sources = append(rep.Sources, sr)
		comments = append(comments, sourceComment(sr, cfg.Licence[s.Name]))
	}

	var allow []string
	for _, path := range cfg.Allow {
		ds, sum, err := readDomainFile(path)
		if err != nil {
			return nil, nil, err
		}
		allow = append(allow, ds...)
		comments = append(comments, fmt.Sprintf("allowlist %s entries=%d sha256=%s",
			baseName(path), len(ds), sum))
	}

	block, keptAllow := Reduce(merged, allow, rep)
	rep.Entries, rep.Exceptions = len(block), len(keptAllow)

	var out bytes.Buffer
	h := blocklist.Header{Version: version, Comments: comments}
	if err := blocklist.Write(&out, h, block, keptAllow); err != nil {
		return nil, nil, err
	}
	l, err := blocklist.Parse(out.Bytes())
	if err != nil {
		return nil, nil, fmt.Errorf("the written list does not load: %w", err)
	}
	var hit []string
	for _, g := range cfg.Guard {
		if blocked, _ := l.Match(g); blocked {
			hit = append(hit, g)
		}
	}
	if len(hit) > 0 {
		return nil, nil, fmt.Errorf("guarded domains would be blocked: %s (add an allow or exclude entry, or check the source)",
			strings.Join(hit, ", "))
	}
	return out.Bytes(), rep, nil
}

// baseName returns the last element of a path, for header comments that
// must not depend on where the build ran.
func baseName(p string) string {
	if i := strings.LastIndexByte(p, '/'); i >= 0 {
		return p[i+1:]
	}
	return p
}

func sourceComment(s SourceReport, licence string) string {
	where := s.Where
	if !s.Remote() {
		where = baseName(where)
	}
	c := fmt.Sprintf("source %s format=%s valid=%d invalid=%d excluded=%d sha256=%s from=%s",
		s.Name, s.Format, s.Counts.Valid, s.Counts.Invalid, s.Excluded, s.SHA256, where)
	if licence != "" {
		c += " licence=" + strings.ReplaceAll(licence, " ", "_")
	}
	return c
}

// Reduce turns the merged block set and the allow entries into the
// smallest list with the same effect:
//
//   - a blocked domain equal to or below an allow entry is removed (the
//     allowlist always wins);
//   - a blocked domain below another blocked domain is removed (the parent
//     already blocks it);
//   - an allow entry is kept only if some remaining blocked domain is
//     above it, since otherwise nothing would block it anyway; an allow
//     entry below another kept allow entry is removed.
//
// Both results are sorted. rep, if not nil, gets the counts.
func Reduce(merged map[string]struct{}, allowIn []string, rep *Report) (block, allow []string) {
	allowSet := sortedSet(allowIn)
	all := make([]string, 0, len(merged))
	for d := range merged {
		all = append(all, d)
	}
	sort.Strings(all)
	var allowed, redundant int
	for _, d := range all {
		if blocklist.Covers(allowSet, d) {
			allowed++
			continue
		}
		if hasParent(merged, d) {
			// The parent is kept unless an allow entry covers it, and then
			// the same allow entry covers d, which was handled above.
			redundant++
			continue
		}
		block = append(block, d)
	}
	for _, a := range allowSet {
		if !parentIn(block, a) {
			continue
		}
		if parentIn(allowSet, a) {
			continue
		}
		allow = append(allow, a)
	}
	if rep != nil {
		rep.Merged, rep.Allowed, rep.Redundant = len(all), allowed, redundant
	}
	return block, allow
}

func sortedSet(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	j := 0
	for i, s := range out {
		if i > 0 && s == out[j-1] {
			continue
		}
		out[j] = s
		j++
	}
	return out[:j]
}

// hasParent reports whether a proper parent of d (with two labels or more)
// is in set.
func hasParent(set map[string]struct{}, d string) bool {
	for s := d; ; {
		i := strings.IndexByte(s, '.')
		if i < 0 {
			return false
		}
		s = s[i+1:]
		if !strings.Contains(s, ".") {
			return false
		}
		if _, ok := set[s]; ok {
			return true
		}
	}
}

// parentIn reports whether a proper parent of d is in the sorted slice.
func parentIn(sorted []string, d string) bool {
	i := strings.IndexByte(d, '.')
	if i < 0 {
		return false
	}
	return blocklist.Covers(sorted, d[i+1:])
}

// CompileIPv4 builds the DoH server address list for the firewall from the
// "ipv4" sources: one address per line, sorted, without duplicates, after
// a few '#' comment lines; at most MaxIPv4Entries. antumbra-fw reads it as
// lists/doh-ipv4.txt.
func CompileIPv4(cfg *Config, downloads, version string) ([]byte, *Report, error) {
	rep := &Report{}
	set := map[netip.Prefix]struct{}{}
	var comments []string
	for _, s := range cfg.IPv4 {
		data, sum, err := readSource(cfg.Path(s, downloads))
		if err != nil {
			return nil, nil, fmt.Errorf("source %s: %w", s.Name, err)
		}
		sr := SourceReport{Source: s, SHA256: sum}
		sr.Counts, err = ParseIPv4(bytes.NewReader(data), func(p netip.Prefix) { set[p] = struct{}{} })
		if err != nil {
			return nil, nil, fmt.Errorf("source %s: %w", s.Name, err)
		}
		if sr.Counts.Valid < s.Min {
			return nil, nil, fmt.Errorf("source %s: only %d usable entries, at least %d expected (broken download?)",
				s.Name, sr.Counts.Valid, s.Min)
		}
		rep.Sources = append(rep.Sources, sr)
		comments = append(comments, sourceComment(sr, cfg.Licence[s.Name]))
	}
	if len(set) > MaxIPv4Entries {
		return nil, nil, fmt.Errorf("%d DoH server addresses, at most %d expected (broken source?)",
			len(set), MaxIPv4Entries)
	}
	ps := make([]netip.Prefix, 0, len(set))
	for p := range set {
		ps = append(ps, p)
	}
	sort.Slice(ps, func(i, j int) bool {
		if c := ps[i].Addr().Compare(ps[j].Addr()); c != 0 {
			return c < 0
		}
		return ps[i].Bits() < ps[j].Bits()
	})
	var out bytes.Buffer
	fmt.Fprintf(&out, "# antumbra DNS-over-HTTPS server addresses (IPv4), for antumbra-fw\n")
	fmt.Fprintf(&out, "# version: %s\n", version)
	fmt.Fprintf(&out, "# entries: %d\n", len(ps))
	for _, c := range comments {
		fmt.Fprintf(&out, "# %s\n", c)
	}
	for _, p := range ps {
		if p.Bits() == 32 {
			fmt.Fprintf(&out, "%s\n", p.Addr())
		} else {
			fmt.Fprintf(&out, "%s\n", p)
		}
	}
	rep.Entries = len(ps)
	return out.Bytes(), rep, nil
}
