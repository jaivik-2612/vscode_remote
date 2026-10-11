package dnsfilter

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
)

// stub is an in-memory upstream. fn makes tor's reply to one question.
type stub struct {
	calls atomic.Int64
	fn    func(id uint16, q dnsmessage.Question) ([]byte, error)
}

func (s *stub) Exchange(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error) {
	s.calls.Add(1)
	var p dnsmessage.Parser
	h, err := p.Start(query)
	if err != nil {
		return nil, err
	}
	q, err := p.Question()
	if err != nil {
		return nil, err
	}
	r, err := s.fn(h.ID, q)
	if err != nil {
		return nil, err
	}
	if !match(r) {
		// A real upstream would keep waiting for the right reply.
		return nil, ErrUpstreamTimeout
	}
	return r, nil
}

// reply builds a reply from tor; add adds records to the answer section.
func reply(id uint16, q dnsmessage.Question, rcode dnsmessage.RCode, add func(b *dnsmessage.Builder)) []byte {
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, Response: true, RecursionAvailable: true, RCode: rcode})
	b.EnableCompression()
	b.StartQuestions()
	b.Question(q)
	b.StartAnswers()
	if add != nil {
		add(&b)
	}
	m, err := b.Finish()
	if err != nil {
		panic(err)
	}
	return m
}

func rr(name string, t dnsmessage.Type) dnsmessage.ResourceHeader {
	return dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName(name), Type: t, Class: dnsmessage.ClassINET, TTL: 300}
}

// answerA is a stub function that answers every A query with 192.0.2.1.
func answerA(id uint16, q dnsmessage.Question) ([]byte, error) {
	return reply(id, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
		switch q.Type {
		case dnsmessage.TypeA:
			b.AResource(rr(q.Name.String(), dnsmessage.TypeA), dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}})
		case dnsmessage.TypeAAAA:
			b.AAAAResource(rr(q.Name.String(), dnsmessage.TypeAAAA), dnsmessage.AAAAResource{AAAA: [16]byte{0x20, 0x01, 0x0d, 0xb8, 15: 1}})
		case dnsmessage.TypePTR:
			b.PTRResource(rr(q.Name.String(), dnsmessage.TypePTR), dnsmessage.PTRResource{PTR: dnsmessage.MustNewName("host.example.")})
		}
	}), nil
}

func testList(t testing.TB) *blocklist.List {
	t.Helper()
	var buf bytes.Buffer
	err := blocklist.Write(&buf, blocklist.Header{Version: "t"},
		[]string{"tracker.example", "ads.example.org", "doubleclick.net"}, []string{"ok.tracker.example"})
	if err != nil {
		t.Fatal(err)
	}
	l, err := blocklist.Parse(buf.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	return l
}

type env struct {
	h     *Handler
	up    *stub
	stats *Stats
}

func newEnv(t testing.TB, mod func(*Config)) *env {
	l := testList(t)
	e := &env{up: &stub{fn: answerA}, stats: &Stats{}}
	cfg := Config{
		List: func() *blocklist.List { return l }, Upstream: e.up, BlockedTTL: 60,
		FilterAAAA: true, LocalNames: true, MaxInflight: 8, Stats: e.stats,
	}
	if mod != nil {
		mod(&cfg)
	}
	e.h = NewHandler(cfg)
	return e
}

func query(id uint16, name string, t dnsmessage.Type) []byte {
	return queryClass(id, name, t, dnsmessage.ClassINET)
}

func queryClass(id uint16, name string, t dnsmessage.Type, c dnsmessage.Class) []byte {
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: t, Class: c})
	m, err := b.Finish()
	if err != nil {
		panic(err)
	}
	return m
}

func (e *env) ask(t *testing.T, msg []byte, size int) *dnsmessage.Message {
	t.Helper()
	resp := e.h.Handle(context.Background(), msg, size)
	if resp == nil {
		t.Fatal("no reply")
	}
	if len(resp) > size {
		t.Fatalf("reply of %d bytes, limit %d", len(resp), size)
	}
	var m dnsmessage.Message
	if err := m.Unpack(resp); err != nil {
		t.Fatalf("reply does not parse: %v", err)
	}
	if !m.Response || !m.RecursionAvailable {
		t.Errorf("reply flags: %+v", m.Header)
	}
	return &m
}

