package dnsfilter

import (
	"context"
	"encoding/binary"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

// FuzzHandle feeds arbitrary bytes to the query parser, as any app on the
// phone can. The handler must never panic, and any answer must be a
// well-formed reply with the query's ID that fits in a UDP message.
func FuzzHandle(f *testing.F) {
	f.Add(query(1, "www.example.org.", dnsmessage.TypeA))
	f.Add(query(2, "a.tracker.example.", dnsmessage.TypeAAAA))
	f.Add(query(3, "printer.local.", dnsmessage.TypePTR))
	f.Add(query(4, "example.org.", dnsmessage.TypeALL))
	f.Add(queryClass(5, "version.bind.", dnsmessage.TypeTXT, 3))
	f.Add([]byte{0, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1})
	f.Add([]byte{0, 1, 0x10, 0, 0, 2, 0, 0, 0, 0, 0, 0})
	f.Add([]byte{})
	e := newEnv(f, nil)
	f.Fuzz(func(t *testing.T, msg []byte) {
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
