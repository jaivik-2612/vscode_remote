package fakedns

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

// Query builds a query message for name (with or without the trailing dot).
func Query(id uint16, name string, t dnsmessage.Type) []byte {
	if name == "" || name[len(name)-1] != '.' {
		name += "."
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: id, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: t, Class: dnsmessage.ClassINET})
	out, err := b.Finish()
	if err != nil {
		panic(err)
	}
	return out
}

// Exchange sends one message to addr over "udp" or "tcp" and returns the
// reply message as raw bytes.
func Exchange(network string, addr netip.AddrPort, msg []byte, timeout time.Duration) ([]byte, error) {
	c, err := net.DialTimeout(network, addr.String(), timeout)
	if err != nil {
		return nil, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(timeout))
	if network == "udp" {
		if _, err := c.Write(msg); err != nil {
			return nil, err
		}
		buf := make([]byte, 65535)
		n, err := c.Read(buf)
		if err != nil {
			return nil, err
		}
		return buf[:n], nil
	}
	out := binary.BigEndian.AppendUint16(nil, uint16(len(msg)))
	if _, err := c.Write(append(out, msg...)); err != nil {
		return nil, err
	}
	var l [2]byte
	if _, err := io.ReadFull(c, l[:]); err != nil {
		return nil, err
	}
	resp := make([]byte, binary.BigEndian.Uint16(l[:]))
	_, err = io.ReadFull(c, resp)
	return resp, err
}

// Ask sends a query for name and type and returns the parsed reply.
func Ask(network string, addr netip.AddrPort, name string, t dnsmessage.Type, timeout time.Duration) (*dnsmessage.Message, error) {
	const id = 0x5a5a
	resp, err := Exchange(network, addr, Query(id, name, t), timeout)
	if err != nil {
		return nil, err
	}
	var m dnsmessage.Message
	if err := m.Unpack(resp); err != nil {
		return nil, err
	}
	if m.ID != id || !m.Response {
		return nil, errors.New("reply has the wrong ID or is not a reply")
	}
	return &m, nil
}
