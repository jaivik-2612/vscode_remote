package dnsfilter

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"syscall"
	"time"
)

// Upstream sends a query to tor and returns the reply. match reports
// whether a received message is the reply to this query (same ID and
// question); others are ignored.
type Upstream interface {
	Exchange(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error)
}

// Upstream errors. Their texts are the short codes shown on the status
// page, so they never carry names or addresses.
var (
	ErrUpstreamDown    = errors.New("refused") // nothing listens on the port
	ErrUpstreamTimeout = errors.New("timeout") // no matching reply in time
	ErrUpstreamOwner   = errors.New("owner")   // the port is held by a uid other than tor's
	ErrOwnerUnknown    = errors.New("owner-unknown")
	ErrUpstreamIO      = errors.New("io")        // any other socket error
	ErrUpstreamReply   = errors.New("malformed") // a reply that is not a DNS reply
	ErrOverload        = errors.New("overload")  // too many queries waiting for tor
)

// Loopback is the only upstream: tor's DNSPort on a loopback address.
// There is no fallback server. When tor does not answer, the query fails.
type Loopback struct {
	addr    netip.AddrPort
	network string // "udp" or "tcp"
	timeout time.Duration
	// ownerUID, when 0 or more, is the uid that must own every socket
	// bound to the upstream port on 127.0.0.1 or the wildcard address.
	ownerUID int
	procNet  string
}

// NewLoopback checks and returns the upstream. The address must be a
// loopback address: the filter never sends a query off the phone.
func NewLoopback(addr netip.AddrPort, network string, timeout time.Duration, ownerUID int) (*Loopback, error) {
	if !addr.Addr().Unmap().IsLoopback() || !addr.Addr().Unmap().Is4() {
		return nil, fmt.Errorf("upstream %s is not an IPv4 loopback address", addr)
	}
	if addr.Port() == 0 {
		return nil, errors.New("upstream port is 0")
	}
	if network != "udp" && network != "tcp" {
		return nil, fmt.Errorf("upstream network %q is not udp or tcp", network)
	}
	if timeout <= 0 {
		return nil, errors.New("upstream timeout must be positive")
	}
	return &Loopback{
		addr:     netip.AddrPortFrom(addr.Addr().Unmap(), addr.Port()),
		network:  network,
		timeout:  timeout,
		ownerUID: ownerUID,
		procNet:  "/proc/net",
	}, nil
}

// SetProcNet changes where the owner check reads the socket tables (tests).
func (u *Loopback) SetProcNet(dir string) { u.procNet = dir }

// Addr returns the upstream address.
func (u *Loopback) Addr() netip.AddrPort { return u.addr }

// Network returns "udp" or "tcp".
func (u *Loopback) Network() string { return u.network }

// OwnerUID returns the uid the upstream port must belong to, or -1.
func (u *Loopback) OwnerUID() int { return u.ownerUID }

// Exchange implements Upstream. Over UDP, a reply with the TC bit set is
// asked again over TCP, once.
func (u *Loopback) Exchange(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, u.timeout)
	defer cancel()
	if u.network == "tcp" {
		return u.exchangeTCP(ctx, query, match)
	}
	resp, err := u.exchangeUDP(ctx, query, match)
	if err == nil && len(resp) > 2 && resp[2]&0x02 != 0 {
		return u.exchangeTCP(ctx, query, match)
	}
	return resp, err
}

func (u *Loopback) checkOwner(proto string) error {
	if u.ownerUID < 0 {
		return nil
	}
	owners, err := portOwners(u.procNet, proto, u.addr.Port())
	if err != nil {
		return ErrOwnerUnknown
	}
	if len(owners) == 0 {
		return ErrUpstreamDown
	}
	for _, o := range owners {
		if o != u.ownerUID {
			return ErrUpstreamOwner
		}
	}
	return nil
}

func (u *Loopback) exchangeUDP(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error) {
	if err := u.checkOwner("udp"); err != nil {
		return nil, err
	}
	// A connected socket on a fresh random port: the kernel delivers only
	// datagrams from the upstream address and port to it.
	c, err := net.DialUDP("udp4", nil, net.UDPAddrFromAddrPort(u.addr))
	if err != nil {
		return nil, classify(err)
	}
	defer c.Close()
	deadline, _ := ctx.Deadline()
	if err := c.SetDeadline(deadline); err != nil {
		return nil, ErrUpstreamIO
	}
	stop := context.AfterFunc(ctx, func() { c.SetDeadline(time.Unix(1, 0)) })
	defer stop()
	if _, err := c.Write(query); err != nil {
		return nil, classify(err)
	}
	buf := make([]byte, 65535)
	for {
		n, err := c.Read(buf)
		if err != nil {
			return nil, classify(err)
		}
		if match(buf[:n]) {
			// Check again: a socket bound next to tor's after the first
			// check would have received the query and could have sent this
			// reply.
			if err := u.checkOwner("udp"); err != nil {
				return nil, err
			}
			return append([]byte(nil), buf[:n]...), nil
		}
		// Not our reply (a late answer to an earlier query, or junk): keep
		// waiting until the deadline.
	}
}

func (u *Loopback) exchangeTCP(ctx context.Context, query []byte, match func([]byte) bool) ([]byte, error) {
	if err := u.checkOwner("tcp"); err != nil {
		return nil, err
	}
	var d net.Dialer
	c, err := d.DialContext(ctx, "tcp4", u.addr.String())
	if err != nil {
		return nil, classify(err)
	}
	defer c.Close()
	deadline, _ := ctx.Deadline()
	if err := c.SetDeadline(deadline); err != nil {
		return nil, ErrUpstreamIO
	}
	stop := context.AfterFunc(ctx, func() { c.SetDeadline(time.Unix(1, 0)) })
	defer stop()
	if len(query) > 65535 {
		return nil, ErrUpstreamIO
	}
	msg := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(msg, uint16(len(query)))
	copy(msg[2:], query)
	if _, err := c.Write(msg); err != nil {
		return nil, classify(err)
	}
	var l [2]byte
	if _, err := io.ReadFull(c, l[:]); err != nil {
		return nil, classify(err)
	}
	resp := make([]byte, binary.BigEndian.Uint16(l[:]))
	if _, err := io.ReadFull(c, resp); err != nil {
		return nil, classify(err)
	}
	if !match(resp) {
		return nil, ErrUpstreamReply
	}
	return resp, nil
}

func classify(err error) error {
	var ne net.Error
	switch {
	case errors.Is(err, syscall.ECONNREFUSED):
		return ErrUpstreamDown
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &ne) && ne.Timeout():
		return ErrUpstreamTimeout
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF), errors.Is(err, syscall.ECONNRESET):
		return ErrUpstreamReply
	}
	return ErrUpstreamIO
}
