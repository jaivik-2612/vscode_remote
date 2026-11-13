// Package blocklist reads, writes and matches the compiled block list that
// antumbra-dnsfilter loads at start and on SIGHUP.
//
// The file is plain text, produced by listc (cmd/listc):
//
//	# antumbra-dnsfilter block list
//	# format: 1
//	# version: 20261011
//	# entries: 190123
//	# exceptions: 2
//	# body-sha256: <SHA-256 of every byte after the header, in hex>
//	# ...any other comment lines (sources, licences)...
//	@@exception.example.net
//	@@other.example.org
//	blocked.example
//	tracker.example.com
//
// The header is every line at the top that starts with '#'. The body is
// everything after it: first the exceptions (lines starting with "@@"),
// then the blocked domains, each group sorted in byte order without
// duplicates, one per line, each line ending in '\n'.
//
// A blocked domain blocks itself and every name below it. An exception
// comes from the allowlist: it unblocks itself and every name below it,
// whatever the block entries say.
package blocklist

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
)

// Format is the only file format version this package reads and writes.
const Format = 1

// MaxFileSize is the largest list file Load accepts. HaGeZi Multi Pro is
// about 4 MB; anything this large is not a list we made.
const MaxFileSize = 64 << 20

// List is a loaded block list. It is read-only after loading and safe for
// concurrent use. The nil *List blocks nothing.
type List struct {
	block   []string // sorted, unique, canonical
	allow   []string // sorted, unique, canonical
	version string
	sum     string // body SHA-256, hex
}

// Version returns the list's version string from its header.
func (l *List) Version() string {
	if l == nil {
		return ""
	}
	return l.version
}

// Size returns the number of blocked domains.
func (l *List) Size() int {
	if l == nil {
		return 0
	}
	return len(l.block)
}

// Exceptions returns the number of exception (allowlist) entries.
func (l *List) Exceptions() int {
	if l == nil {
		return 0
	}
	return len(l.allow)
}

// SHA256 returns the SHA-256 of the list body, in hex.
func (l *List) SHA256() string {
	if l == nil {
		return ""
	}
	return l.sum
}

// Match reports whether a DNS name is blocked, and if so the list entry
// that blocks it. The name may carry a trailing dot and any letter case.
// An exception on the name or any of its parents wins over every block
// entry.
func (l *List) Match(name string) (blocked bool, entry string) {
	if l == nil {
		return false, ""
	}
	name = Canonical(name)
	if name == "" {
		return false, ""
	}
	if len(l.allow) > 0 {
		for s := name; ; {
			if has(l.allow, s) {
				return false, ""
			}
			i := strings.IndexByte(s, '.')
			if i < 0 {
				break
			}
			s = s[i+1:]
		}
	}
	for s := name; ; {
		if has(l.block, s) {
			return true, s
		}
		i := strings.IndexByte(s, '.')
		if i < 0 {
			break
		}
		s = s[i+1:]
	}
	return false, ""
}

// Covers reports whether name equals one of the sorted, canonical domains
// in set or lies below one of them. Name must be canonical.
func Covers(set []string, name string) bool {
	for s := name; ; {
		if has(set, s) {
			return true
		}
		i := strings.IndexByte(s, '.')
		if i < 0 {
			return false
		}
		s = s[i+1:]
	}
}

func has(sorted []string, s string) bool {
	i := sort.SearchStrings(sorted, s)
	return i < len(sorted) && sorted[i] == s
}

// Canonical returns name in the form list entries use: ASCII letters in
// lower case and no trailing dot. Other bytes are kept as they are, so a
// name with unusual bytes simply matches nothing. It does not validate.
func Canonical(name string) string {
	name = strings.TrimSuffix(name, ".")
	for i := 0; i < len(name); i++ {
		if c := name[i]; 'A' <= c && c <= 'Z' {
			b := []byte(name)
			for j := i; j < len(b); j++ {
				if 'A' <= b[j] && b[j] <= 'Z' {
					b[j] += 'a' - 'A'
				}
			}
			return string(b)
		}
	}
	return name
}

