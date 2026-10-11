# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra CI: a small reader for packet captures, standard library only.

Reads classic pcap (either byte order, microsecond or nanosecond time
stamps) and pcapng (section header, interface description, enhanced and
simple packet blocks, with per-interface time-stamp resolution). A file
cut off in the middle of a record, as an emulator that was killed may
leave, is read up to the last whole record and marked as truncated.

Decodes the link types the Android emulator and on-device captures use:
Ethernet (with VLAN tags), raw IP, Linux "cooked" captures (SLL and SLL2),
and IEEE 802.11 with or without a radiotap header (netsim's Wi-Fi
captures). Above them: ARP, IPv4 (with fragments), IPv6 (with extension
headers), TCP, UDP, ICMP and ICMPv6. It also pulls out the few
application details the leak report shows: the name in a DNS question,
the server name (SNI) in a TLS ClientHello, the Host header of an HTTP
request, and the options of a DHCP message.

Nothing here trusts the capture: every length is checked, and a malformed
frame is returned with what could be decoded, never an exception.
"""

import ipaddress
import struct

LINKTYPE_NULL = 0
LINKTYPE_ETHERNET = 1
LINKTYPE_RAW_OLD = 12
LINKTYPE_RAW_OLD2 = 14
LINKTYPE_RAW = 101
LINKTYPE_IEEE802_11 = 105
LINKTYPE_LINUX_SLL = 113
LINKTYPE_IEEE802_11_RADIOTAP = 127
LINKTYPE_LINUX_SLL2 = 276

SUPPORTED_LINKTYPES = {
    LINKTYPE_ETHERNET, LINKTYPE_RAW_OLD, LINKTYPE_RAW_OLD2, LINKTYPE_RAW,
    LINKTYPE_IEEE802_11, LINKTYPE_LINUX_SLL, LINKTYPE_IEEE802_11_RADIOTAP,
    LINKTYPE_LINUX_SLL2,
}

ETH_IPV4 = 0x0800
ETH_ARP = 0x0806
ETH_IPV6 = 0x86DD
ETH_VLAN = (0x8100, 0x88A8, 0x9100)

# Linux SLL packet types: the capturing host's own view of the direction.
SLL_OUTGOING = 4


class CaptureError(Exception):
    """The file is not a capture this reader understands."""


class Record:
    """One captured frame: time (float seconds), link type, bytes."""

    __slots__ = ("ts", "linktype", "data", "orig_len")

    def __init__(self, ts, linktype, data, orig_len):
        self.ts = ts
        self.linktype = linktype
        self.data = data
        self.orig_len = orig_len


class CaptureInfo:
    """What the reader found out about the file as a whole."""

    def __init__(self, path, fmt):
        self.path = path
        self.format = fmt
        self.linktypes = set()
        self.records = 0
        self.truncated = False
        self.first = None
        self.last = None

    def as_dict(self):
        return {
            "path": self.path,
            "format": self.format,
            "linktypes": sorted(self.linktypes),
            "records": self.records,
            "truncated": self.truncated,
            "first": self.first,
            "last": self.last,
        }


def read_capture(path):
    """Returns (records, CaptureInfo). Raises CaptureError for a file that
    is neither pcap nor pcapng, or is shorter than a file header."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 4:
        raise CaptureError("%s: too short to be a capture (%d bytes)" % (path, len(data)))
    magic = data[:4]
    if magic == b"\x0a\x0d\x0d\x0a":
        records, info = _read_pcapng(path, data)
    elif magic in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4", b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d"):
        records, info = _read_pcap(path, data)
    else:
        raise CaptureError("%s: not a pcap or pcapng file (magic %s)" % (path, magic.hex()))
    for r in records:
        info.linktypes.add(r.linktype)
    info.records = len(records)
    if records:
        info.first = min(r.ts for r in records)
        info.last = max(r.ts for r in records)
    return records, info


def _read_pcap(path, data):
    if len(data) < 24:
        raise CaptureError("%s: pcap file header cut short" % path)
    magic = data[:4]
    endian = "<" if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
    nano = magic in (b"\x4d\x3c\xb2\xa1", b"\xa1\xb2\x3c\x4d")
    linktype = struct.unpack(endian + "I", data[20:24])[0] & 0x0FFFFFFF
    div = 1e9 if nano else 1e6
    info = CaptureInfo(path, "pcap")
    records = []
    pos = 24
    while pos < len(data):
        if pos + 16 > len(data):
            info.truncated = True
            break
        sec, frac, incl, orig = struct.unpack(endian + "IIII", data[pos:pos + 16])
        if incl > 0x4000000:
            # A record over 64 MiB is garbage, not a frame: stop here.
            info.truncated = True
            break
        if pos + 16 + incl > len(data):
            info.truncated = True
            break
        records.append(Record(sec + frac / div, linktype, data[pos + 16:pos + 16 + incl], orig))
        pos += 16 + incl
    return records, info


