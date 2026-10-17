package listc

import (
	"bytes"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"

	"antumbra/dnsfilter/internal/blocklist"
)

func collect(t *testing.T, parse func(add func(string)) (Counts, error)) ([]string, Counts) {
	t.Helper()
	var out []string
	c, err := parse(func(d string) { out = append(out, d) })
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(out)
	return out, c
}

func TestParseDomains(t *testing.T) {
	in := "\uFEFF# Title: test list\n" +
		"! adblock comment\n" +
		"[Adblock Plus 2.0]\n" +
		"Plain.Example.com\n" +
		"plain.example.com.   # trailing dot and comment\n" +
		"*.wild.example.org\n" +
		"||adblock.example.net^\n" +
		"||options.example.net^$third-party\n" +
		"0.0.0.0 hosts1.example hosts2.example\n" +
		"127.0.0.1 localhost\n" +
		"::1 ip6-localhost ip6-loopback\n" +
		"0.0.0.0 0.0.0.0\n" +
		"notanip hosts3.example\n" +
		"1.2.3.4\n" +
		"com\n" +
		"bad_char!.example\n" +
		"\n   \n"
	got, c := collect(t, func(add func(string)) (Counts, error) { return ParseDomains(strings.NewReader(in), add) })
	want := []string{"adblock.example.net", "hosts1.example", "hosts2.example",
		"plain.example.com", "plain.example.com", "wild.example.org"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q\nwant %q", got, want)
	}
	// options rule, "notanip" line, bare address, single label, bad character.
	if c.Valid != 6 || c.Invalid != 5 {
		t.Errorf("counts %+v, want 6 valid and 5 invalid", c)
	}
}

func TestParseETIP(t *testing.T) {
	list := `{"trackers": [
	  {"name": "A", "network_signature": "adjust\\.com|adj\\.st|go\\.link"},
	  {"name": "B", "network_signature": ""},
	  {"name": "C", "network_signature": "\\.facebook\\.com"},
	  {"name": "D", "network_signature": "^api\\.Segment\\.io$|.*\\.exacttarget\\.|mt[0-9]*\\.google\\.cn|54\\.243\\.73\\.253:8080/x/|data.\\altbeacon\\.org|fidzup|usw\\-lax\\.adsrvr\\.org"}
	]}`
	byID := `{"trackers": {"1": {"id": 1, "network_signature": "adjust\\.com"}, "2": {"network_signature": "x\\.example\\.org"}}}`

	got, c := collect(t, func(add func(string)) (Counts, error) { return ParseETIP(strings.NewReader(list), add) })
	want := []string{"adj.st", "adjust.com", "api.segment.io", "facebook.com", "go.link", "usw-lax.adsrvr.org"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q\nwant %q", got, want)
	}
	if c.Valid != 6 || c.Invalid != 5 {
		t.Errorf("counts %+v, want 6 valid and 5 invalid", c)
	}

	got, _ = collect(t, func(add func(string)) (Counts, error) { return ParseETIP(strings.NewReader(byID), add) })
	if !reflect.DeepEqual(got, []string{"adjust.com", "x.example.org"}) {
		t.Errorf("object form: got %q", got)
	}
	for _, bad := range []string{`{}`, `{"trackers": 3}`, `not json`, `{"trackers": [1]}`} {
		if _, err := ParseETIP(strings.NewReader(bad), func(string) {}); err == nil {
			t.Errorf("ParseETIP(%s) accepted it", bad)
		}
	}
}