func TestForwardEchoesClient(t *testing.T) {
	e := newEnv(t, nil)
	m := e.ask(t, query(0x1234, "WwW.Example.COM.", dnsmessage.TypeA), MaxUDPSize)
	if m.ID != 0x1234 || !m.RecursionDesired || m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("header %+v", m.Header)
	}
	if len(m.Questions) != 1 || m.Questions[0].Name.String() != "WwW.Example.COM." {
		t.Errorf("question not echoed as sent: %+v", m.Questions)
	}
	if len(m.Answers) != 1 || m.Answers[0].Body.(*dnsmessage.AResource).A != [4]byte{192, 0, 2, 1} {
		t.Errorf("answers %+v", m.Answers)
	}
	if len(m.Authorities) != 0 || len(m.Additionals) != 0 {
		t.Error("forwarded answer has extra sections")
	}
	if e.up.calls.Load() != 1 || e.stats.Forwarded.Load() != 1 || e.stats.Queries.Load() != 1 {
		t.Errorf("calls=%d forwarded=%d queries=%d", e.up.calls.Load(), e.stats.Forwarded.Load(), e.stats.Queries.Load())
	}
}

func TestForwardUsesFreshQuery(t *testing.T) {
	// The query tor sees has its own ID and only the question, whatever
	// the client sent (here: an EDNS OPT record with a client subnet).
	var seen []byte
	e := newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) { return answerA(id, q) }
	inner := e.h.cfg.Upstream
	e.h.cfg.Upstream = upstreamFunc(func(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error) {
		seen = append([]byte(nil), query...)
		return inner.Exchange(ctx, query, match)
	})
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 7, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName("a.example."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	b.StartAdditionals()
	var opt dnsmessage.ResourceHeader
	opt.SetEDNS0(4096, dnsmessage.RCodeSuccess, false)
	b.OPTResource(opt, dnsmessage.OPTResource{Options: []dnsmessage.Option{{Code: 8, Data: []byte{0, 1, 24, 0, 192, 0, 2}}}})
	msg, _ := b.Finish()
	m := e.ask(t, msg, MaxUDPSize)
	if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 {
		t.Fatalf("reply %+v", m)
	}
	var up dnsmessage.Message
	if err := up.Unpack(seen); err != nil {
		t.Fatal(err)
	}
	if up.ID == 7 && up.ID == m.ID {
		// One in 65536 runs: not a failure by itself; the other checks still hold.
		t.Log("upstream ID happened to equal the client's")
	}
	if len(up.Questions) != 1 || len(up.Answers)+len(up.Authorities)+len(up.Additionals) != 0 || !up.RecursionDesired {
		t.Errorf("upstream query carries more than the question: %+v", up)
	}
}

type upstreamFunc func(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error)

func (f upstreamFunc) Exchange(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error) {
	return f(ctx, query, match)
}

