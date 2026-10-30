package dnsfilter

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"strings"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
)

// BlockMode is how a blocked name is answered.
type BlockMode int

const (
	// BlockNXDOMAIN answers "no such name" for every type.
	BlockNXDOMAIN BlockMode = iota
	// BlockZero answers A with 0.0.0.0 and AAAA with ::, and other types
	// with an empty answer.
	BlockZero
)

func (m BlockMode) String() string {
	if m == BlockZero {
		return "zero"
	}
	return "nxdomain"
}

// Config sets the handler's policy.
type Config struct {
	// List returns the current block list (nil blocks nothing). It is
	// called once per query, so a list swapped in on SIGHUP applies from
	// the next query.
	List func() *blocklist.List
	// Upstream is tor's DNSPort. Nothing else is ever asked.
	Upstream Upstream
	// BlockMode and BlockedTTL shape blocked answers. BlockedTTL is also
	// the TTL of every other answer made here, and the negative-caching
	// time in their SOA record.
	BlockMode  BlockMode
	BlockedTTL uint32
	// FilterAAAA answers every AAAA query with an empty answer and drops
	// AAAA records from tor's replies. IPv6 is off on the phone; an IPv6
	// address would only make apps try a path that is closed.
	FilterAAAA bool
	// LocalNames answers names that only mean something on a local network
	// (".local", ".lan", "home.arpa", private reverse zones, ...) here, so
	// they never reach a Tor exit.
	LocalNames bool
	// MaxInflight caps queries waiting for tor; beyond it the answer is
	// SERVFAIL at once.
	MaxInflight int
	// Stats receives the counters. Required.
	Stats *Stats
	// Debugf, when set, receives one line per query with the name and the
	// decision. It is set only in the opt-in debug mode; nothing else in
	// this package ever passes a name to a logger.
	Debugf func(format string, args ...any)
}

// Handler answers DNS query messages.
type Handler struct {
	cfg      Config
	inflight chan struct{}
}

// NewHandler returns a handler for cfg.
func NewHandler(cfg Config) *Handler {
	if cfg.MaxInflight < 1 {
		cfg.MaxInflight = 1
	}
	if cfg.List == nil {
		cfg.List = func() *blocklist.List { return nil }
	}
	return &Handler{cfg: cfg, inflight: make(chan struct{}, cfg.MaxInflight)}
}

const (
	// MaxUDPSize is the largest reply sent over UDP. The filter does not
	// speak EDNS, so the classic limit applies; longer replies are sent
	// truncated (TC set) and the client asks again over TCP.
	MaxUDPSize = 512
	// MaxTCPSize is the largest reply sent over TCP.
	MaxTCPSize = 65535
	// maxAnswers caps the records copied from one reply of tor.
	maxAnswers = 32
)

var (
	soaNS   = dnsmessage.MustNewName("localhost.")
	soaMBox = dnsmessage.MustNewName("nobody.invalid.")
)

// result is what Handle decided before the reply is encoded.
type result struct {
	rcode   dnsmessage.RCode
	answers []dnsmessage.Resource
	soa     bool // add an SOA to the authority section (negative answers made here)
}

// Handle answers one query message. maxSize is the largest reply the
// transport carries (MaxUDPSize or MaxTCPSize). A nil result means the
// message gets no answer: it is not a query, or it is too broken to
// answer.
func (h *Handler) Handle(ctx context.Context, req []byte, maxSize int) []byte {
	st := h.cfg.Stats
	var p dnsmessage.Parser
	hdr, err := p.Start(req)
	if err != nil || hdr.Response {
		// Too short for a header, or a reply: never answer those, so no
		// two resolvers can be made to talk to each other in a loop.
		st.Dropped.Add(1)
		return nil
	}
	st.Queries.Add(1)
	if hdr.OpCode != 0 {
		st.NotImp.Add(1)
		return h.encode(hdr, nil, result{rcode: dnsmessage.RCodeNotImplemented}, maxSize)
	}
	q, err := p.Question()
	if err != nil {
		st.FormErr.Add(1)
		return h.encode(hdr, nil, result{rcode: dnsmessage.RCodeFormatError}, maxSize)
	}
	if _, err := p.Question(); !errors.Is(err, dnsmessage.ErrSectionDone) {
		// More than one question: no resolver answers that.
		st.FormErr.Add(1)
		return h.encode(hdr, nil, result{rcode: dnsmessage.RCodeFormatError}, maxSize)
	}
	res, how := h.decide(ctx, q)
	if h.cfg.Debugf != nil {
		h.cfg.Debugf("query %q %s -> %s", q.Name.String(), typeName(q.Type), how)
	}
	return h.encode(hdr, &q, res, maxSize)
}