func TestParseIPv4(t *testing.T) {
	in := "# DoH servers\n1.1.1.1\n8.8.8.8 # comment\n9.9.9.9/32\n9.9.9.0/24\n9.9.9.9/24\n9.9.9.8/31\n" +
		"10.0.0.1\n127.0.0.1\n192.168.1.1\n169.254.1.1\n100.64.0.1\n224.0.0.1\n0.0.0.0\n" +
		"2606:4700::1111\n300.1.1.1\n1.0.0.0/4\n0.0.0.0/0\n"
	var got []string
	c, err := ParseIPv4(strings.NewReader(in), func(p netip.Prefix) { got = append(got, p.String()) })
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"1.1.1.1/32", "8.8.8.8/32", "9.9.9.9/32"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %q, want %q", got, want)
	}
	// Three prefixes wider than /32, 7 special, IPv6, 300.x, /4, /0.
	if c.Valid != 3 || c.Invalid != 14 {
		t.Errorf("counts %+v, want 3 valid and 14 invalid", c)
	}
}

func set(ds ...string) map[string]struct{} {
	m := map[string]struct{}{}
	for _, d := range ds {
		m[d] = struct{}{}
	}
	return m
}

func TestReduce(t *testing.T) {
	merged := set(
		"doubleclick.net", "ad.doubleclick.net", "x.ad.doubleclick.net", // children of a blocked parent
		"example.com",             // blocked, with an exception below
		"tracker.cdn.example.com", // below that exception: removed
		"stats.lineageos.org",     // blocked; allow entry above it wins
		"exact.example.org",       // equal to an allow entry: removed
		"keep.example.net",
	)
	allow := []string{
		"cdn.example.com", "img.cdn.example.com", // second is below the first: dropped
		"lineageos.org",     // above a blocked domain: removes it, then has no effect
		"exact.example.org", // equal: removes the block entry, then has no effect
		"unrelated.example", // nothing above it is blocked: dropped
	}
	var rep Report
	block, keep := Reduce(merged, allow, &rep)
	if want := []string{"doubleclick.net", "example.com", "keep.example.net"}; !reflect.DeepEqual(block, want) {
		t.Errorf("block = %q, want %q", block, want)
	}
	if want := []string{"cdn.example.com"}; !reflect.DeepEqual(keep, want) {
		t.Errorf("allow = %q, want %q", keep, want)
	}
	if rep.Merged != 8 || rep.Allowed != 3 || rep.Redundant != 2 {
		t.Errorf("report %+v", rep)
	}

	// The reduced list must decide every name as the full sets would.
	var buf bytes.Buffer
	if err := blocklist.Write(&buf, blocklist.Header{Version: "t"}, block, keep); err != nil {
		t.Fatal(err)
	}
	l, err := blocklist.Parse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	full := func(name string) bool {
		as := sortedSet(allow)
		if blocklist.Covers(as, name) {
			return false
		}
		var all []string
		for d := range merged {
			all = append(all, d)
		}
		sort.Strings(all)
		return blocklist.Covers(all, name)
	}
	names := []string{"doubleclick.net", "q.x.ad.doubleclick.net", "example.com", "www.example.com",
		"cdn.example.com", "a.tracker.cdn.example.com", "img.cdn.example.com", "stats.lineageos.org",
		"lineageos.org", "exact.example.org", "a.exact.example.org", "keep.example.net", "unrelated.example",
		"other.example.org"}
	for _, n := range names {
		if got, _ := l.Match(n); got != full(n) {
			t.Errorf("%s: reduced list says blocked=%v, full sets say %v", n, got, full(n))
		}
	}
}