def _read_pcapng(path, data):
    info = CaptureInfo(path, "pcapng")
    records = []
    pos = 0
    endian = "<"
    interfaces = []  # (linktype, ticks per second)
    while pos < len(data):
        if pos + 12 > len(data):
            info.truncated = True
            break
        if data[pos:pos + 4] == b"\x0a\x0d\x0d\x0a":
            bom = data[pos + 8:pos + 12]
            if bom == b"\x4d\x3c\x2b\x1a":
                endian = "<"
            elif bom == b"\x1a\x2b\x3c\x4d":
                endian = ">"
            else:
                raise CaptureError("%s: bad pcapng byte-order magic" % path)
            interfaces = []
        btype, blen = struct.unpack(endian + "II", data[pos:pos + 8])
        if blen < 12 or blen % 4 or pos + blen > len(data):
            info.truncated = True
            break
        body = data[pos + 8:pos + blen - 4]
        if btype == 0x00000001 and len(body) >= 8:  # interface description
            linktype = struct.unpack(endian + "H", body[:2])[0]
            interfaces.append((linktype, _if_tsresol(body[8:], endian)))
        elif btype == 0x00000006 and len(body) >= 20:  # enhanced packet
            ifid, hi, lo, caplen, orig = struct.unpack(endian + "IIIII", body[:20])
            if ifid < len(interfaces) and 20 + caplen <= len(body):
                linktype, tps = interfaces[ifid]
                records.append(Record(((hi << 32) | lo) / tps, linktype, body[20:20 + caplen], orig))
        elif btype == 0x00000003 and len(body) >= 4 and interfaces:  # simple packet
            orig = struct.unpack(endian + "I", body[:4])[0]
            linktype = interfaces[0][0]
            records.append(Record(0.0, linktype, body[4:4 + orig], orig))
        elif btype == 0x00000002 and len(body) >= 20:  # obsolete packet block
            ifid, _drops, hi, lo, caplen, orig = struct.unpack(endian + "HHIIII", body[:20])
            if ifid < len(interfaces) and 20 + caplen <= len(body):
                linktype, tps = interfaces[ifid]
                records.append(Record(((hi << 32) | lo) / tps, linktype, body[20:20 + caplen], orig))
        pos += blen
    return records, info


def _if_tsresol(opts, endian):
    """Ticks per second from an interface block's options (default 10^6)."""
    pos = 0
    while pos + 4 <= len(opts):
        code, length = struct.unpack(endian + "HH", opts[pos:pos + 4])
        if code == 0:
            break
        value = opts[pos + 4:pos + 4 + length]
        if code == 9 and length >= 1:
            v = value[0]
            return float(2 ** (v & 0x7F)) if v & 0x80 else float(10 ** v)
        pos += 4 + length + ((4 - length % 4) % 4)
    return 1e6


def write_pcap(path, records, snaplen=None):
    """Writes records as a classic little-endian microsecond pcap. With
    snaplen, each frame is cut to that many bytes (the original length is
    kept in the record header, as tcpdump -s does). All records must share
    one link type."""
    linktypes = {r.linktype for r in records}
    if len(linktypes) > 1:
        raise ValueError("write_pcap: records have several link types: %s" % sorted(linktypes))
    linktype = linktypes.pop() if linktypes else LINKTYPE_ETHERNET
    out = [struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, snaplen or 262144, linktype)]
    for r in records:
        frame = r.data if snaplen is None else r.data[:snaplen]
        sec = int(r.ts)
        usec = int(round((r.ts - sec) * 1e6))
        if usec >= 1000000:
            sec, usec = sec + 1, usec - 1000000
        out.append(struct.pack("<IIII", sec, usec, len(frame), max(r.orig_len, len(frame))))
        out.append(frame)
    with open(path, "wb") as f:
        f.write(b"".join(out))


# ---------------------------------------------------------------------------
# Decoding
# ---------------------------------------------------------------------------

