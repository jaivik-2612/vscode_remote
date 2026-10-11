package dnsfilter

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
	"antumbra/dnsfilter/internal/fakedns"
)

func TestNewLoopbackRefusesOtherServers(t *testing.T) {
	for _, a := range []string{"8.8.8.8:53", "192.168.1.1:53", "0.0.0.0:9053", "[::1]:9053", "[2001:db8::1]:53", "127.0.0.1:0"} {
		if _, err := NewLoopback(netip.MustParseAddrPort(a), "udp", time.Second, -1); err == nil {
			t.Errorf("NewLoopback(%s) accepted it", a)
		}
	}
	if _, err := NewLoopback(netip.MustParseAddrPort("127.0.0.1:9053"), "tls", time.Second, -1); err == nil {
		t.Error("accepted network tls")
	}
	if _, err := NewLoopback(netip.MustParseAddrPort("127.0.0.1:9053"), "udp", 0, -1); err == nil {
		t.Error("accepted a zero timeout")
	}
	if u, err := NewLoopback(netip.MustParseAddrPort("[::ffff:127.0.0.1]:9053"), "udp", time.Second, 2950); err != nil || u.Addr().String() != "127.0.0.1:9053" {
		t.Errorf("mapped loopback: %v %v", u, err)
	}
}

// fakeEnv is a handler talking to a fake tor over real loopback sockets.
type fakeEnv struct {
	h     *Handler
	fake  *fakedns.Server
	stats *Stats
	up    *Loopback
}

func newFakeEnv(t *testing.T, network string, timeout time.Duration, owner int) *fakeEnv {
	t.Helper()
	fake, err := fakedns.Start(true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(fake.Close)
	up, err := NewLoopback(fake.Addr(), network, timeout, owner)
	if err != nil {
		t.Fatal(err)
	}
	l := testList(t)
	stats := &Stats{}
	h := NewHandler(Config{List: func() *blocklist.List { return l }, Upstream: up, BlockedTTL: 60,
		FilterAAAA: true, LocalNames: true, MaxInflight: 8, Stats: stats})
	return &fakeEnv{h: h, fake: fake, stats: stats, up: up}
}

func (e *fakeEnv) ask(t *testing.T, name string, typ dnsmessage.Type) (*dnsmessage.Message, time.Duration) {
	t.Helper()
	start := time.Now()
	resp := e.h.Handle(context.Background(), query(0x77, name, typ), MaxUDPSize)
	took := time.Since(start)
	var m dnsmessage.Message
	if err := m.Unpack(resp); err != nil {
		t.Fatalf("reply does not parse: %v", err)
	}
	return &m, took
}

func TestFakeUpstream(t *testing.T) {
	e := newFakeEnv(t, "udp", 2*time.Second, -1)
	m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA)
	if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 ||
		m.Answers[0].Body.(*dnsmessage.AResource).A != fakedns.DefaultA.As4() {
		t.Fatalf("forwarded answer: %+v", m)
	}
	e.fake.SetNX("gone.example.org")
	if m, _ := e.ask(t, "gone.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeNameError {
		t.Errorf("tor's NXDOMAIN: %v", m.RCode)
	}
	if m, _ := e.ask(t, "4.4.8.8.in-addr.arpa.", dnsmessage.TypePTR); len(m.Answers) != 1 {
		t.Errorf("PTR: %+v", m)
	}
	// Blocked, local, AAAA and refused queries never reach tor.
	for _, q := range []struct {
		name string
		typ  dnsmessage.Type
	}{{"tracker.example.", dnsmessage.TypeA}, {"x.doubleclick.net.", dnsmessage.TypeA},
		{"printer.local.", dnsmessage.TypeA}, {"www.example.org.", dnsmessage.TypeAAAA},
		{"www.example.org.", dnsmessage.TypeALL}, {"www.example.org.", dnsmessage.TypeMX}} {
		e.ask(t, q.name, q.typ)
	}
	want := []string{"www.example.org", "gone.example.org", "4.4.8.8.in-addr.arpa"}
	if got := e.fake.Seen(); !reflect.DeepEqual(got, want) {
		t.Errorf("tor saw %q, want %q", got, want)
	}
	if known, ok, _, _ := e.stats.Upstream(); !known || !ok {
		t.Error("upstream state not ok after good exchanges")
	}
}