func TestBlockedNXDOMAIN(t *testing.T) {
	e := newEnv(t, nil)
	for _, name := range []string{"tracker.example.", "a.b.TRACKER.example.", "ads.example.org."} {
		for _, typ := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA, dnsmessage.TypeHTTPS, dnsmessage.TypeMX} {
			m := e.ask(t, query(9, name, typ), MaxUDPSize)
			if m.RCode != dnsmessage.RCodeNameError || len(m.Answers) != 0 {
				t.Errorf("%s %v: %v with %d answers, want NXDOMAIN", name, typ, m.RCode, len(m.Answers))
			}
			if len(m.Authorities) != 1 {
				t.Fatalf("%s: no SOA for negative caching", name)
			}
			soa, ok := m.Authorities[0].Body.(*dnsmessage.SOAResource)
			if !ok || soa.MinTTL != 60 || m.Authorities[0].Header.TTL != 60 {
				t.Errorf("SOA %+v", m.Authorities[0])
			}
		}
	}
	if e.up.calls.Load() != 0 {
		t.Errorf("blocked names reached tor %d times", e.up.calls.Load())
	}
	if e.stats.Blocked.Load() != 12 {
		t.Errorf("blocked counter %d, want 12", e.stats.Blocked.Load())
	}
	// The exception and an unrelated name are forwarded.
	for _, name := range []string{"ok.tracker.example.", "x.ok.tracker.example.", "example.org."} {
		if m := e.ask(t, query(9, name, dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 {
			t.Errorf("%s: %v with %d answers, want a forwarded answer", name, m.RCode, len(m.Answers))
		}
	}
}

func TestBlockedZero(t *testing.T) {
	e := newEnv(t, func(c *Config) { c.BlockMode = BlockZero })
	m := e.ask(t, query(1, "tracker.example.", dnsmessage.TypeA), MaxUDPSize)
	if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 || m.Answers[0].Body.(*dnsmessage.AResource).A != [4]byte{} {
		t.Errorf("A: %+v", m)
	}
	if m.Answers[0].Header.TTL != 60 {
		t.Errorf("TTL %d", m.Answers[0].Header.TTL)
	}
	m = e.ask(t, query(1, "tracker.example.", dnsmessage.TypeAAAA), MaxUDPSize)
	if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 || m.Answers[0].Body.(*dnsmessage.AAAAResource).AAAA != [16]byte{} {
		t.Errorf("AAAA: %+v", m)
	}
	m = e.ask(t, query(1, "tracker.example.", dnsmessage.TypeTXT), MaxUDPSize)
	if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 0 || len(m.Authorities) != 1 {
		t.Errorf("TXT: %+v", m)
	}
}

func TestAAAAAndOtherTypes(t *testing.T) {
	e := newEnv(t, nil)
	for _, typ := range []dnsmessage.Type{dnsmessage.TypeAAAA, dnsmessage.TypeMX, dnsmessage.TypeTXT,
		dnsmessage.TypeSRV, dnsmessage.TypeHTTPS, dnsmessage.TypeSVCB, dnsmessage.TypeNS, dnsmessage.TypeSOA, dnsmessage.Type(257)} {
		m := e.ask(t, query(2, "example.org.", typ), MaxUDPSize)
		if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 0 || len(m.Authorities) != 1 {
			t.Errorf("%v: %v, %d answers, %d authorities; want an empty answer with SOA", typ, m.RCode, len(m.Answers), len(m.Authorities))
		}
	}
	if e.up.calls.Load() != 0 {
		t.Errorf("tor was asked %d times", e.up.calls.Load())
	}
	// PTR is forwarded.
	if m := e.ask(t, query(2, "4.4.8.8.in-addr.arpa.", dnsmessage.TypePTR), MaxUDPSize); len(m.Answers) != 1 {
		t.Errorf("PTR not forwarded: %+v", m)
	}

	// With -aaaa forward, AAAA goes to tor and its records are kept.
	e = newEnv(t, func(c *Config) { c.FilterAAAA = false })
	if m := e.ask(t, query(3, "example.org.", dnsmessage.TypeAAAA), MaxUDPSize); len(m.Answers) != 1 || e.up.calls.Load() != 1 {
		t.Errorf("AAAA forward: %+v", m)
	}
}

func TestAAAARecordsDroppedFromReplies(t *testing.T) {
	e := newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		return reply(id, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
			b.AResource(rr(q.Name.String(), dnsmessage.TypeA), dnsmessage.AResource{A: [4]byte{192, 0, 2, 1}})
			b.AAAAResource(rr(q.Name.String(), dnsmessage.TypeAAAA), dnsmessage.AAAAResource{})
			b.MXResource(rr(q.Name.String(), dnsmessage.TypeMX), dnsmessage.MXResource{MX: dnsmessage.MustNewName("mx.example.")})
			b.TXTResource(rr(q.Name.String(), dnsmessage.TypeTXT), dnsmessage.TXTResource{TXT: []string{"x"}})
			h := rr(q.Name.String(), dnsmessage.TypeA)
			h.Class = dnsmessage.Class(3) // CHAOS
			b.AResource(h, dnsmessage.AResource{A: [4]byte{6, 6, 6, 6}})
		}), nil
	}
	m := e.ask(t, query(4, "example.org.", dnsmessage.TypeA), MaxUDPSize)
	if len(m.Answers) != 1 || m.Answers[0].Header.Type != dnsmessage.TypeA || m.Answers[0].Body.(*dnsmessage.AResource).A != [4]byte{192, 0, 2, 1} {
		t.Errorf("answers %+v", m.Answers)
	}
}

