// Package fakedns is a small DNS server that stands in for tor's DNSPort
// in the tests and in antumbra-dnsfilter's -self-test. It answers like
// tor: A, AAAA and PTR only, NOTIMP for everything else.
package fakedns

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// DefaultA is the address given for every name without its own entry.
var DefaultA = netip.MustParseAddr("192.0.2.53")

// Server is a fake upstream on 127.0.0.1, UDP and (optionally) TCP. Its
// behaviour is changed with the Set methods, which are safe to call while
// it serves.
type Server struct {
	mu         sync.Mutex
	nx         map[string]bool   // names answered NXDOMAIN
	cname      map[string]string // name -> target; then an A for the target
	delay      time.Duration     // wait this long before answering
	truncate   bool              // set TC on UDP replies (forces TCP)
	wrongFirst bool              // send a reply with a wrong ID first
	rcode      dnsmessage.RCode  // if not 0, answer every query with it

	queries atomic.Int64
	seenMu  sync.Mutex
	seen    []string

	udp  *net.UDPConn
	tcp  *net.TCPListener
	addr netip.AddrPort
	wg   sync.WaitGroup
}

// Start starts a server on a free loopback port. With withTCP it also
// listens on TCP on the same port.
func Start(withTCP bool) (*Server, error) {
	for try := 0; try < 10; try++ {
		u, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			return nil, err
		}
		s := &Server{udp: u, addr: u.LocalAddr().(*net.UDPAddr).AddrPort(),
			nx: map[string]bool{}, cname: map[string]string{}}
		if withTCP {
			t, err := net.ListenTCP("tcp4", net.TCPAddrFromAddrPort(s.addr))
			if err != nil {
				u.Close()
				continue
			}
			s.tcp = t
		}
		s.wg.Add(1)
		go s.serveUDP()
		if s.tcp != nil {
			s.wg.Add(1)
			go s.serveTCP()
		}
		return s, nil
	}
	return nil, errors.New("fakedns: no free port")
}

// SetNX makes the server answer NXDOMAIN for name (lower case, no dot).
func (s *Server) SetNX(name string) { s.mu.Lock(); s.nx[name] = true; s.mu.Unlock() }

// SetCNAME makes the server answer name with a CNAME to target, then an A.
func (s *Server) SetCNAME(name, target string) { s.mu.Lock(); s.cname[name] = target; s.mu.Unlock() }

// SetDelay makes the server wait d before each answer.
func (s *Server) SetDelay(d time.Duration) { s.mu.Lock(); s.delay = d; s.mu.Unlock() }

// SetTruncate makes UDP replies carry TC and no answers.
func (s *Server) SetTruncate(v bool) { s.mu.Lock(); s.truncate = v; s.mu.Unlock() }

// SetWrongFirst makes the server send a reply with a wrong ID first.
func (s *Server) SetWrongFirst(v bool) { s.mu.Lock(); s.wrongFirst = v; s.mu.Unlock() }

// SetRCode makes the server answer every query with rcode (0: normal).
func (s *Server) SetRCode(rc dnsmessage.RCode) { s.mu.Lock(); s.rcode = rc; s.mu.Unlock() }

// Addr returns the server's address.
func (s *Server) Addr() netip.AddrPort { return s.addr }

// Queries returns how many queries the server received.
func (s *Server) Queries() int64 { return s.queries.Load() }

// Seen returns the names asked so far (lower case, no trailing dot).
func (s *Server) Seen() []string {
	s.seenMu.Lock()
	defer s.seenMu.Unlock()
	return append([]string(nil), s.seen...)
}

// Close stops the server. Afterwards the port refuses queries.
func (s *Server) Close() {
	s.udp.Close()
	if s.tcp != nil {
		s.tcp.Close()
	}
	s.wg.Wait()
}