// decide applies the policy to one question. The second result is a short
// description for the debug log.
func (h *Handler) decide(ctx context.Context, q dnsmessage.Question) (result, string) {
	st := h.cfg.Stats
	if q.Class != dnsmessage.ClassINET {
		st.Refused.Add(1)
		return result{rcode: dnsmessage.RCodeRefused}, "refused (class)"
	}
	if refusedType(q.Type) {
		st.Refused.Add(1)
		return result{rcode: dnsmessage.RCodeRefused}, "refused (type)"
	}
	if !PlainName(q.Name.String()) {
		// A name with a byte outside letters, digits, '-' and '_' (a NUL,
		// a control byte, a space, UTF-8) matches no list entry, yet tor
		// reads names as C strings and cuts them at a NUL: "doubleclick" +
		// "net\x00" would be looked up as doubleclick.net at an exit. Such
		// a name is never forwarded and never matched; it does not exist.
		st.BadName.Add(1)
		return result{rcode: dnsmessage.RCodeNameError, soa: true}, "nxdomain (bad name)"
	}
	name := blocklist.Canonical(q.Name.String())
	if name == "" {
		// The root: it has no A, AAAA or PTR record, and tor's DNSPort
		// has nothing to say about it.
		st.Local.Add(1)
		return result{rcode: dnsmessage.RCodeSuccess, soa: true}, "empty (root)"
	}
	if h.cfg.LocalNames {
		if r, ok := h.local(q, name); ok {
			st.Local.Add(1)
			return r, "local"
		}
	}
	if blocked, _ := h.cfg.List().Match(name); blocked {
		st.Blocked.Add(1)
		return h.blocked(q), "blocked"
	}
	switch {
	case q.Type == dnsmessage.TypeAAAA && h.cfg.FilterAAAA,
		!forwardedType(q.Type):
		// tor's DNSPort answers only A, AAAA and PTR (anything else gets
		// NOTIMP, which resolvers retry). An empty answer lets apps go on
		// with the A record at once.
		st.Local.Add(1)
		return result{rcode: dnsmessage.RCodeSuccess, soa: true}, "empty (type)"
	}
	return h.forward(ctx, q)
}

func (h *Handler) blocked(q dnsmessage.Question) result {
	if h.cfg.BlockMode == BlockNXDOMAIN {
		return result{rcode: dnsmessage.RCodeNameError, soa: true}
	}
	rh := dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: h.cfg.BlockedTTL}
	switch q.Type {
	case dnsmessage.TypeA:
		rh.Type = dnsmessage.TypeA
		return result{answers: []dnsmessage.Resource{{Header: rh, Body: &dnsmessage.AResource{}}}}
	case dnsmessage.TypeAAAA:
		rh.Type = dnsmessage.TypeAAAA
		return result{answers: []dnsmessage.Resource{{Header: rh, Body: &dnsmessage.AAAAResource{}}}}
	}
	return result{rcode: dnsmessage.RCodeSuccess, soa: true}
}

// refusedType reports whether a question type is refused outright: zone
// transfers, ANY, and the other query-only and meta types (RFC 6895),
// OPT among them.
func refusedType(t dnsmessage.Type) bool {
	return t == 0 || t == dnsmessage.TypeOPT || t >= 128 && t <= 255
}

// forwardedType reports whether tor's DNSPort can answer a question type.
func forwardedType(t dnsmessage.Type) bool {
	return t == dnsmessage.TypeA || t == dnsmessage.TypeAAAA || t == dnsmessage.TypePTR
}