func TestRefused(t *testing.T) {
	e := newEnv(t, nil)
	for _, typ := range []dnsmessage.Type{dnsmessage.TypeALL, dnsmessage.TypeAXFR, 251 /* IXFR */, 253, 254,
		dnsmessage.TypeOPT, 0, 249, 250, 128} {
		if m := e.ask(t, query(5, "example.org.", typ), MaxUDPSize); m.RCode != dnsmessage.RCodeRefused {
			t.Errorf("type %d: %v, want REFUSED", typ, m.RCode)
		}
	}
	for _, c := range []dnsmessage.Class{3 /* CHAOS */, 4 /* HESIOD */, 255 /* ANY */} {
		if m := e.ask(t, queryClass(5, "version.bind.", dnsmessage.TypeTXT, c), MaxUDPSize); m.RCode != dnsmessage.RCodeRefused {
			t.Errorf("class %d: %v, want REFUSED", c, m.RCode)
		}
	}
	if e.up.calls.Load() != 0 {
		t.Error("a refused query reached tor")
	}
}

func TestMalformed(t *testing.T) {
	e := newEnv(t, nil)
	valid := query(0x4242, "example.org.", dnsmessage.TypeA)

	for name, msg := range map[string][]byte{
		"empty":      {},
		"short":      valid[:11],
		"a response": func() []byte { m := append([]byte(nil), valid...); m[2] |= 0x80; return m }(),
	} {
		if resp := e.h.Handle(context.Background(), msg, MaxUDPSize); resp != nil {
			t.Errorf("%s: answered, want silence", name)
		}
	}

	header := func(qd uint16, opcode byte) []byte {
		h := make([]byte, 12)
		binary.BigEndian.PutUint16(h, 0x4242)
		h[2] = opcode<<3 | 0x01
		binary.BigEndian.PutUint16(h[4:], qd)
		return h
	}
	q := valid[12:] // the question section of the valid query
	cases := map[string]struct {
		msg   []byte
		rcode dnsmessage.RCode
	}{
		"no question":     {header(0, 0), dnsmessage.RCodeFormatError},
		"two questions":   {append(append(header(2, 0), q...), q...), dnsmessage.RCodeFormatError},
		"count too high":  {append(header(2, 0), q...), dnsmessage.RCodeFormatError},
		"cut question":    {append(header(1, 0), q[:5]...), dnsmessage.RCodeFormatError},
		"pointer loop":    {append(header(1, 0), 0xC0, 12, 0, 1, 0, 1), dnsmessage.RCodeFormatError},
		"forward pointer": {append(header(1, 0), 0xC0, 40, 0, 1, 0, 1), dnsmessage.RCodeFormatError},
		"reserved label":  {append(header(1, 0), 0x40, 'a', 0, 0, 1, 0, 1), dnsmessage.RCodeFormatError},
		"dot in label":    {append(header(1, 0), 3, 'a', '.', 'b', 0, 0, 1, 0, 1), dnsmessage.RCodeFormatError},
		"opcode STATUS":   {append(header(1, 2), q...), dnsmessage.RCodeNotImplemented},
		"opcode NOTIFY":   {append(header(1, 4), q...), dnsmessage.RCodeNotImplemented},
		"opcode UPDATE":   {append(header(1, 5), q...), dnsmessage.RCodeNotImplemented},
	}
	for name, c := range cases {
		resp := e.h.Handle(context.Background(), c.msg, MaxUDPSize)
		if resp == nil {
			t.Errorf("%s: no answer", name)
			continue
		}
		var m dnsmessage.Message
		if err := m.Unpack(resp); err != nil {
			t.Errorf("%s: reply does not parse: %v", name, err)
			continue
		}
		if m.ID != 0x4242 || m.RCode != c.rcode || !m.Response {
			t.Errorf("%s: ID %#x rcode %v, want %#x %v", name, m.ID, m.RCode, 0x4242, c.rcode)
		}
	}
	// Trailing junk after a good question is ignored.
	if m := e.ask(t, append(append([]byte(nil), valid...), 1, 2, 3), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("trailing junk: %v", m.RCode)
	}
	if e.up.calls.Load() != 1 {
		t.Errorf("tor asked %d times, want 1", e.up.calls.Load())
	}
}