// writeTree writes files under a temporary directory and returns it.
func writeTree(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, content := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

const testConfig = `# test sources
block   pro      domains 3  https://lists.example/pro.txt
block   exodus   etip    2  https://lists.example/trackers.json
block   own      domains 1  own.txt
ipv4    doh-ips  2          https://lists.example/doh.txt
exclude exodus   exodus-exclude.txt
allow   allow.txt
guard   google.com wikipedia.org
licence pro      GPL-3.0
`

func testTree(t *testing.T) (dir, downloads string) {
	dir = writeTree(t, map[string]string{
		"lists/sources.conf":       testConfig,
		"lists/own.txt":            "# ours\nstats.lineageos.org\nizatcloud.net\n",
		"lists/exodus-exclude.txt": "google.com\n",
		"lists/allow.txt":          "good.doubleclick.net\n",
		"dl/pro":                   "# Title: pro\nads.example.com\ndoubleclick.net\nad.doubleclick.net\ntracker.example.org\n",
		"dl/exodus":                `{"trackers": {"1": {"network_signature": "\\.google\\.com|app-measurement\\.com"}, "2": {"network_signature": "adjust\\.com"}}}`,
		"dl/doh-ips":               "1.1.1.1\n8.8.8.8\n8.8.4.4\n127.0.0.1\n",
	})
	return dir, filepath.Join(dir, "dl")
}

func loadConfig(t *testing.T, dir string) *Config {
	t.Helper()
	f, err := os.Open(filepath.Join(dir, "lists/sources.conf"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	cfg, err := ParseConfig(f, filepath.Join(dir, "lists"))
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}

func TestCompile(t *testing.T) {
	dir, dl := testTree(t)
	cfg := loadConfig(t, dir)
	out, rep, err := Compile(cfg, dl, "20261011")
	if err != nil {
		t.Fatal(err)
	}
	l, err := blocklist.Parse(out)
	if err != nil {
		t.Fatal(err)
	}
	if l.Version() != "20261011" {
		t.Errorf("version %q", l.Version())
	}
	blocked := []string{"ads.example.com", "x.doubleclick.net", "tracker.example.org", "app-measurement.com",
		"adjust.com", "stats.lineageos.org", "xtrapath1.izatcloud.net"}
	open := []string{"google.com", "www.google.com", "good.doubleclick.net", "lineageos.org", "example.com"}
	for _, n := range blocked {
		if b, _ := l.Match(n); !b {
			t.Errorf("%s is not blocked", n)
		}
	}
	for _, n := range open {
		if b, _ := l.Match(n); b {
			t.Errorf("%s is blocked", n)
		}
	}
	if l.Exceptions() != 1 {
		t.Errorf("exceptions = %d, want 1", l.Exceptions())
	}
	if rep.Sources[1].Excluded != 1 {
		t.Errorf("exodus excluded = %d, want 1", rep.Sources[1].Excluded)
	}
	text := string(out)
	for _, s := range []string{"# source pro format=domains", "from=https://lists.example/pro.txt",
		"licence=GPL-3.0", "# source own format=domains", "from=own.txt", "# allowlist allow.txt entries=1"} {
		if !strings.Contains(text, s) {
			t.Errorf("header lacks %q:\n%s", s, text)
		}
	}
	if strings.Contains(text, dir) {
		t.Error("the output names the build directory")
	}

	// Same inputs, same bytes.
	again, _, err := Compile(cfg, dl, "20261011")
	if err != nil || !bytes.Equal(out, again) {
		t.Error("compiling twice gave different output")
	}

	doh, _, err := CompileIPv4(cfg, dl, "20261011")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(string(doh), "\n1.1.1.1\n8.8.4.4\n8.8.8.8\n") {
		t.Errorf("doh list:\n%s", doh)
	}
}

func TestCompileFailures(t *testing.T) {
	t.Run("guard", func(t *testing.T) {
		dir, dl := testTree(t)
		os.WriteFile(filepath.Join(dir, "lists/exodus-exclude.txt"), nil, 0o644)
		_, _, err := Compile(loadConfig(t, dir), dl, "v")
		if err == nil || !strings.Contains(err.Error(), "google.com") {
			t.Errorf("err = %v, want a guard failure naming google.com", err)
		}
	})
	t.Run("too few entries", func(t *testing.T) {
		dir, dl := testTree(t)
		os.WriteFile(filepath.Join(dl, "pro"), []byte("<html>rate limited</html>\n"), 0o644)
		_, _, err := Compile(loadConfig(t, dir), dl, "v")
		if err == nil || !strings.Contains(err.Error(), "broken download") {
			t.Errorf("err = %v, want a minimum-entries failure", err)
		}
	})
	t.Run("missing download", func(t *testing.T) {
		dir, dl := testTree(t)
		os.Remove(filepath.Join(dl, "exodus"))
		if _, _, err := Compile(loadConfig(t, dir), dl, "v"); err == nil {
			t.Error("compiled without a source")
		}
	})
	t.Run("invalid allow entry", func(t *testing.T) {
		dir, dl := testTree(t)
		os.WriteFile(filepath.Join(dir, "lists/allow.txt"), []byte("not a domain!\n"), 0o644)
		if _, _, err := Compile(loadConfig(t, dir), dl, "v"); err == nil {
			t.Error("accepted an invalid allow entry")
		}
	})
	t.Run("doh too many", func(t *testing.T) {
		dir, dl := testTree(t)
		var b strings.Builder
		for i := 0; i <= MaxIPv4Entries; i++ {
			fmt.Fprintf(&b, "45.%d.%d.%d\n", i>>16, (i>>8)&255, i&255)
		}
		os.WriteFile(filepath.Join(dl, "doh-ips"), []byte(b.String()), 0o644)
		if _, _, err := CompileIPv4(loadConfig(t, dir), dl, "v"); err == nil || !strings.Contains(err.Error(), "at most") {
			t.Errorf("err = %v, want a maximum-entries failure", err)
		}
	})
	t.Run("doh too few", func(t *testing.T) {
		dir, dl := testTree(t)
		os.WriteFile(filepath.Join(dl, "doh-ips"), []byte("10.0.0.1\n"), 0o644)
		if _, _, err := CompileIPv4(loadConfig(t, dir), dl, "v"); err == nil {
			t.Error("accepted a DoH list with too few usable entries")
		}
	})
}

func TestParseConfigErrors(t *testing.T) {
	for _, bad := range []string{
		"block pro domains 3",                                  // missing WHERE
		"block pro rpz 3 x.txt",                                // unknown format
		"block pro domains many x.txt",                         // bad MIN
		"block ../pro domains 3 x.txt",                         // bad name
		"block pro domains 3 x.txt\nblock pro domains 3 y.txt", // name twice
		"block pro domains 3 http://insecure.example/x",        // not https
		"exclude nosuch x.txt",                                 // unknown source
		"licence nosuch GPL",                                   // unknown source
		"guard not_a_domain!",                                  // bad guard
		"frobnicate x",                                         // unknown record
	} {
		if _, err := ParseConfig(strings.NewReader(bad), "."); err == nil {
			t.Errorf("ParseConfig accepted %q", bad)
		}
	}
}

// TestShippedSources checks that the real sources file parses and that
// Antumbra's own lists are valid.
func TestShippedSources(t *testing.T) {
	dir := filepath.Join("..", "..", "lists")
	f, err := os.Open(filepath.Join(dir, "sources.conf"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	cfg, err := ParseConfig(f, dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, s := range cfg.Block {
		if !s.Remote() {
			if _, _, err := readDomainFile(cfg.Path(s, "")); err != nil {
				t.Error(err)
			}
		}
	}
	for _, files := range cfg.Exclude {
		for _, p := range files {
			if _, _, err := readDomainFile(p); err != nil {
				t.Error(err)
			}
		}
	}
	for _, p := range cfg.Allow {
		if _, _, err := readDomainFile(p); err != nil {
			t.Error(err)
		}
	}
	if len(cfg.Guard) == 0 {
		t.Error("no guard entries")
	}
	// The Exodus exclusions stay valid while the source is off (see
	// sources.conf), so that turning it back on is one edit.
	if _, _, err := readDomainFile(filepath.Join(dir, "exodus-exclude.txt")); err != nil {
		t.Error(err)
	}
	// The emulator's tracker test asks for these; they must stay blocked
	// whatever the remote lists do.
	own, _, err := readDomainFile(filepath.Join(dir, "antumbra-extra.txt"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"doubleclick.net", "stats.lineageos.org"} {
		if !blocklist.Covers(sortedSet(own), want) {
			t.Errorf("antumbra-extra.txt does not block %s", want)
		}
	}
}