func TestUpstreamDownFailsClosedAtOnce(t *testing.T) {
	e := newFakeEnv(t, "udp", 3*time.Second, -1)
	e.fake.Close()
	m, took := e.ask(t, "www.example.org.", dnsmessage.TypeA)
	if m.RCode != dnsmessage.RCodeServerFailure || len(m.Answers) != 0 {
		t.Fatalf("tor down: %v, want SERVFAIL", m.RCode)
	}
	if took > time.Second {
		t.Errorf("took %v; a closed port should fail at once", took)
	}
	if _, _, code, _ := e.stats.Upstream(); code != "refused" {
		t.Errorf("state %q, want refused", code)
	}

	e = newFakeEnv(t, "tcp", 3*time.Second, -1)
	e.fake.Close()
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("tor down over tcp: %v", m.RCode)
	}
}

func TestUpstreamTimeout(t *testing.T) {
	e := newFakeEnv(t, "udp", 300*time.Millisecond, -1)
	e.fake.SetDelay(2 * time.Second)
	m, took := e.ask(t, "slow.example.org.", dnsmessage.TypeA)
	if m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("slow tor: %v, want SERVFAIL", m.RCode)
	}
	if took < 250*time.Millisecond || took > 1500*time.Millisecond {
		t.Errorf("took %v, want about the 300ms timeout", took)
	}
	if _, _, code, _ := e.stats.Upstream(); code != "timeout" {
		t.Errorf("state %q, want timeout", code)
	}
}

func TestUpstreamIgnoresWrongReplies(t *testing.T) {
	e := newFakeEnv(t, "udp", 2*time.Second, -1)
	e.fake.SetWrongFirst(true)
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 {
		t.Errorf("after a wrong-ID datagram: %+v", m)
	}
}

func TestUpstreamTruncatedRetriesOverTCP(t *testing.T) {
	e := newFakeEnv(t, "udp", 2*time.Second, -1)
	e.fake.SetTruncate(true)
	if m, _ := e.ask(t, "big.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 || m.Truncated {
		t.Errorf("TC from tor: %+v", m)
	}
	if e.fake.Queries() != 2 {
		t.Errorf("tor saw %d queries, want 2 (udp, then tcp)", e.fake.Queries())
	}
}

func TestUpstreamTCP(t *testing.T) {
	e := newFakeEnv(t, "tcp", 2*time.Second, -1)
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 {
		t.Errorf("tcp upstream: %+v", m)
	}
}

func TestUpstreamOwnerCheck(t *testing.T) {
	if _, err := os.ReadFile("/proc/net/udp"); err != nil {
		t.Skip("/proc/net/udp not readable here")
	}
	me := os.Getuid()
	e := newFakeEnv(t, "udp", 2*time.Second, me)
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeSuccess {
		t.Fatalf("port owned by the expected uid: %v", m.RCode)
	}
	e = newFakeEnv(t, "udp", 2*time.Second, me+1)
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("port owned by another uid: %v, want SERVFAIL", m.RCode)
	}
	if _, _, code, _ := e.stats.Upstream(); code != "owner" {
		t.Errorf("state %q, want owner", code)
	}
	if e.fake.Queries() != 0 {
		t.Error("the query was sent to a port held by the wrong uid")
	}
	e = newFakeEnv(t, "tcp", 2*time.Second, me+1)
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeServerFailure || e.fake.Queries() != 0 {
		t.Errorf("tcp, wrong owner: %v", m.RCode)
	}
	e = newFakeEnv(t, "udp", 2*time.Second, me)
	e.up.SetProcNet(t.TempDir()) // nothing readable there
	if m, _ := e.ask(t, "www.example.org.", dnsmessage.TypeA); m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("unreadable socket table: %v, want SERVFAIL", m.RCode)
	}
}

// procAddr formats an address the way /proc/net/{udp,tcp}{,6} print it on
// this machine: each 32-bit word as a host-order integer.
func procAddr(a netip.Addr, port uint16) string {
	b := a.AsSlice()
	var s strings.Builder
	for i := 0; i < len(b); i += 4 {
		fmt.Fprintf(&s, "%08X", binary.NativeEndian.Uint32(b[i:]))
	}
	return fmt.Sprintf("%s:%04X", s.String(), port)
}

