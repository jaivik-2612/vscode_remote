package dnsfilter

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"syscall"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
	"antumbra/dnsfilter/internal/fakedns"
)

type srvEnv struct {
	srv   *Server
	fake  *fakedns.Server
	stats *Stats
}

func newServer(t *testing.T, mod func(*ServerConfig)) *srvEnv {
	t.Helper()
	fake, err := fakedns.Start(false)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(fake.Close)
	up, err := NewLoopback(fake.Addr(), "udp", 2*time.Second, -1)
	if err != nil {
		t.Fatal(err)
	}
	l := testList(t)
	stats := &Stats{}
	h := NewHandler(Config{List: func() *blocklist.List { return l }, Upstream: up, BlockedTTL: 60,
		FilterAAAA: true, LocalNames: true, MaxInflight: 8, Stats: stats})
	cfg := ServerConfig{Handler: h, Stats: stats, Limiter: NewLimiter(1000, 1000, 64), TCPIdle: 2 * time.Second}
	if mod != nil {
		mod(&cfg)
	}
	srv, err := Listen(netip.MustParseAddrPort("127.0.0.1:0"), cfg)
	if err != nil {
		t.Fatal(err)
	}
	srv.Serve()
	t.Cleanup(srv.Close)
	return &srvEnv{srv: srv, fake: fake, stats: stats}
}

func frame(msg []byte) []byte {
	return append(binary.BigEndian.AppendUint16(nil, uint16(len(msg))), msg...)
}

func readFrame(t *testing.T, c net.Conn) *dnsmessage.Message {
	t.Helper()
	var l [2]byte
	if _, err := io.ReadFull(c, l[:]); err != nil {
		t.Fatalf("read length: %v", err)
	}
	b := make([]byte, binary.BigEndian.Uint16(l[:]))
	if _, err := io.ReadFull(c, b); err != nil {
		t.Fatalf("read message: %v", err)
	}
	var m dnsmessage.Message
	if err := m.Unpack(b); err != nil {
		t.Fatalf("unpack: %v", err)
	}
	return &m
}

func TestServerUDPAndTCP(t *testing.T) {
	e := newServer(t, nil)
	for _, network := range []string{"udp", "tcp"} {
		m, err := fakedns.Ask(network, e.srv.Addr(), "www.example.org", dnsmessage.TypeA, 3*time.Second)
		if err != nil || m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 {
			t.Errorf("%s allowed: %v %+v", network, err, m)
		}
		m, err = fakedns.Ask(network, e.srv.Addr(), "a.tracker.example", dnsmessage.TypeA, 3*time.Second)
		if err != nil || m.RCode != dnsmessage.RCodeNameError {
			t.Errorf("%s blocked: %v %+v", network, err, m)
		}
	}
}

func TestTCPFraming(t *testing.T) {
	e := newServer(t, nil)
	dial := func() net.Conn {
		c, err := net.Dial("tcp", e.srv.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(5 * time.Second))
		return c
	}

	// Two queries in one write: two answers, in order.
	c := dial()
	q1 := query(1, "one.example.org.", dnsmessage.TypeA)
	q2 := query(2, "two.tracker.example.", dnsmessage.TypeA)
	if _, err := c.Write(append(frame(q1), frame(q2)...)); err != nil {
		t.Fatal(err)
	}
	if m := readFrame(t, c); m.ID != 1 || m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("first: %+v", m.Header)
	}
	if m := readFrame(t, c); m.ID != 2 || m.RCode != dnsmessage.RCodeNameError {
		t.Errorf("second: %+v", m.Header)
	}
	c.Close()

	// A message dribbled in one byte at a time.
	c = dial()
	for _, b := range frame(query(3, "three.example.org.", dnsmessage.TypeA)) {
		if _, err := c.Write([]byte{b}); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Millisecond)
	}
	if m := readFrame(t, c); m.ID != 3 || len(m.Answers) != 1 {
		t.Errorf("dribbled: %+v", m)
	}
	c.Close()

	// A length too short for a DNS header closes the connection.
	c = dial()
	c.Write([]byte{0, 5, 1, 2, 3, 4, 5})
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Error("connection still open after a 5-byte message")
	}
	c.Close()

	// A message that is cut short gets no answer; the connection closes
	// when the read times out or the client closes.
	c = dial()
	full := frame(query(4, "four.example.org.", dnsmessage.TypeA))
	c.Write(full[:len(full)-3])
	c.(*net.TCPConn).CloseWrite()
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Error("answered a cut message")
	}
	c.Close()

	// A reply sent to the filter is dropped, and the connection closed.
	c = dial()
	r := query(5, "five.example.org.", dnsmessage.TypeA)
	r[2] |= 0x80
	c.Write(frame(r))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Error("answered a reply")
	}
	c.Close()
}

func TestTCPIdleTimeout(t *testing.T) {
	e := newServer(t, func(c *ServerConfig) { c.TCPIdle = 200 * time.Millisecond })
	c, err := net.Dial("tcp", e.srv.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	start := time.Now()
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("read data from an idle connection")
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Errorf("idle connection closed after %v, want about 200ms", took)
	}
}