class Packet:
    """A decoded frame. Fields that do not apply are None.

    l3 is "arp", "ipv4", "ipv6" or None (a frame this reader cannot place,
    such as an encrypted 802.11 frame or another EtherType). proto is
    "tcp", "udp", "icmp", "icmpv6", "ip-N" for another protocol number, or
    "fragment" for a non-first IP fragment (which carries no ports).
    """

    __slots__ = ("ts", "linktype", "length", "src_mac", "dst_mac", "ethertype",
                 "direction_hint", "l3", "src", "dst", "proto", "sport", "dport",
                 "tcp_flags", "icmp_type", "payload", "arp_op", "note")

    def __init__(self, ts, linktype, length):
        self.ts = ts
        self.linktype = linktype
        self.length = length
        self.src_mac = None
        self.dst_mac = None
        self.ethertype = None
        self.direction_hint = None  # "out" or "in" when the capture says so (SLL)
        self.l3 = None
        self.src = None
        self.dst = None
        self.proto = None
        self.sport = None
        self.dport = None
        self.tcp_flags = None
        self.icmp_type = None
        self.payload = b""
        self.arp_op = None
        self.note = None

    @property
    def tcp_syn_only(self):
        return self.proto == "tcp" and self.tcp_flags is not None and (self.tcp_flags & 0x12) == 0x02


def mac_str(b):
    return ":".join("%02x" % x for x in b)


def decode(rec):
    """Decodes one Record into a Packet (never raises)."""
    p = Packet(rec.ts, rec.linktype, rec.orig_len)
    try:
        _decode_link(p, rec.linktype, rec.data)
    except (IndexError, struct.error, ValueError):
        p.note = "malformed"
    return p


def _decode_link(p, linktype, b):
    if linktype == LINKTYPE_ETHERNET:
        if len(b) < 14:
            p.note = "short ethernet frame"
            return
        p.dst_mac, p.src_mac = mac_str(b[0:6]), mac_str(b[6:12])
        etype = struct.unpack(">H", b[12:14])[0]
        off = 14
        while etype in ETH_VLAN and len(b) >= off + 4:
            etype = struct.unpack(">H", b[off + 2:off + 4])[0]
            off += 4
        _decode_ethertype(p, etype, b[off:])
    elif linktype in (LINKTYPE_RAW, LINKTYPE_RAW_OLD, LINKTYPE_RAW_OLD2):
        if not b:
            return
        version = b[0] >> 4
        _decode_ethertype(p, ETH_IPV4 if version == 4 else ETH_IPV6 if version == 6 else -1, b)
    elif linktype == LINKTYPE_LINUX_SLL:
        if len(b) < 16:
            return
        pkttype, _hatype, alen = struct.unpack(">HHH", b[0:6])
        if alen == 6:
            p.src_mac = mac_str(b[6:12])
        p.direction_hint = "out" if pkttype == SLL_OUTGOING else "in"
        _decode_ethertype(p, struct.unpack(">H", b[14:16])[0], b[16:])
    elif linktype == LINKTYPE_LINUX_SLL2:
        if len(b) < 20:
            return
        proto = struct.unpack(">H", b[0:2])[0]
        pkttype, alen = b[10], b[11]
        if alen == 6:
            p.src_mac = mac_str(b[12:18])
        p.direction_hint = "out" if pkttype == SLL_OUTGOING else "in"
        _decode_ethertype(p, proto, b[20:])
    elif linktype == LINKTYPE_IEEE802_11_RADIOTAP:
        if len(b) < 8:
            return
        rtlen = struct.unpack("<H", b[2:4])[0]
        _decode_80211(p, b[rtlen:])
    elif linktype == LINKTYPE_IEEE802_11:
        _decode_80211(p, b)
    else:
        p.note = "link type %d not decoded" % linktype


def _decode_80211(p, b):
    if len(b) < 24:
        return
    fc0, flags = b[0], b[1]
    ftype = (fc0 >> 2) & 3
    subtype = (fc0 >> 4) & 0xF
    if ftype != 2:
        p.note = "802.11 management or control frame"
        return
    tods, fromds = flags & 1, (flags >> 1) & 1
    hdr = 24
    if tods and fromds:
        hdr += 6
    if subtype & 0x8:  # QoS data
        hdr += 2
        if flags & 0x80:  # +HTC
            hdr += 4
    a1, a2, a3 = b[4:10], b[10:16], b[16:22]
    if not tods and not fromds:
        src, dst = a2, a1
    elif tods and not fromds:
        src, dst = a2, a3
    elif fromds and not tods:
        src, dst = a3, a1
    else:
        src, dst = b[24:30], a3
    p.src_mac, p.dst_mac = mac_str(src), mac_str(dst)
    if subtype & 0x4:
        p.note = "802.11 null data"
        return
    if flags & 0x40:
        p.note = "802.11 protected frame (not decoded)"
        return
    body = b[hdr:]
    if len(body) >= 8 and body[0:3] == b"\xaa\xaa\x03":
        _decode_ethertype(p, struct.unpack(">H", body[6:8])[0], body[8:])
    else:
        p.note = "802.11 frame without LLC/SNAP"