func TestLocalNames(t *testing.T) {
	e := newEnv(t, nil)
	local := []string{"printer.local.", "local.", "router.lan.", "fritz.home.", "nas.home.arpa.", "x.internal.",
		"a.localdomain.", "foo.test.", "bar.invalid.", "x.alt.", "my.corp.",
		"1.1.168.192.in-addr.arpa.", "5.0.0.10.in-addr.arpa.", "1.0.16.172.in-addr.arpa.", "1.0.31.172.in-addr.arpa.",
		"1.0.0.127.in-addr.arpa.", "1.1.254.169.in-addr.arpa.", "1.0.64.100.in-addr.arpa.", "1.0.127.100.in-addr.arpa.",
		"1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.e.f.ip6.arpa.",
		"1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.ip6.arpa."}
	for _, n := range local {
		if m := e.ask(t, query(6, n, dnsmessage.TypePTR), MaxUDPSize); m.RCode != dnsmessage.RCodeNameError {
			t.Errorf("%s: %v, want NXDOMAIN", n, m.RCode)
		}
	}
	forwarded := []string{"lan.example.com.", "localhost.example.com.", "1.0.15.172.in-addr.arpa.",
		"1.0.32.172.in-addr.arpa.", "1.0.128.100.in-addr.arpa.", "8.8.8.8.in-addr.arpa.", "abcdefgh.onion.", "x.exit."}
	for _, n := range forwarded {
		if m := e.ask(t, query(6, n, dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 1 {
			t.Errorf("%s: %v with %d answers, want forwarded", n, m.RCode, len(m.Answers))
		}
	}
	if got := e.up.calls.Load(); got != int64(len(forwarded)) {
		t.Errorf("tor asked %d times, want %d", got, len(forwarded))
	}
	m := e.ask(t, query(6, "localhost.", dnsmessage.TypeA), MaxUDPSize)
	if len(m.Answers) != 1 || m.Answers[0].Body.(*dnsmessage.AResource).A != [4]byte{127, 0, 0, 1} {
		t.Errorf("localhost A: %+v", m)
	}
	if m := e.ask(t, query(6, "a.localhost.", dnsmessage.TypeAAAA), MaxUDPSize); len(m.Answers) != 0 || m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("localhost AAAA with IPv6 off: %+v", m)
	}

	// Off: local names go to tor like any other.
	e = newEnv(t, func(c *Config) { c.LocalNames = false })
	if m := e.ask(t, query(6, "printer.local.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess || e.up.calls.Load() != 1 {
		t.Errorf("local names off: %+v", m)
	}
}

func TestUpstreamFailuresAreServfail(t *testing.T) {
	for _, upErr := range []error{ErrUpstreamDown, ErrUpstreamTimeout, ErrUpstreamOwner, ErrOwnerUnknown,
		ErrUpstreamIO, ErrUpstreamReply, errors.New("anything else")} {
		e := newEnv(t, nil)
		e.up.fn = func(uint16, dnsmessage.Question) ([]byte, error) { return nil, upErr }
		m := e.ask(t, query(8, "example.org.", dnsmessage.TypeA), MaxUDPSize)
		if m.RCode != dnsmessage.RCodeServerFailure || len(m.Answers) != 0 {
			t.Errorf("%v: %v, want SERVFAIL", upErr, m.RCode)
		}
		if e.stats.ServFail.Load() != 1 || e.stats.UpstreamErrors.Load() != 1 {
			t.Errorf("%v: servfail=%d upstream_errors=%d", upErr, e.stats.ServFail.Load(), e.stats.UpstreamErrors.Load())
		}
		known, ok, code, _ := e.stats.Upstream()
		want := upErr.Error()
		if want == "anything else" {
			want = "io"
		}
		if !known || ok || code != want {
			t.Errorf("%v: upstream state known=%v ok=%v code=%q", upErr, known, ok, code)
		}
	}

	for _, rc := range []dnsmessage.RCode{dnsmessage.RCodeServerFailure, dnsmessage.RCodeRefused,
		dnsmessage.RCodeNotImplemented, dnsmessage.RCodeFormatError, 9} {
		e := newEnv(t, nil)
		e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) { return reply(id, q, rc, nil), nil }
		if m := e.ask(t, query(8, "example.org.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeServerFailure {
			t.Errorf("tor rcode %v: %v, want SERVFAIL", rc, m.RCode)
		}
		// tor answered, so tor is reported as working.
		if _, ok, _, _ := e.stats.Upstream(); !ok || e.stats.UpstreamErrors.Load() != 0 || e.stats.ServFail.Load() != 1 {
			t.Errorf("tor rcode %v: upstream ok=%v errors=%d servfail=%d", rc, ok, e.stats.UpstreamErrors.Load(), e.stats.ServFail.Load())
		}
	}

	e := newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		return reply(id, q, dnsmessage.RCodeNameError, nil), nil
	}
	if m := e.ask(t, query(8, "nowhere.example.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeNameError {
		t.Errorf("tor NXDOMAIN passed on as %v", m.RCode)
	}

	// A reply whose answer section is cut short.
	e = newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		r, _ := answerA(id, q)
		return r[:len(r)-3], nil
	}
	if m := e.ask(t, query(8, "example.org.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("cut reply: %v, want SERVFAIL", m.RCode)
	}
	if _, ok, code, _ := e.stats.Upstream(); ok || code != "malformed" || e.stats.UpstreamErrors.Load() != 1 {
		t.Errorf("cut reply: upstream ok=%v code=%q errors=%d", ok, code, e.stats.UpstreamErrors.Load())
	}

	// A reply to another question (the match function rejects it).
	e = newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		q.Name = dnsmessage.MustNewName("other.example.")
		return answerA(id, q)
	}
	if m := e.ask(t, query(8, "example.org.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("reply to another question: %v, want SERVFAIL", m.RCode)
	}
	// A reply with another ID.
	e = newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) { return answerA(id+1, q) }
	if m := e.ask(t, query(8, "example.org.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeServerFailure {
		t.Errorf("reply with another ID: %v, want SERVFAIL", m.RCode)
	}
}

func TestReplyMatchIgnoresCase(t *testing.T) {
	e := newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		q.Name = dnsmessage.MustNewName(strings.ToUpper(q.Name.String()))
		return answerA(id, q)
	}
	if m := e.ask(t, query(8, "example.org.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("%v", m.RCode)
	}
}

func TestCNAMEToBlockedName(t *testing.T) {
	e := newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		return reply(id, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
			b.CNAMEResource(rr(q.Name.String(), dnsmessage.TypeCNAME), dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("x.Doubleclick.net.")})
			b.AResource(rr("x.doubleclick.net.", dnsmessage.TypeA), dnsmessage.AResource{A: [4]byte{192, 0, 2, 9}})
		}), nil
	}
	m := e.ask(t, query(10, "metrics.shop.example.", dnsmessage.TypeA), MaxUDPSize)
	if m.RCode != dnsmessage.RCodeNameError || len(m.Answers) != 0 {
		t.Errorf("cloaked tracker: %v with %d answers, want NXDOMAIN", m.RCode, len(m.Answers))
	}
	if e.stats.Blocked.Load() != 1 || e.stats.Forwarded.Load() != 0 {
		t.Errorf("blocked=%d forwarded=%d", e.stats.Blocked.Load(), e.stats.Forwarded.Load())
	}

	// A CNAME to an allowed name is passed on.
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		return reply(id, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
			b.CNAMEResource(rr(q.Name.String(), dnsmessage.TypeCNAME), dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("cdn.example.net.")})
			b.AResource(rr("cdn.example.net.", dnsmessage.TypeA), dnsmessage.AResource{A: [4]byte{192, 0, 2, 9}})
		}), nil
	}
	if m := e.ask(t, query(10, "www.shop.example.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 2 {
		t.Errorf("CNAME chain: %+v", m)
	}
}

