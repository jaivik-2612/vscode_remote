package blocklist

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func mustList(t testing.TB, block, allow []string) *List {
	t.Helper()
	var buf bytes.Buffer
	if err := Write(&buf, Header{Version: "test-1", Comments: []string{"source x sha256=00"}}, block, allow); err != nil {
		t.Fatal(err)
	}
	l, err := Parse(buf.Bytes())
	if err != nil {
		t.Fatalf("Parse(Write(...)): %v\n%s", err, buf.String())
	}
	return l
}

func TestMatch(t *testing.T) {
	l := mustList(t,
		[]string{"doubleclick.net", "tracker.example.com", "ads.example.org", "stats.lineageos.org"},
		[]string{"ok.doubleclick.net"})
	cases := []struct {
		name    string
		blocked bool
		entry   string
	}{
		{"doubleclick.net", true, "doubleclick.net"},
		{"doubleclick.net.", true, "doubleclick.net"},    // trailing dot
		{"DoubleClick.NET", true, "doubleclick.net"},     // letter case
		{"a.b.doubleclick.net", true, "doubleclick.net"}, // subdomain
		{"notdoubleclick.net", false, ""},                // label boundary
		{"doubleclick.net.evil", false, ""},              // suffix, not parent
		{"net", false, ""},                               // parent of an entry
		{"ok.doubleclick.net", false, ""},                // exception
		{"x.ok.doubleclick.net", false, ""},              // below an exception
		{"tracker.example.com", true, "tracker.example.com"},
		{"example.com", false, ""},     // parent is not blocked
		{"www.example.com", false, ""}, // sibling
		{"stats.lineageos.org", true, "stats.lineageos.org"},
		{"download.lineageos.org", false, ""},
		{"", false, ""},
		{".", false, ""},
		{"a..doubleclick.net", true, "doubleclick.net"}, // odd, but still below
		{"bad\x00byte.example.org", false, ""},
	}
	for _, c := range cases {
		b, e := l.Match(c.name)
		if b != c.blocked || e != c.entry {
			t.Errorf("Match(%q) = %v, %q; want %v, %q", c.name, b, e, c.blocked, c.entry)
		}
	}
	var nilList *List
	if b, _ := nilList.Match("doubleclick.net"); b {
		t.Error("nil list blocks")
	}
	if nilList.Size() != 0 || nilList.Version() != "" {
		t.Error("nil list has a size or version")
	}
}