// ValidDomain reports whether s is a canonical domain that may appear in a
// list: 2 to 127 labels of 1 to 63 bytes from [a-z0-9_-], at most 253
// bytes in all, and a last label that is not all digits (so that IPv4
// addresses are not taken for names).
func ValidDomain(s string) bool {
	if len(s) == 0 || len(s) > 253 {
		return false
	}
	labels, start := 0, 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == '.' {
			n := i - start
			if n == 0 || n > 63 {
				return false
			}
			labels++
			start = i + 1
			continue
		}
		c := s[i]
		if !('a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	if labels < 2 {
		return false
	}
	last := s[strings.LastIndexByte(s, '.')+1:]
	for i := 0; i < len(last); i++ {
		if last[i] < '0' || last[i] > '9' {
			return true
		}
	}
	return false
}

// Load reads and verifies a list file.
func Load(path string) (*List, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, MaxFileSize+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxFileSize {
		return nil, fmt.Errorf("%s: larger than %d bytes", path, MaxFileSize)
	}
	l, err := Parse(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return l, nil
}

// Parse verifies and loads a list from its file contents. It checks the
// format version, the body hash and the entry counts in the header, and
// that every entry is valid, sorted and unique.
func Parse(data []byte) (*List, error) {
	hdr, body, err := splitHeader(data)
	if err != nil {
		return nil, err
	}
	if hdr["format"] != strconv.Itoa(Format) {
		return nil, fmt.Errorf("unsupported or missing format %q (want %d)", hdr["format"], Format)
	}
	version := hdr["version"]
	if version == "" {
		return nil, errors.New("missing version")
	}
	want, ok := hdr["body-sha256"]
	if !ok || len(want) != 64 {
		return nil, errors.New("missing or malformed body-sha256")
	}
	sum := sha256.Sum256(body)
	got := hex.EncodeToString(sum[:])
	if got != want {
		return nil, errors.New("body-sha256 does not match: the file is damaged or was edited")
	}
	nBlock, err1 := strconv.Atoi(hdr["entries"])
	nAllow, err2 := strconv.Atoi(hdr["exceptions"])
	if err1 != nil || err2 != nil || nBlock < 0 || nAllow < 0 {
		return nil, errors.New("missing or malformed entries/exceptions count")
	}
	if len(body) > 0 && body[len(body)-1] != '\n' {
		return nil, errors.New("last line has no newline")
	}

	// One string holds the whole body; entries are slices of it, so the
	// list costs the file size plus one string header per entry.
	text := string(body)
	l := &List{
		block:   make([]string, 0, nBlock),
		allow:   make([]string, 0, nAllow),
		version: version,
		sum:     got,
	}
	for line := 1; len(text) > 0; line++ {
		i := strings.IndexByte(text, '\n')
		e := text[:i]
		text = text[i+1:]
		allow := strings.HasPrefix(e, "@@")
		if allow {
			e = e[2:]
		}
		if !ValidDomain(e) {
			return nil, fmt.Errorf("body line %d: not a valid domain", line)
		}
		switch {
		case allow && len(l.block) > 0:
			return nil, fmt.Errorf("body line %d: exception after the block entries", line)
		case allow:
			if n := len(l.allow); n > 0 && l.allow[n-1] >= e {
				return nil, fmt.Errorf("body line %d: exceptions not sorted or not unique", line)
			}
			l.allow = append(l.allow, e)
		default:
			if n := len(l.block); n > 0 && l.block[n-1] >= e {
				return nil, fmt.Errorf("body line %d: entries not sorted or not unique", line)
			}
			l.block = append(l.block, e)
		}
	}
	if len(l.block) != nBlock || len(l.allow) != nAllow {
		return nil, fmt.Errorf("header counts %d entries and %d exceptions, body has %d and %d",
			nBlock, nAllow, len(l.block), len(l.allow))
	}
	return l, nil
}

// splitHeader returns the "# key: value" pairs of the header and the body.
func splitHeader(data []byte) (map[string]string, []byte, error) {
	hdr := map[string]string{}
	rest := data
	for len(rest) > 0 && rest[0] == '#' {
		i := bytes.IndexByte(rest, '\n')
		if i < 0 {
			return nil, nil, errors.New("header line has no newline")
		}
		line := string(rest[1:i])
		rest = rest[i+1:]
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		if !reservedKey(k) {
			continue // sources, licences and other notes
		}
		if _, dup := hdr[k]; dup {
			return nil, nil, fmt.Errorf("header key %q appears twice", k)
		}
		hdr[k] = strings.TrimSpace(v)
	}
	if len(hdr) == 0 {
		return nil, nil, errors.New("no header: not an antumbra-dnsfilter list")
	}
	return hdr, rest, nil
}

// reservedKey reports whether k is one of the header fields that Parse
// reads. Each may appear only once.
func reservedKey(k string) bool {
	switch k {
	case "format", "version", "entries", "exceptions", "body-sha256":
		return true
	}
	return false
}

// Header holds what Write puts at the top of a list file besides the
// fields it computes itself.
type Header struct {
	Version string
	// Comments are written as "# <comment>" lines after the fixed fields.
	// They must not contain newlines, and a comment of the form "key: value"
	// must not repeat a key already in the header.
	Comments []string
}

// Write writes a list file. The block and allow slices must hold
// canonical, valid domains; Write sorts and deduplicates copies of them.
// The output depends only on its inputs, so the same inputs give the same
// bytes.
func Write(w io.Writer, h Header, block, allow []string) error {
	if h.Version == "" || strings.ContainsAny(h.Version, "\r\n") {
		return errors.New("blocklist: version must be one non-empty line")
	}
	block, err := sortedUnique(block)
	if err != nil {
		return err
	}
	allow, err = sortedUnique(allow)
	if err != nil {
		return err
	}
	var body bytes.Buffer
	for _, a := range allow {
		body.WriteString("@@")
		body.WriteString(a)
		body.WriteByte('\n')
	}
	for _, b := range block {
		body.WriteString(b)
		body.WriteByte('\n')
	}
	sum := sha256.Sum256(body.Bytes())

	var out bytes.Buffer
	fmt.Fprintf(&out, "# antumbra-dnsfilter block list\n")
	fmt.Fprintf(&out, "# format: %d\n", Format)
	fmt.Fprintf(&out, "# version: %s\n", h.Version)
	fmt.Fprintf(&out, "# entries: %d\n", len(block))
	fmt.Fprintf(&out, "# exceptions: %d\n", len(allow))
	fmt.Fprintf(&out, "# body-sha256: %s\n", hex.EncodeToString(sum[:]))
	for _, c := range h.Comments {
		if strings.ContainsAny(c, "\r\n") {
			return errors.New("blocklist: comment contains a newline")
		}
		if k, _, ok := strings.Cut(c, ":"); ok && reservedKey(strings.TrimSpace(k)) {
			return fmt.Errorf("blocklist: comment uses the reserved header key %q", k)
		}
		out.WriteString("# ")
		out.WriteString(c)
		out.WriteByte('\n')
	}
	if _, err := out.WriteTo(w); err != nil {
		return err
	}
	_, err = body.WriteTo(w)
	return err
}

func sortedUnique(in []string) ([]string, error) {
	out := append([]string(nil), in...)
	sort.Strings(out)
	j := 0
	for i, s := range out {
		if !ValidDomain(s) {
			return nil, fmt.Errorf("blocklist: %q is not a valid canonical domain", s)
		}
		if i > 0 && s == out[j-1] {
			continue
		}
		out[j] = s
		j++
	}
	return out[:j], nil
}