func procTable(rows ...string) string {
	out := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n"
	for i, r := range rows {
		out += fmt.Sprintf("%4d: %s\n", i, r)
	}
	return out
}

func row(local, remote string, st string, uid int) string {
	return fmt.Sprintf("%s %s %s 00000000:00000000 00:00000000 00000000 %5d        0 12345 2 0000000000000000 0", local, remote, st, uid)
}

func TestPortOwners(t *testing.T) {
	ip := netip.MustParseAddr
	zero4 := procAddr(ip("0.0.0.0"), 0)
	zero6 := procAddr(ip("::"), 0)
	dir := t.TempDir()
	write := func(name, content string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("udp", procTable(
		row(procAddr(ip("127.0.0.1"), 9053), zero4, "07", 2950),                            // tor
		row(procAddr(ip("127.0.0.2"), 9053), zero4, "07", 10200),                           // another address: ignored
		row(procAddr(ip("127.0.0.1"), 40000), procAddr(ip("127.0.0.1"), 9053), "01", 2951), // the filter's own socket
		row(procAddr(ip("10.0.2.15"), 9053), zero4, "07", 10300),                           // LAN address: ignored
	))
	write("udp6", procTable(
		row(procAddr(ip("::1"), 9053), zero6, "07", 10400),              // ::1 does not get 127.0.0.1 traffic
		row(procAddr(ip("::ffff:127.0.0.1"), 9053), zero6, "07", 10500), // mapped loopback: counts
	))
	got, err := portOwners(dir, "udp", 9053)
	if err != nil {
		t.Fatal(err)
	}
	if want := []int{2950, 10500}; !reflect.DeepEqual(got, want) {
		t.Errorf("udp owners %v, want %v", got, want)
	}

	write("udp", procTable(row(procAddr(ip("0.0.0.0"), 9053), zero4, "07", 10600)))
	os.Remove(filepath.Join(dir, "udp6")) // IPv6 off: the v6 table may be missing
	if got, err := portOwners(dir, "udp", 9053); err != nil || !reflect.DeepEqual(got, []int{10600}) {
		t.Errorf("wildcard bind: %v %v", got, err)
	}

	write("tcp", procTable(
		row(procAddr(ip("127.0.0.1"), 9053), zero4, "0A", 2950),                            // listening
		row(procAddr(ip("127.0.0.1"), 9053), procAddr(ip("127.0.0.1"), 41000), "01", 2950), // accepted connection
		row(procAddr(ip("127.0.0.1"), 41000), procAddr(ip("127.0.0.1"), 9053), "01", 2951), // the filter's side
	))
	write("tcp6", procTable(row(procAddr(ip("::"), 9053), zero6, "0A", 10700)))
	if got, err := portOwners(dir, "tcp", 9053); err != nil || !reflect.DeepEqual(got, []int{2950, 10700}) {
		t.Errorf("tcp owners %v %v, want [2950 10700]", got, err)
	}

	os.Remove(filepath.Join(dir, "udp"))
	if _, err := portOwners(dir, "udp", 9053); err == nil {
		t.Error("a missing IPv4 table is not an error")
	}
	write("udp", "header\n0: zz:qq\n")
	if _, err := portOwners(dir, "udp", 9053); err == nil {
		t.Error("a garbled table is not an error")
	}
}

func TestParseProcAddr(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "0.0.0.0", "::", "::1", "::ffff:127.0.0.1", "2001:db8::42"} {
		a := netip.MustParseAddr(s)
		got, port, err := parseProcAddr(procAddr(a, 9053))
		if err != nil || got != a || port != 9053 {
			t.Errorf("%s: got %v %d %v", s, got, port, err)
		}
	}
	if binary.NativeEndian.Uint16([]byte{1, 0}) == 1 { // little-endian, as on the phone and in CI
		a, _, _ := parseProcAddr("0100007F:235D")
		if a.String() != "127.0.0.1" {
			t.Errorf("literal kernel form decoded as %v", a)
		}
	}
	for _, bad := range []string{"", "0100007F", "0100007F:", "0100007:235D", "ZZ00007F:235D", "0100007F:XYZW",
		hex.EncodeToString(make([]byte, 9)) + ":0035"} {
		if _, _, err := parseProcAddr(bad); err == nil {
			t.Errorf("parseProcAddr(%q) accepted it", bad)
		}
	}
}