func TestCanonical(t *testing.T) {
	for in, want := range map[string]string{
		"Example.COM.": "example.com",
		"example.com":  "example.com",
		"":             "",
		".":            "",
		"\xffA.b":      "\xffa.b", // non-ASCII bytes are kept as they are
	} {
		if got := Canonical(in); got != want {
			t.Errorf("Canonical(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestValidDomain(t *testing.T) {
	good := []string{"a.b", "example.com", "x-y_z.example.co.uk", "123.example", "xn--bcher-kva.example",
		strings.Repeat("a", 63) + ".com"}
	bad := []string{"", "com", "Example.com", "a..b", ".a.b", "a.b.", "a b.c", "1.2.3.4", "a.123",
		strings.Repeat("a", 64) + ".com", strings.Repeat("a.", 127) + "com", "*.example.com", "ex!ample.com"}
	for _, s := range good {
		if !ValidDomain(s) {
			t.Errorf("ValidDomain(%q) = false", s)
		}
	}
	for _, s := range bad {
		if ValidDomain(s) {
			t.Errorf("ValidDomain(%q) = true", s)
		}
	}
}

func TestWriteIsDeterministicAndSorted(t *testing.T) {
	var a, b bytes.Buffer
	h := Header{Version: "v"}
	if err := Write(&a, h, []string{"c.example", "a.example", "b.example", "a.example"}, []string{"z.a.example"}); err != nil {
		t.Fatal(err)
	}
	if err := Write(&b, h, []string{"b.example", "a.example", "c.example"}, []string{"z.a.example", "z.a.example"}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(a.Bytes(), b.Bytes()) {
		t.Fatalf("same input, different output:\n%s\n%s", a.String(), b.String())
	}
	if !strings.HasSuffix(a.String(), "@@z.a.example\na.example\nb.example\nc.example\n") {
		t.Fatalf("unexpected body:\n%s", a.String())
	}
	if err := Write(&a, h, []string{"Not.Canonical"}, nil); err == nil {
		t.Error("Write accepted a non-canonical domain")
	}
	if err := Write(&a, Header{Version: "v", Comments: []string{"version: 2"}}, nil, nil); err == nil {
		t.Error("Write accepted a comment that repeats a header key")
	}
	if err := Write(&a, Header{Version: "a\nb"}, nil, nil); err == nil {
		t.Error("Write accepted a version with a newline")
	}
}

func TestParseRejectsDamage(t *testing.T) {
	var buf bytes.Buffer
	if err := Write(&buf, Header{Version: "v1"}, []string{"a.example", "b.example"}, []string{"ok.a.example"}); err != nil {
		t.Fatal(err)
	}
	good := buf.String()
	if _, err := Parse([]byte(good)); err != nil {
		t.Fatal(err)
	}
	// rehash recomputes the body hash, so that the checks behind it run.
	rehash := func(s string) string {
		var out bytes.Buffer
		l := strings.Split(s, "\n")
		var hdr, body []string
		for i, line := range l {
			if !strings.HasPrefix(line, "#") {
				body = l[i:]
				break
			}
			hdr = append(hdr, line)
		}
		b := strings.Join(body, "\n")
		for _, h := range hdr {
			if strings.HasPrefix(h, "# body-sha256:") {
				h = "# body-sha256: " + sha(b)
			}
			out.WriteString(h + "\n")
		}
		out.WriteString(b)
		return out.String()
	}
	cases := map[string]string{
		"no header":        "a.example\n",
		"truncated":        good[:len(good)-4],
		"edited body":      strings.Replace(good, "b.example", "c.example", 1),
		"wrong format":     strings.Replace(good, "# format: 1", "# format: 2", 1),
		"missing version":  strings.Replace(good, "# version: v1\n", "", 1),
		"duplicate key":    strings.Replace(good, "# version: v1\n", "# version: v1\n# version: v2\n", 1),
		"wrong count":      rehash(strings.Replace(good, "# entries: 2", "# entries: 3", 1)),
		"unsorted":         rehash(strings.Replace(good, "a.example\nb.example\n", "b.example\na.example\n", 1)),
		"duplicate":        rehash(strings.Replace(good, "a.example\nb.example\n", "a.example\na.example\n", 1)),
		"invalid entry":    rehash(strings.Replace(good, "b.example\n", "B.example\n", 1)),
		"blank line":       rehash(strings.Replace(good, "b.example\n", "\n", 1)),
		"comment in body":  rehash(strings.Replace(good, "b.example\n", "# b.example\n", 1)),
		"exception at end": rehash(strings.Replace(good, "@@ok.a.example\n", "", 1) + "@@ok.b.example\n"),
		"no final newline": rehash(strings.TrimSuffix(good, "\n")),
	}
	for name, data := range cases {
		if _, err := Parse([]byte(data)); err == nil {
			t.Errorf("%s: Parse accepted it", name)
		}
	}
}

func TestLoad(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "x.list")
	var buf bytes.Buffer
	Write(&buf, Header{Version: "20261011"}, []string{"a.example"}, nil)
	if err := os.WriteFile(p, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	l, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if l.Version() != "20261011" || l.Size() != 1 || l.Exceptions() != 0 || len(l.SHA256()) != 64 {
		t.Errorf("unexpected list %+v", l)
	}
	if _, err := Load(filepath.Join(dir, "missing")); err == nil {
		t.Error("Load of a missing file succeeded")
	}
}

func TestCovers(t *testing.T) {
	set := []string{"a.example", "local", "x.y.z"}
	for name, want := range map[string]bool{
		"a.example": true, "b.a.example": true, "example": false,
		"printer.local": true, "local": true, "localx": false, "q.x.y.z": true, "y.z": false,
	} {
		if got := Covers(set, name); got != want {
			t.Errorf("Covers(%q) = %v, want %v", name, got, want)
		}
	}
}

func BenchmarkMatch(b *testing.B) {
	var block []string
	for i := 0; i < 200000; i++ {
		block = append(block, "host"+strconv.Itoa(i)+".tracker"+strconv.Itoa(i%5000)+".example")
	}
	l := mustList(b, block, nil)
	names := []string{"a.b.c.host17.tracker17.example", "www.not-listed.example.org", "x.y.z.w.v.u.example.net"}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		l.Match(names[i%len(names)])
	}
}

func sha(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