func TestTruncation(t *testing.T) {
	e := newEnv(t, nil)
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		return reply(id, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
			for i := 0; i < 40; i++ {
				b.AResource(rr(q.Name.String(), dnsmessage.TypeA), dnsmessage.AResource{A: [4]byte{192, 0, 2, byte(i)}})
			}
		}), nil
	}
	name := strings.Repeat("a", 60) + "." + strings.Repeat("b", 60) + ".example."
	m := e.ask(t, query(11, name, dnsmessage.TypeA), MaxUDPSize)
	if !m.Truncated || len(m.Answers) != 0 || len(m.Questions) != 1 || m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("UDP: truncated=%v answers=%d questions=%d", m.Truncated, len(m.Answers), len(m.Questions))
	}
	m = e.ask(t, query(11, name, dnsmessage.TypeA), MaxTCPSize)
	if m.Truncated || len(m.Answers) != maxAnswers {
		t.Errorf("TCP: truncated=%v answers=%d, want %d", m.Truncated, len(m.Answers), maxAnswers)
	}
}

func TestOverload(t *testing.T) {
	release := make(chan struct{})
	entered := make(chan struct{}, 1)
	e := newEnv(t, func(c *Config) { c.MaxInflight = 1 })
	e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
		entered <- struct{}{}
		<-release
		return answerA(id, q)
	}
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		e.h.Handle(context.Background(), query(1, "slow.example.", dnsmessage.TypeA), MaxUDPSize)
	}()
	<-entered
	start := time.Now()
	m := e.ask(t, query(2, "second.example.", dnsmessage.TypeA), MaxUDPSize)
	if m.RCode != dnsmessage.RCodeServerFailure || time.Since(start) > time.Second {
		t.Errorf("overload: %v after %v, want an immediate SERVFAIL", m.RCode, time.Since(start))
	}
	// Blocked names are still answered while tor is busy.
	if m := e.ask(t, query(3, "tracker.example.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeNameError {
		t.Errorf("blocked name while overloaded: %v", m.RCode)
	}
	close(release)
	wg.Wait()
}

func TestDebugLogOnlyWhenAsked(t *testing.T) {
	var lines []string
	e := newEnv(t, func(c *Config) {
		c.Debugf = func(f string, a ...any) { lines = append(lines, fmt.Sprintf(f, a...)) }
	})
	e.ask(t, query(1, "secret-name.example.", dnsmessage.TypeA), MaxUDPSize)
	e.ask(t, query(1, "tracker.example.", dnsmessage.TypeA), MaxUDPSize)
	if len(lines) != 2 || !strings.Contains(lines[0], "secret-name.example.") || !strings.Contains(lines[1], "blocked") {
		t.Errorf("debug lines %q", lines)
	}
}

func TestListSwap(t *testing.T) {
	var cur atomic.Pointer[blocklist.List]
	e := newEnv(t, func(c *Config) { c.List = cur.Load })
	if m := e.ask(t, query(1, "tracker.example.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeSuccess {
		t.Errorf("without a list: %v", m.RCode)
	}
	cur.Store(testList(t))
	if m := e.ask(t, query(1, "tracker.example.", dnsmessage.TypeA), MaxUDPSize); m.RCode != dnsmessage.RCodeNameError {
		t.Errorf("after loading a list: %v", m.RCode)
	}
}
