package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
	"antumbra/dnsfilter/internal/fakedns"
)

func TestFlagDefaultsMatchTheContract(t *testing.T) {
	o, err := parseFlags(nil)
	if err != nil {
		t.Fatal(err)
	}
	if o.listen != "127.0.0.1:5335" || o.statusListen != "127.0.0.1:5380" || o.upstream != "127.0.0.1:9053" ||
		o.upstreamUID != 2950 || o.upstreamNet != "udp" || o.blockedAnswer != "nxdomain" || o.aaaa != "empty" ||
		o.moduleStatus != "/data/adb/antumbra/run/status.json" || o.debugQueries || o.allowPrivileged ||
		o.statusRefresh != time.Minute ||
		len(o.lists.paths) != 1 || o.lists.paths[0] != "/data/adb/antumbra/lists/dnsfilter.list" {
		t.Errorf("defaults %+v", o)
	}
	o, err = parseFlags([]string{"-list", "a", "-list", "b"})
	if err != nil || strings.Join(o.lists.paths, ",") != "a,b" {
		t.Errorf("-list a -list b: %v %v", o.lists.paths, err)
	}
	if _, err := parseFlags([]string{"stray"}); err == nil {
		t.Error("accepted a stray argument")
	}
}

func TestRefusesRoot(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("not running as root")
	}
	if _, bad := privileged(); !bad {
		t.Fatal("root not reported as privileged")
	}
	o, _ := parseFlags([]string{"-list", "/nonexistent"})
	if err := run(o, nil); err == nil || !strings.Contains(err.Error(), "refusing to run") {
		t.Errorf("run as root: %v", err)
	}
}

func TestFailsClosedWithoutList(t *testing.T) {
	o, _ := parseFlags([]string{"-insecure-allow-privileged", "-list", "/nonexistent/a.list", "-list", "/nonexistent/b.list",
		"-listen", "127.0.0.1:0", "-status-listen", ""})
	err := run(o, nil)
	if err == nil || !strings.Contains(err.Error(), "no block list loaded") {
		t.Errorf("run without a list: %v, want a refusal", err)
	}
}

func TestSelfTest(t *testing.T) {
	if code := selfTest(nil, false); code != 0 {
		t.Errorf("self-test exit code %d", code)
	}
}

func writeList(t *testing.T, path, version string, block ...string) {
	t.Helper()
	var buf bytes.Buffer
	if err := blocklist.Write(&buf, blocklist.Header{Version: version}, block, nil); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func getStatus(t *testing.T, addr net.Addr) map[string]any {
	t.Helper()
	res, err := http.Get("http://" + addr.String() + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		t.Fatalf("%v: %s", err, body)
	}
	return doc
}

// TestRun runs the whole program on loopback ports with a fake tor: DNS on
// UDP and TCP, the status page, SIGHUP reloads, and shutdown.
func TestRun(t *testing.T) {
	dir := t.TempDir()
	listPath := filepath.Join(dir, "dnsfilter.list")
	writeList(t, listPath, "v1", "tracker.example")
	modPath := filepath.Join(dir, "status.json")
	os.WriteFile(modPath, []byte(`{"fw":"live"}`), 0o644)

	fake, err := fakedns.Start(false)
	if err != nil {
		t.Fatal(err)
	}
	defer fake.Close()
	owner := "-1"
	if _, err := os.ReadFile("/proc/net/udp"); err == nil {
		owner = strconv.Itoa(os.Getuid())
	}

	o, err := parseFlags([]string{"-insecure-allow-privileged", "-listen", "127.0.0.1:0", "-status-listen", "127.0.0.1:0",
		"-upstream", fake.Addr().String(), "-upstream-uid", owner, "-list", listPath, "-module-status", modPath,
		"-status-refresh", "0"})
	if err != nil {
		t.Fatal(err)
	}
	type addrs struct {
		dns    netip.AddrPort
		status net.Addr
	}
	ready := make(chan addrs, 1)
	o.onReady = func(d netip.AddrPort, s net.Addr) { ready <- addrs{d, s} }
	sig := make(chan os.Signal, 1)
	done := make(chan error, 1)
	go func() { done <- run(o, sig) }()
	var a addrs
	select {
	case a = <-ready:
	case err := <-done:
		t.Fatalf("run ended early: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("filter did not start")
	}

	ask := func(network, name string) dnsmessage.RCode {
		m, err := fakedns.Ask(network, a.dns, name, dnsmessage.TypeA, 5*time.Second)
		if err != nil {
			t.Fatalf("%s %s: %v", network, name, err)
		}
		return m.RCode
	}
	if rc := ask("udp", "www.example.org"); rc != dnsmessage.RCodeSuccess {
		t.Errorf("allowed: %v", rc)
	}
	if rc := ask("tcp", "x.tracker.example"); rc != dnsmessage.RCodeNameError {
		t.Errorf("blocked: %v", rc)
	}
	doc := getStatus(t, a.status)
	if doc["queries"] != 2.0 || doc["blocked"] != 1.0 || doc["forwarded"] != 1.0 {
		t.Errorf("counters %v %v %v", doc["queries"], doc["blocked"], doc["forwarded"])
	}
	if l := doc["list"].(map[string]any); l["version"] != "v1" || l["size"] != 1.0 {
		t.Errorf("list %v", l)
	}
	if u := doc["upstream"].(map[string]any); u["state"] != "ok" {
		t.Errorf("upstream %v", u)
	}
	if m := doc["module"].(map[string]any); m["fw"] != "live" {
		t.Errorf("module %v", m)
	}

	// SIGHUP loads a new list.
	writeList(t, listPath, "v2", "other.example")
	sig <- syscall.SIGHUP
	deadline := time.Now().Add(5 * time.Second)
	for getStatus(t, a.status)["list"].(map[string]any)["version"] != "v2" {
		if time.Now().After(deadline) {
			t.Fatal("list not reloaded")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if rc := ask("udp", "x.tracker.example"); rc != dnsmessage.RCodeSuccess {
		t.Errorf("old entry after reload: %v", rc)
	}
	if rc := ask("udp", "other.example"); rc != dnsmessage.RCodeNameError {
		t.Errorf("new entry after reload: %v", rc)
	}

	// A damaged list is refused; the current one stays.
	os.WriteFile(listPath, []byte("# format: 1\ngarbage\n"), 0o644)
	sig <- syscall.SIGHUP
	deadline = time.Now().Add(5 * time.Second)
	for getStatus(t, a.status)["list"].(map[string]any)["reload_error"] == nil {
		if time.Now().After(deadline) {
			t.Fatal("failed reload not reported")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if rc := ask("udp", "other.example"); rc != dnsmessage.RCodeNameError {
		t.Errorf("after a failed reload: %v", rc)
	}

	// Tor stops: SERVFAIL, and the status page says so.
	fake.Close()
	if rc := ask("udp", "new.example.org"); rc != dnsmessage.RCodeServerFailure {
		t.Errorf("tor down: %v", rc)
	}
	if u := getStatus(t, a.status)["upstream"].(map[string]any); u["state"] != "error" || u["last_error"] != "refused" {
		t.Errorf("upstream after tor stopped: %v", u)
	}

	sig <- syscall.SIGTERM
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("run: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("did not stop")
	}
	if _, err := fakedns.Ask("udp", a.dns, "www.example.org", dnsmessage.TypeA, 300*time.Millisecond); err == nil {
		t.Error("still answering after stop")
	}
}