def _decode_ethertype(p, etype, b):
    p.ethertype = etype
    if etype == ETH_IPV4:
        _decode_ipv4(p, b)
    elif etype == ETH_IPV6:
        _decode_ipv6(p, b)
    elif etype == ETH_ARP:
        if len(b) >= 28 and b[4] == 6 and b[5] == 4:
            p.l3 = "arp"
            p.arp_op = struct.unpack(">H", b[6:8])[0]
            p.src = str(ipaddress.IPv4Address(b[14:18]))
            p.dst = str(ipaddress.IPv4Address(b[24:28]))
            p.proto = "arp"


def _decode_ipv4(p, b):
    if len(b) < 20 or b[0] >> 4 != 4:
        p.note = "bad IPv4 header"
        return
    ihl = (b[0] & 0x0F) * 4
    total = struct.unpack(">H", b[2:4])[0]
    frag = struct.unpack(">H", b[6:8])[0]
    p.l3 = "ipv4"
    p.src = str(ipaddress.IPv4Address(b[12:16]))
    p.dst = str(ipaddress.IPv4Address(b[16:20]))
    proto = b[9]
    end = min(len(b), total) if total >= ihl else len(b)
    l4 = b[ihl:end]
    if frag & 0x1FFF:
        p.proto = "fragment"
        return
    _decode_l4(p, proto, l4, v6=False)


def _decode_ipv6(p, b):
    if len(b) < 40 or b[0] >> 4 != 6:
        p.note = "bad IPv6 header"
        return
    plen = struct.unpack(">H", b[4:6])[0]
    nxt = b[6]
    p.l3 = "ipv6"
    p.src = str(ipaddress.IPv6Address(b[8:24]))
    p.dst = str(ipaddress.IPv6Address(b[24:40]))
    rest = b[40:40 + plen] if plen else b[40:]
    for _ in range(8):
        if nxt in (0, 43, 60) and len(rest) >= 2:  # hop-by-hop, routing, destination
            hl = (rest[1] + 1) * 8
            nxt, rest = rest[0], rest[hl:]
        elif nxt == 44 and len(rest) >= 8:  # fragment
            offset = struct.unpack(">H", rest[2:4])[0] >> 3
            nxt, rest = rest[0], rest[8:]
            if offset:
                p.proto = "fragment"
                return
        elif nxt == 51 and len(rest) >= 2:  # authentication header
            hl = (rest[1] + 2) * 4
            nxt, rest = rest[0], rest[hl:]
        else:
            break
    _decode_l4(p, nxt, rest, v6=True)


def _decode_l4(p, proto, l4, v6):
    if proto == 6 and len(l4) >= 20:
        p.proto = "tcp"
        p.sport, p.dport = struct.unpack(">HH", l4[0:4])
        p.tcp_flags = l4[13]
        off = (l4[12] >> 4) * 4
        p.payload = l4[off:] if off >= 20 else b""
    elif proto == 17 and len(l4) >= 8:
        p.proto = "udp"
        p.sport, p.dport = struct.unpack(">HH", l4[0:4])
        p.payload = l4[8:]
    elif proto == 1 and not v6 and len(l4) >= 2:
        p.proto = "icmp"
        p.icmp_type = l4[0]
    elif proto == 58 and v6 and len(l4) >= 2:
        p.proto = "icmpv6"
        p.icmp_type = l4[0]
    else:
        p.proto = "ip-%d" % proto


# ---------------------------------------------------------------------------
# Application details (best effort; None when absent or malformed)
# ---------------------------------------------------------------------------

