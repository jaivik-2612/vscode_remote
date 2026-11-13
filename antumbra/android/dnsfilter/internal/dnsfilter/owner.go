package dnsfilter

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io/fs"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Why the owner check exists: tor's DNSPort is a UDP socket that tor opens
// with SO_REUSEADDR, and tor does not open it at all while DisableNetwork
// is 1 (before the Welcome screen, and for the whole session in offline
// mode). Any app can then bind 127.0.0.1:9053 itself, alone or next to
// tor; Linux gives each datagram to the most recently bound socket. Such
// an app would see every name the filter forwards and could answer them,
// and its answers are replies the firewall lets through. So before each
// exchange, and again when the reply has arrived, the filter reads the
// kernel's socket table and refuses to use the port unless every socket
// bound to it belongs to tor's uid. (A process that binds, answers and
// closes between the two reads is not caught: it has seen the name, and
// the query times out. The firewall must also refuse packets from port
// 9053 that do not come from tor's uid, so that such a socket cannot
// answer.)

// portOwners returns the uids of the sockets bound to port on 127.0.0.1 or
// on the wildcard address, in IPv4 or IPv4-mapped IPv6 form: the sockets
// that can receive datagrams or connections sent to 127.0.0.1:port. For
// "tcp" only listening sockets count. proto is "udp" or "tcp".
//
// The tables are /proc/net/<proto> and /proc/net/<proto>6. The first must
// be readable; the second may be missing when IPv6 is off.
func portOwners(procNet, proto string, port uint16) ([]int, error) {
	var owners []int
	for _, name := range []string{proto, proto + "6"} {
		f, err := os.Open(filepath.Join(procNet, name))
		if err != nil {
			if name != proto && errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return nil, err
		}
		o, err := scanSockets(f, proto == "tcp", port)
		f.Close()
		if err != nil {
			return nil, err
		}
		owners = append(owners, o...)
	}
	return owners, nil
}

func scanSockets(f *os.File, listenOnly bool, port uint16) ([]int, error) {
	var owners []int
	sc := bufio.NewScanner(f)
	first := true
	for sc.Scan() {
		if first { // column titles
			first = false
			continue
		}
		// sl local_address rem_address st tx:rx tr:when retrnsmt uid ...
		fields := strings.Fields(sc.Text())
		if len(fields) < 8 {
			return nil, errors.New("short line in socket table")
		}
		addr, p, err := parseProcAddr(fields[1])
		if err != nil {
			return nil, err
		}
		if p != port || !reaches127(addr) {
			continue
		}
		if listenOnly && fields[3] != "0A" { // TCP_LISTEN
			continue
		}
		uid, err := strconv.Atoi(fields[7])
		if err != nil {
			return nil, errors.New("bad uid in socket table")
		}
		owners = append(owners, uid)
	}
	return owners, sc.Err()
}

// parseProcAddr decodes "0100007F:235D" or the 32-digit IPv6 form. The
// kernel prints each 32-bit word of the address as a host-order integer,
// so the bytes are recovered with the machine's own byte order.
func parseProcAddr(s string) (netip.Addr, uint16, error) {
	a, p, ok := strings.Cut(s, ":")
	if !ok || (len(a) != 8 && len(a) != 32) || len(p) != 4 {
		return netip.Addr{}, 0, errors.New("bad address in socket table")
	}
	raw, err := hex.DecodeString(a)
	if err != nil {
		return netip.Addr{}, 0, errors.New("bad address in socket table")
	}
	var b [16]byte
	for i := 0; i < len(raw); i += 4 {
		binary.NativeEndian.PutUint32(b[i:], binary.BigEndian.Uint32(raw[i:]))
	}
	port, err := strconv.ParseUint(p, 16, 16)
	if err != nil {
		return netip.Addr{}, 0, errors.New("bad port in socket table")
	}
	if len(raw) == 4 {
		return netip.AddrFrom4([4]byte(b[:4])), uint16(port), nil
	}
	return netip.AddrFrom16(b), uint16(port), nil
}

var (
	loop4 = netip.MustParseAddr("127.0.0.1")
	any4  = netip.IPv4Unspecified()
)

// reaches127 reports whether a socket bound to addr receives traffic sent
// to 127.0.0.1.
func reaches127(addr netip.Addr) bool {
	if addr == netip.IPv6Unspecified() {
		return true // a dual-stack wildcard socket
	}
	a := addr.Unmap()
	return a == loop4 || a == any4
}