// forward asks tor and turns its reply into the answer. Every failure is
// SERVFAIL: the query is never sent anywhere else.
func (h *Handler) forward(ctx context.Context, q dnsmessage.Question) (result, string) {
	st := h.cfg.Stats
	servfail := func(code string) (result, string) {
		st.ServFail.Add(1)
		return result{rcode: dnsmessage.RCodeServerFailure}, "servfail (" + code + ")"
	}
	select {
	case h.inflight <- struct{}{}:
		defer func() { <-h.inflight }()
	default:
		st.UpstreamErrors.Add(1)
		return servfail(ErrOverload.Error())
	}

	// A fresh query with its own random ID and only the question: nothing
	// else the client put in its message reaches tor.
	var idb [2]byte
	if _, err := rand.Read(idb[:]); err != nil {
		return servfail("rand")
	}
	id := binary.BigEndian.Uint16(idb[:])
	b := dnsmessage.NewBuilder(make([]byte, 0, 64), dnsmessage.Header{ID: id, RecursionDesired: true})
	if b.StartQuestions() != nil || b.Question(q) != nil {
		return servfail("build")
	}
	query, err := b.Finish()
	if err != nil {
		return servfail("build")
	}
	match := func(m []byte) bool { return isReplyTo(m, id, q) }

	reply, err := h.cfg.Upstream.Exchange(ctx, query, match)
	if err != nil {
		st.UpstreamErrors.Add(1)
		code := ErrUpstreamIO.Error()
		for _, e := range []error{ErrUpstreamDown, ErrUpstreamTimeout, ErrUpstreamOwner,
			ErrOwnerUnknown, ErrUpstreamReply} {
			if errors.Is(err, e) {
				code = e.Error()
			}
		}
		st.noteUpstream(false, code)
		return servfail(code)
	}
	res, how := h.fromReply(reply)
	if how == "malformed" {
		st.UpstreamErrors.Add(1)
		st.noteUpstream(false, ErrUpstreamReply.Error())
		return servfail(how)
	}
	// tor answered. A SERVFAIL, REFUSED or NOTIMP from it is passed on as
	// SERVFAIL, but tor itself is working.
	st.noteUpstream(true, "")
	if res.rcode == dnsmessage.RCodeServerFailure {
		return servfail(how)
	}
	if how == "blocked" {
		st.Blocked.Add(1)
		return h.blocked(q), "blocked (cname)"
	}
	st.Forwarded.Add(1)
	return res, how
}

// isReplyTo reports whether m is tor's reply to the query with this ID and
// question. The name is compared without regard to letter case.
func isReplyTo(m []byte, id uint16, q dnsmessage.Question) bool {
	var p dnsmessage.Parser
	h, err := p.Start(m)
	if err != nil || !h.Response || h.ID != id || h.OpCode != 0 {
		return false
	}
	rq, err := p.Question()
	if err != nil {
		return false
	}
	return rq.Type == q.Type && rq.Class == q.Class && strings.EqualFold(rq.Name.String(), q.Name.String())
}

// fromReply copies the A, AAAA, PTR and CNAME records of tor's reply. A
// CNAME that points at a blocked name makes the whole answer blocked
// (tor's DNSPort itself never sends CNAMEs; this guards against any
// upstream that does). The second result is "blocked" in that case, else a
// short description.
func (h *Handler) fromReply(m []byte) (result, string) {
	var p dnsmessage.Parser
	rh, err := p.Start(m)
	if err != nil || p.SkipAllQuestions() != nil {
		return result{rcode: dnsmessage.RCodeServerFailure}, "malformed"
	}
	if rh.RCode != dnsmessage.RCodeSuccess && rh.RCode != dnsmessage.RCodeNameError {
		return result{rcode: dnsmessage.RCodeServerFailure}, "rcode " + rh.RCode.String()
	}
	res := result{rcode: rh.RCode}
	list := h.cfg.List()
	for len(res.answers) < maxAnswers {
		ah, err := p.AnswerHeader()
		if errors.Is(err, dnsmessage.ErrSectionDone) {
			break
		}
		if err != nil {
			return result{rcode: dnsmessage.RCodeServerFailure}, "malformed"
		}
		var body dnsmessage.ResourceBody
		switch {
		case ah.Class != dnsmessage.ClassINET:
			err = p.SkipAnswer()
		case ah.Type == dnsmessage.TypeA:
			var r dnsmessage.AResource
			r, err = p.AResource()
			body = &r
		case ah.Type == dnsmessage.TypeAAAA:
			var r dnsmessage.AAAAResource
			r, err = p.AAAAResource()
			if !h.cfg.FilterAAAA {
				body = &r
			}
		case ah.Type == dnsmessage.TypePTR:
			var r dnsmessage.PTRResource
			r, err = p.PTRResource()
			body = &r
		case ah.Type == dnsmessage.TypeCNAME:
			var r dnsmessage.CNAMEResource
			r, err = p.CNAMEResource()
			if err == nil {
				// A target that is not a plain name cannot be matched
				// reliably, so it counts as blocked.
				target := r.CNAME.String()
				if !PlainName(target) {
					return result{}, "blocked"
				}
				if blocked, _ := list.Match(target); blocked {
					return result{}, "blocked"
				}
			}
			body = &r
		default:
			err = p.SkipAnswer()
		}
		if err != nil {
			return result{rcode: dnsmessage.RCodeServerFailure}, "malformed"
		}
		if body != nil {
			res.answers = append(res.answers, dnsmessage.Resource{Header: ah, Body: body})
		}
	}
	if rh.RCode == dnsmessage.RCodeNameError {
		return res, "forwarded nxdomain"
	}
	return res, "forwarded"
}

