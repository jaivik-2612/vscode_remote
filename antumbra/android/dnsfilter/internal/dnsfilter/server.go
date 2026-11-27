package dnsfilter

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"sync"
	"time"
)

// ServerConfig sets the listeners' limits.
type ServerConfig struct {
	Handler *Handler
	Limiter *Limiter // per client port; nil: no limit
	Stats   *Stats
	// MaxWorkers caps UDP queries being handled at once; more are dropped.
	MaxWorkers int
	// MaxTCPConns caps open TCP connections; more are closed at once.
	MaxTCPConns int
	// TCPIdle is how long a TCP connection may wait between queries.
	TCPIdle time.Duration
	// Logf receives errors. It never gets a name or a client address.
	Logf func(format string, args ...any)
}

// Server serves DNS on UDP and TCP on the same loopback address.
type Server struct {
	cfg     ServerConfig
	udp     *net.UDPConn
	tcp     *net.TCPListener
	addr    netip.AddrPort
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	workers chan struct{}
	conns   chan struct{}
}

// maxQueriesPerConn closes a TCP connection after this many queries, so
// that one connection cannot hold a slot for ever.
const maxQueriesPerConn = 1000

// Listen binds UDP and TCP sockets on addr, which must be an IPv4
// loopback address: the filter never answers anything but the phone
// itself. With port 0, both sockets get the same free port.
//
// The UDP socket is bound without SO_REUSEADDR, so no other process can
// bind the same address and port next to it and read queries meant for
// the filter.
func Listen(addr netip.AddrPort, cfg ServerConfig) (*Server, error) {
	if !addr.Addr().Is4() || !addr.Addr().IsLoopback() {
		return nil, fmt.Errorf("listen address %s is not an IPv4 loopback address", addr)
	}
	if cfg.Handler == nil || cfg.Stats == nil {
		return nil, errors.New("server: Handler and Stats are required")
	}
	if cfg.MaxWorkers < 1 {
		cfg.MaxWorkers = 256
	}
	if cfg.MaxTCPConns < 1 {
		cfg.MaxTCPConns = 64
	}
	if cfg.TCPIdle <= 0 {
		cfg.TCPIdle = 10 * time.Second
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	var lastErr error
	for try := 0; try < 10; try++ {
		u, err := net.ListenUDP("udp4", net.UDPAddrFromAddrPort(addr))
		if err != nil {
			return nil, err
		}
		bound := u.LocalAddr().(*net.UDPAddr).AddrPort()
		t, err := net.ListenTCP("tcp4", net.TCPAddrFromAddrPort(bound))
		if err != nil {
			u.Close()
			lastErr = err
			if addr.Port() != 0 {
				return nil, err
			}
			continue // the free UDP port was taken for TCP; pick another
		}
		ctx, cancel := context.WithCancel(context.Background())
		return &Server{
			cfg: cfg, udp: u, tcp: t, addr: bound, ctx: ctx, cancel: cancel,
			workers: make(chan struct{}, cfg.MaxWorkers),
			conns:   make(chan struct{}, cfg.MaxTCPConns),
		}, nil
	}
	return nil, lastErr
}

// Addr returns the bound address.
func (s *Server) Addr() netip.AddrPort { return s.addr }

// Serve starts answering on both sockets. It returns at once.
func (s *Server) Serve() {
	s.wg.Add(2)
	go s.serveUDP()
	go s.serveTCP()
}

// Close stops both listeners and waits for queries being answered.
func (s *Server) Close() {
	s.cancel()
	s.udp.Close()
	s.tcp.Close()
	s.wg.Wait()
}

func (s *Server) recover(where string) {
	if r := recover(); r != nil {
		// A bug, not an attack we can tolerate silently; the query is
		// dropped and the process goes on serving the others.
		s.cfg.Stats.Dropped.Add(1)
		s.cfg.Logf("internal error in %s: %v", where, r)
	}
}

func (s *Server) serveUDP() {
	defer s.wg.Done()
	buf := make([]byte, 65535)
	for {
		n, from, err := s.udp.ReadFromUDPAddrPort(buf)
		if err != nil {
			if s.ctx.Err() != nil {
				return
			}
			s.cfg.Logf("udp read: %v", err)
			time.Sleep(10 * time.Millisecond)
			continue
		}
		if !s.cfg.Limiter.Allow(from) {
			s.cfg.Stats.RateLimited.Add(1)
			continue
		}
		select {
		case s.workers <- struct{}{}:
		default:
			s.cfg.Stats.Dropped.Add(1)
			continue
		}
		msg := append([]byte(nil), buf[:n]...)
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer func() { <-s.workers }()
			defer s.recover("udp")
			if resp := s.cfg.Handler.Handle(s.ctx, msg, MaxUDPSize); resp != nil {
				s.udp.WriteToUDPAddrPort(resp, from)
			}
		}()
	}
}

func (s *Server) serveTCP() {
	defer s.wg.Done()
	for {
		c, err := s.tcp.AcceptTCP()
		if err != nil {
			if s.ctx.Err() != nil {
				return
			}
			s.cfg.Logf("tcp accept: %v", err)
			time.Sleep(10 * time.Millisecond)
			continue
		}
		select {
		case s.conns <- struct{}{}:
		default:
			s.cfg.Stats.Dropped.Add(1)
			c.Close()
			continue
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer func() { <-s.conns }()
			defer c.Close()
			defer s.recover("tcp")
			stop := context.AfterFunc(s.ctx, func() { c.SetDeadline(time.Unix(1, 0)) })
			defer stop()
			s.serveConn(c)
		}()
	}
}

// serveConn answers the queries on one TCP connection in order. Each
// message is preceded by its length in two bytes (RFC 1035 4.2.2).
func (s *Server) serveConn(c *net.TCPConn) {
	from := c.RemoteAddr().(*net.TCPAddr).AddrPort()
	var l [2]byte
	for i := 0; i < maxQueriesPerConn; i++ {
		c.SetReadDeadline(time.Now().Add(s.cfg.TCPIdle))
		if _, err := io.ReadFull(c, l[:]); err != nil {
			return
		}
		n := int(binary.BigEndian.Uint16(l[:]))
		if n < 12 {
			s.cfg.Stats.Dropped.Add(1)
			return
		}
		msg := make([]byte, n)
		c.SetReadDeadline(time.Now().Add(5 * time.Second))
		if _, err := io.ReadFull(c, msg); err != nil {
			return
		}
		if !s.cfg.Limiter.Allow(from) {
			s.cfg.Stats.RateLimited.Add(1)
			return
		}
		resp := s.cfg.Handler.Handle(s.ctx, msg, MaxTCPSize)
		if resp == nil {
			return
		}
		out := make([]byte, 2+len(resp))
		binary.BigEndian.PutUint16(out, uint16(len(resp)))
		copy(out[2:], resp)
		c.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if _, err := c.Write(out); err != nil {
			return
		}
	}
}