def dns_question(payload, tcp=False):
    """(name, qtype, is_response) of the first question, or None."""
    try:
        if tcp:
            if len(payload) < 2:
                return None
            payload = payload[2:2 + struct.unpack(">H", payload[:2])[0]]
        if len(payload) < 12:
            return None
        flags, qd = struct.unpack(">HH", payload[2:6])
        if qd < 1:
            return None
        name, pos = _dns_name(payload, 12)
        if name is None or pos + 4 > len(payload):
            return None
        qtype = struct.unpack(">H", payload[pos:pos + 2])[0]
        return name, qtype, bool(flags & 0x8000)
    except (IndexError, struct.error):
        return None


def _dns_name(msg, pos):
    labels = []
    jumps = 0
    end = None
    while True:
        if pos >= len(msg):
            return None, None
        n = msg[pos]
        if n == 0:
            pos += 1
            break
        if n & 0xC0 == 0xC0:
            if pos + 1 >= len(msg) or jumps > 16:
                return None, None
            if end is None:
                end = pos + 2
            pos = ((n & 0x3F) << 8) | msg[pos + 1]
            jumps += 1
            continue
        if n > 63 or pos + 1 + n > len(msg):
            return None, None
        labels.append(msg[pos + 1:pos + 1 + n].decode("ascii", "replace"))
        pos += 1 + n
        if len(labels) > 127:
            return None, None
    return ".".join(labels).lower() or ".", (end if end is not None else pos)


def tls_sni(payload):
    """The server name from a TLS ClientHello at the start of payload."""
    try:
        if len(payload) < 9 or payload[0] != 0x16 or payload[1] != 0x03 or payload[5] != 0x01:
            return None
        pos = 9 + 2 + 32  # record header, handshake header, version, random
        pos += 1 + payload[pos]  # session id
        pos += 2 + struct.unpack(">H", payload[pos:pos + 2])[0]  # cipher suites
        pos += 1 + payload[pos]  # compression methods
        ext_end = pos + 2 + struct.unpack(">H", payload[pos:pos + 2])[0]
        pos += 2
        while pos + 4 <= min(ext_end, len(payload)):
            etype, elen = struct.unpack(">HH", payload[pos:pos + 4])
            if etype == 0 and elen >= 5:
                lst = payload[pos + 4:pos + 4 + elen]
                if lst[2] == 0:
                    nlen = struct.unpack(">H", lst[3:5])[0]
                    name = lst[5:5 + nlen]
                    if len(name) == nlen:
                        return name.decode("ascii", "replace").lower()
                return None
            pos += 4 + elen
    except (IndexError, struct.error):
        return None
    return None


_HTTP_METHODS = (b"GET ", b"POST ", b"HEAD ", b"PUT ", b"OPTIONS ", b"CONNECT ", b"DELETE ", b"PATCH ")


def http_host(payload):
    """The Host header of an HTTP/1 request at the start of payload."""
    if not payload.startswith(_HTTP_METHODS):
        return None
    head = payload[:4096]
    for line in head.split(b"\r\n")[1:]:
        if not line:
            break
        if line[:5].lower() == b"host:":
            return line[5:].strip().decode("ascii", "replace").lower()
    return None


DHCP_MESSAGE_TYPES = {1: "DISCOVER", 2: "OFFER", 3: "REQUEST", 4: "DECLINE", 5: "ACK",
                      6: "NAK", 7: "RELEASE", 8: "INFORM"}


def dhcp_options(payload):
    """A dict of the DHCP fields the report shows, or None."""
    try:
        if len(payload) < 240 or payload[236:240] != b"\x63\x82\x53\x63":
            return None
        out = {"op": payload[0], "ciaddr": str(ipaddress.IPv4Address(payload[12:16])),
               "yiaddr": str(ipaddress.IPv4Address(payload[16:20])),
               "chaddr": mac_str(payload[28:34])}
        pos = 240
        while pos < len(payload):
            code = payload[pos]
            if code == 255:
                break
            if code == 0:
                pos += 1
                continue
            ln = payload[pos + 1]
            val = payload[pos + 2:pos + 2 + ln]
            if code == 53 and ln >= 1:
                out["message_type"] = DHCP_MESSAGE_TYPES.get(val[0], str(val[0]))
            elif code == 50 and ln == 4:
                out["requested_ip"] = str(ipaddress.IPv4Address(val))
            elif code == 54 and ln == 4:
                out["server_id"] = str(ipaddress.IPv4Address(val))
            elif code == 12:
                out["hostname"] = val.decode("ascii", "replace")
            elif code == 60:
                out["vendor_class"] = val.decode("ascii", "replace")
            pos += 2 + ln
        return out
    except (IndexError, struct.error, ValueError):
        return None