func TestTCPConnectionLimit(t *testing.T) {
	e := newServer(t, func(c *ServerConfig) { c.MaxTCPConns = 2 })
	var held []net.Conn
	for i := 0; i < 2; i++ {
		c, err := net.Dial("tcp", e.srv.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		held = append(held, c)
	}
	// Make sure both are accepted and counted before the third.
	for i, c := range held {
		c.SetDeadline(time.Now().Add(3 * time.Second))
		c.Write(frame(query(uint16(i), "x.example.org.", dnsmessage.TypeA)))
		readFrame(t, c)
	}
	c, err := net.Dial("tcp", e.srv.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(3 * time.Second))
	c.Write(frame(query(9, "x.example.org.", dnsmessage.TypeA)))
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Error("a third connection was served")
	}
}

func TestUDPDropsReplies(t *testing.T) {
	e := newServer(t, nil)
	c, err := net.Dial("udp", e.srv.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	r := query(5, "x.example.org.", dnsmessage.TypeA)
	r[2] |= 0x80
	c.Write(r)
	c.Write([]byte{1, 2, 3})
	c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if n, err := c.Read(make([]byte, 512)); err == nil {
		t.Errorf("got a %d-byte answer to a reply or junk", n)
	}
	if e.stats.Dropped.Load() != 2 {
		t.Errorf("dropped=%d, want 2", e.stats.Dropped.Load())
	}
}

func TestRateLimitPerClientPort(t *testing.T) {
	e := newServer(t, func(c *ServerConfig) { c.Limiter = NewLimiter(1, 3, 64) })
	c, err := net.Dial("udp", e.srv.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	for i := 0; i < 10; i++ {
		c.Write(query(uint16(i), "a.tracker.example.", dnsmessage.TypeA))
	}
	got := 0
	c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	for {
		if _, err := c.Read(make([]byte, 512)); err != nil {
			break
		}
		got++
	}
	if got != 3 || e.stats.RateLimited.Load() != 7 {
		t.Errorf("answered %d, rate-limited %d; want 3 and 7", got, e.stats.RateLimited.Load())
	}
	// Another client port has its own allowance.
	c2, err := net.Dial("udp", e.srv.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer c2.Close()
	c2.Write(query(99, "a.tracker.example.", dnsmessage.TypeA))
	c2.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := c2.Read(make([]byte, 512)); err != nil {
		t.Errorf("second client port: %v", err)
	}
}

func TestNoOtherSocketCanShareThePort(t *testing.T) {
	e := newServer(t, nil)
	lc := net.ListenConfig{Control: func(network, address string, c syscall.RawConn) error {
		var serr error
		c.Control(func(fd uintptr) {
			serr = syscall.SetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
		})
		return serr
	}}
	pc, err := lc.ListenPacket(t.Context(), "udp4", e.srv.Addr().String())
	if err == nil {
		pc.Close()
		t.Fatal("another socket bound the filter's UDP port with SO_REUSEADDR")
	}
	if !errors.Is(err, syscall.EADDRINUSE) {
		t.Errorf("err = %v, want EADDRINUSE", err)
	}
	if ln, err := lc.Listen(t.Context(), "tcp4", e.srv.Addr().String()); err == nil {
		ln.Close()
		t.Fatal("another socket listened on the filter's TCP port")
	}
}

func TestListenOnlyOnLoopback(t *testing.T) {
	stats := &Stats{}
	h := NewHandler(Config{Stats: stats, Upstream: &stub{}})
	for _, a := range []string{"0.0.0.0:0", "192.0.2.1:53", "[::1]:0", "[::]:0"} {
		if s, err := Listen(netip.MustParseAddrPort(a), ServerConfig{Handler: h, Stats: stats}); err == nil {
			s.Close()
			t.Errorf("Listen(%s) accepted it", a)
		}
	}
}

func TestLimiter(t *testing.T) {
	now := time.Unix(1000, 0)
	l := NewLimiter(2, 4, 16)
	l.now = func() time.Time { return now }
	k := netip.MustParseAddrPort("127.0.0.1:40000")
	for i := 0; i < 4; i++ {
		if !l.Allow(k) {
			t.Fatalf("burst query %d refused", i)
		}
	}
	if l.Allow(k) {
		t.Fatal("fifth query allowed")
	}
	now = now.Add(500 * time.Millisecond) // one token back
	if !l.Allow(k) || l.Allow(k) {
		t.Fatal("refill is wrong")
	}
	now = now.Add(time.Hour) // never more than the burst
	for i := 0; i < 4; i++ {
		l.Allow(k)
	}
	if l.Allow(k) {
		t.Fatal("bucket refilled beyond the burst")
	}
	// Many idle client ports are forgotten, not kept for ever.
	for p := 0; p < 100; p++ {
		l.Allow(netip.AddrPortFrom(k.Addr(), uint16(41000+p)))
		now = now.Add(10 * time.Second)
	}
	if n := l.Len(); n > 16 {
		t.Errorf("limiter tracks %d ports, cap 16", n)
	}
	if !NewLimiter(0, 1, 16).Allow(k) || !(*Limiter)(nil).Allow(k) {
		t.Error("a disabled limiter refuses")
	}
}
