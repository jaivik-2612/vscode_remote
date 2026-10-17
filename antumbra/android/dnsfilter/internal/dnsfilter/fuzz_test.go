package dnsfilter

import (
	"context"
	"encoding/binary"
	"regexp"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

// forwardable is what a name sent to tor must look like: one or more labels
// of 1 to 63 bytes from [A-Za-z0-9_-], each followed by a dot, 254 bytes at
// most. It is written out here independently of PlainName, as the oracle
// for it.
var forwardable = regexp.MustCompile(`^(?:[A-Za-z0-9_-]{1,63}\.)+$`)

// FuzzHandle feeds arbitrary bytes to the query parser, as any app on the
// phone can. The handler must never panic, any answer must be a well-formed
// reply with the query's ID that fits in a UDP message, and every name that
// reaches tor must be a plain name (no NUL or other byte that tor or an
// exit could read differently from the filter).
func FuzzHandle(f *testing.F) {
	f.Add(query(1, "www.example.org.", dnsmessage.TypeA))
	f.Add(query(2, "a.tracker.example.", dnsmessage.TypeAAAA))
	f.Add(query(3, "printer.local.", dnsmessage.TypePTR))
	f.Add(query(4, "example.org.", dnsmessage.TypeALL))
	f.Add(queryClass(5, "version.bind.", dnsmessage.TypeTXT, 3))
	f.Add([]byte{0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1})
	f.Add([]byte{0, 1, 0x10, 0, 0, 2, 0, 0, 0, 0, 0, 0})
	f.Add([]byte{})
	f.Add(rawQuery(6, dnsmessage.TypeA, "doubleclick", "net\x00"))
	f.Add(rawQuery(7, dnsmessage.TypeA, "ads", "doubleclick", "net\x00x"))
	f.Add(rawQuery(8, dnsmessage.TypePTR, "1", "0", "0", "127", "in-addr", "arpa"))
	f.Add([]byte("00\x010\x00\x01000000\x00\x00\f\x00\x01")) // PTR for the root (found by fuzzing)
	e := newEnv(f, nil)
	f.Fuzz(func(t *testing.T, msg []byte) {
		e.up.fn = func(id uint16, q dnsmessage.Question) ([]byte, error) {
			if n := q.Name.String(); len(n) > 254 || !forwardable.MatchString(n) {
				t.Fatalf("name %q was sent to tor", n)
			}
			return answerA(id, q)
		}
		resp := e.h.Handle(context.Background(), msg, MaxUDPSize)
		if resp == nil {
			return
		}
		if len(resp) > MaxUDPSize {
			t.Fatalf("%d-byte UDP reply", len(resp))
		}
		var m dnsmessage.Message
		if err := m.Unpack(resp); err != nil {
			t.Fatalf("reply does not parse: %v", err)
		}
		if !m.Response || len(msg) < 2 || m.ID != binary.BigEndian.Uint16(msg) {
			t.Fatalf("reply header %+v for query %x", m.Header, msg)
		}
	})
}

// FuzzReply feeds arbitrary bytes as tor's reply. Whatever tor sends, the
// filter must not panic and must send the client a well-formed reply.
func FuzzReply(f *testing.F) {
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("www.example.org."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}
	good, _ := answerA(0, q)
	f.Add(good)
	f.Add(reply(0, q, dnsmessage.RCodeNameError, nil))
	f.Add(reply(0, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
		b.CNAMEResource(rr("www.example.org.", dnsmessage.TypeCNAME), dnsmessage.CNAMEResource{CNAME: dnsmessage.MustNewName("x.doubleclick.net.")})
	}))
	f.Add(reply(0, q, dnsmessage.RCodeSuccess, func(b *dnsmessage.Builder) {
		b.UnknownResource(rr("www.example.org.", dnsmessage.TypeHTTPS), dnsmessage.UnknownResource{Type: dnsmessage.TypeHTTPS, Data: []byte{0, 1, 0, 0, 1, 0, 3}})
	}))
	e := newEnv(f, nil)
	f.Fuzz(func(t *testing.T, r []byte) {
		e.up.fn = func(id uint16, _ dnsmessage.Question) ([]byte, error) {
			out := append([]byte(nil), r...)
			if len(out) >= 2 {
				binary.BigEndian.PutUint16(out, id) // let the ID match, so parsing goes deeper
			}
			return out, nil
		}
		resp := e.h.Handle(context.Background(), query(0x99, "www.example.org.", dnsmessage.TypeA), MaxUDPSize)
		var m dnsmessage.Message
		if err := m.Unpack(resp); err != nil {
			t.Fatalf("reply does not parse: %v", err)
		}
		if m.ID != 0x99 || len(resp) > MaxUDPSize {
			t.Fatalf("bad reply %+v", m.Header)
		}
	})
}