func (s *Server) serveUDP() {
	defer s.wg.Done()
	buf := make([]byte, 65535)
	for {
		n, from, err := s.udp.ReadFromUDPAddrPort(buf)
		if err != nil {
			return
		}
		msg := append([]byte(nil), buf[:n]...)
		go func() {
			s.mu.Lock()
			wrong, trunc := s.wrongFirst, s.truncate
			s.mu.Unlock()
			resp := s.answer(msg, trunc)
			if resp == nil {
				return
			}
			if wrong {
				bad := append([]byte(nil), resp...)
				bad[0] ^= 0xff
				s.udp.WriteToUDPAddrPort(bad, from)
			}
			s.udp.WriteToUDPAddrPort(resp, from)
		}()
	}
}

func (s *Server) serveTCP() {
	defer s.wg.Done()
	for {
		c, err := s.tcp.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			c.SetDeadline(time.Now().Add(10 * time.Second))
			var l [2]byte
			for {
				if _, err := io.ReadFull(c, l[:]); err != nil {
					return
				}
				msg := make([]byte, binary.BigEndian.Uint16(l[:]))
				if _, err := io.ReadFull(c, msg); err != nil {
					return
				}
				resp := s.answer(msg, false)
				if resp == nil {
					return
				}
				out := binary.BigEndian.AppendUint16(nil, uint16(len(resp)))
				if _, err := c.Write(append(out, resp...)); err != nil {
					return
				}
			}
		}()
	}
}

func (s *Server) answer(msg []byte, truncate bool) []byte {
	var p dnsmessage.Parser
	h, err := p.Start(msg)
	if err != nil {
		return nil
	}
	q, err := p.Question()
	if err != nil {
		return nil
	}
	s.queries.Add(1)
	name := strings.ToLower(strings.TrimSuffix(q.Name.String(), "."))
	s.seenMu.Lock()
	s.seen = append(s.seen, name)
	s.seenMu.Unlock()

	s.mu.Lock()
	delay, rcode := s.delay, s.rcode
	nx := s.nx[name]
	target, isCNAME := s.cname[name]
	s.mu.Unlock()
	a := DefaultA
	if delay > 0 {
		time.Sleep(delay)
	}

	rh := dnsmessage.Header{ID: h.ID, Response: true, RecursionDesired: h.RecursionDesired,
		RecursionAvailable: true, Truncated: truncate}
	switch {
	case rcode != 0:
		rh.RCode = rcode
	case nx:
		rh.RCode = dnsmessage.RCodeNameError
	case q.Type != dnsmessage.TypeA && q.Type != dnsmessage.TypeAAAA && q.Type != dnsmessage.TypePTR:
		rh.RCode = dnsmessage.RCodeNotImplemented
	}
	b := dnsmessage.NewBuilder(nil, rh)
	b.EnableCompression()
	b.StartQuestions()
	b.Question(q)
	b.StartAnswers()
	if rh.RCode == 0 && !truncate {
		owner := q.Name
		if isCNAME {
			t := dnsmessage.MustNewName(target + ".")
			b.CNAMEResource(dnsmessage.ResourceHeader{Name: owner, Class: dnsmessage.ClassINET, TTL: 60},
				dnsmessage.CNAMEResource{CNAME: t})
			owner = t
		}
		rr := dnsmessage.ResourceHeader{Name: owner, Class: dnsmessage.ClassINET, TTL: 60}
		switch q.Type {
		case dnsmessage.TypeA:
			b.AResource(rr, dnsmessage.AResource{A: a.As4()})
		case dnsmessage.TypeAAAA:
			b.AAAAResource(rr, dnsmessage.AAAAResource{AAAA: netip.MustParseAddr("2001:db8::53").As16()})
		case dnsmessage.TypePTR:
			b.PTRResource(rr, dnsmessage.PTRResource{PTR: dnsmessage.MustNewName("host.example.")})
		}
	}
	out, err := b.Finish()
	if err != nil {
		return nil
	}
	return out
}