// encode builds the reply to the client: its ID, its RD bit and its
// question as it sent it (letter case included).
func (h *Handler) encode(qh dnsmessage.Header, q *dnsmessage.Question, r result, maxSize int) []byte {
	hdr := dnsmessage.Header{
		ID:                 qh.ID,
		Response:           true,
		OpCode:             qh.OpCode,
		RecursionDesired:   qh.RecursionDesired,
		RecursionAvailable: true,
		RCode:              r.rcode,
	}
	msg, err := h.build(hdr, q, r)
	if err != nil {
		// Should not happen (every name came from a parsed message); answer
		// SERVFAIL rather than nothing.
		h.cfg.Stats.ServFail.Add(1)
		hdr.RCode = dnsmessage.RCodeServerFailure
		msg, err = h.build(hdr, q, result{rcode: dnsmessage.RCodeServerFailure})
		if err != nil {
			return nil
		}
	}
	if len(msg) > maxSize {
		// Too long for this transport: header and question only, with TC.
		hdr.Truncated = true
		msg, err = h.build(hdr, q, result{rcode: r.rcode})
		if err != nil || len(msg) > maxSize {
			return nil
		}
	}
	return msg
}

func (h *Handler) build(hdr dnsmessage.Header, q *dnsmessage.Question, r result) ([]byte, error) {
	b := dnsmessage.NewBuilder(make([]byte, 0, 128), hdr)
	b.EnableCompression()
	if err := b.StartQuestions(); err != nil {
		return nil, err
	}
	if q != nil {
		if err := b.Question(*q); err != nil {
			return nil, err
		}
	}
	if err := b.StartAnswers(); err != nil {
		return nil, err
	}
	for _, a := range r.answers {
		var err error
		switch body := a.Body.(type) {
		case *dnsmessage.AResource:
			err = b.AResource(a.Header, *body)
		case *dnsmessage.AAAAResource:
			err = b.AAAAResource(a.Header, *body)
		case *dnsmessage.PTRResource:
			err = b.PTRResource(a.Header, *body)
		case *dnsmessage.CNAMEResource:
			err = b.CNAMEResource(a.Header, *body)
		default:
			err = errors.New("unexpected record type")
		}
		if err != nil {
			return nil, err
		}
	}
	if r.soa && q != nil {
		if err := b.StartAuthorities(); err != nil {
			return nil, err
		}
		ttl := h.cfg.BlockedTTL
		err := b.SOAResource(
			dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: ttl},
			dnsmessage.SOAResource{NS: soaNS, MBox: soaMBox, Serial: 1,
				Refresh: 3600, Retry: 600, Expire: 86400, MinTTL: ttl})
		if err != nil {
			return nil, err
		}
	}
	return b.Finish()
}

// PlainName reports whether a DNS name in presentation form (as
// dnsmessage.Name.String gives it, with or without the final dot) is made
// only of labels of 1 to 63 bytes from [A-Za-z0-9_-], separated by dots, at
// most 253 bytes in all. The root name (an empty name) is plain. Only plain
// names are matched against the lists and forwarded to tor: any other byte
// (NUL and the other control bytes above all) could make tor, or the exit's
// resolver, read a different name than the one the filter matched.
func PlainName(s string) bool {
	if len(s) > 0 && s[len(s)-1] == '.' {
		s = s[:len(s)-1]
	}
	if len(s) > 253 {
		return false
	}
	if s == "" {
		return true
	}
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == '.' {
			if n := i - start; n == 0 || n > 63 {
				return false
			}
			start = i + 1
			continue
		}
		c := s[i]
		if !('a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

func typeName(t dnsmessage.Type) string {
	s := t.String()
	return strings.TrimPrefix(s, "Type")
}
