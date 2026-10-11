# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for the Antumbra CI tools: the pcap reader, the leak
analyser, citool and summary. Every capture is generated here, frame by
frame, so the tests need nothing but the standard library.

Run: python3 -B -m unittest discover -s antumbra/android/ci/tests -v
"""

import contextlib
import io
import ipaddress
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import unittest

sys.dont_write_bytecode = True
CI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, CI)

import citool  # noqa: E402
import leak_analyser as la  # noqa: E402
import pcapread  # noqa: E402
import summary  # noqa: E402

GUEST_MAC = "02:15:b2:00:00:00"
SLIRP_GW_MAC = "52:55:0a:00:02:02"
SLIRP_DNS_MAC = "52:55:0a:00:02:03"
GUEST = "10.0.2.15"


# --- Frame builders ---------------------------------------------------------

def mac(s):
    return bytes(int(x, 16) for x in s.split(":"))


def eth(src, dst, etype, payload):
    return mac(dst) + mac(src) + struct.pack(">H", etype) + payload


def ipv4(src, dst, proto, l4, frag=0):
    hdr = struct.pack(">BBHHHBBH4s4s", 0x45, 0, 20 + len(l4), 1, frag, 64, proto, 0,
                      ipaddress.IPv4Address(src).packed, ipaddress.IPv4Address(dst).packed)
    return hdr + l4


def ipv6(src, dst, nh, l4):
    return struct.pack(">IHBB16s16s", 0x60000000, len(l4), nh, 255,
                       ipaddress.IPv6Address(src).packed, ipaddress.IPv6Address(dst).packed) + l4


def tcp(sport, dport, flags=0x02, payload=b""):
    return struct.pack(">HHIIBBHHH", sport, dport, 1, 0, 5 << 4, flags, 65535, 0, 0) + payload


def udp(sport, dport, payload=b""):
    return struct.pack(">HHHH", sport, dport, 8 + len(payload), 0) + payload


def arp(op, sha, spa, tha, tpa):
    return struct.pack(">HHBBH6s4s6s4s", 1, 0x0800, 6, 4, op, mac(sha), ipaddress.IPv4Address(spa).packed,
                       mac(tha), ipaddress.IPv4Address(tpa).packed)


def dns_query(name, qid=0x1234):
    q = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack(">HH", 1, 1)


def client_hello(sni):
    name = sni.encode()
    sn = struct.pack(">BH", 0, len(name)) + name
    ext = struct.pack(">HH", 0, len(sn) + 2) + struct.pack(">H", len(sn)) + sn
    body = b"\x03\x03" + b"\x11" * 32 + b"\x00" + b"\x00\x02\x13\x01" + b"\x01\x00" + struct.pack(">H", len(ext)) + ext
    hs = b"\x01" + struct.pack(">I", len(body))[1:] + body
    return b"\x16\x03\x01" + struct.pack(">H", len(hs)) + hs


def dhcp(msgtype, chaddr, hostname=None, vendor=None, requested=None, ciaddr="0.0.0.0", server=None):
    b = struct.pack(">BBBBIHH4s4s4s4s", 1, 1, 6, 0, 0xABCDEF01, 0, 0, ipaddress.IPv4Address(ciaddr).packed,
                    b"\0" * 4, b"\0" * 4, b"\0" * 4)
    b += mac(chaddr) + b"\0" * 10 + b"\0" * 64 + b"\0" * 128 + b"\x63\x82\x53\x63"
    b += bytes([53, 1, msgtype])
    if hostname:
        b += bytes([12, len(hostname)]) + hostname.encode()
    if vendor:
        b += bytes([60, len(vendor)]) + vendor.encode()
    if requested:
        b += bytes([50, 4]) + ipaddress.IPv4Address(requested).packed
    if server:
        b += bytes([54, 4]) + ipaddress.IPv4Address(server).packed
    return b + b"\xff"


def out4(dst, l4, proto, src=GUEST, src_mac=GUEST_MAC):
    return eth(src_mac, SLIRP_GW_MAC, 0x0800, ipv4(src, dst, proto, l4))


def sll2(ifindex, l3, src_mac, pkttype=4, hatype=1, proto=0x0800):
    """A frame as tcpdump -i any -y LINUX_SLL2 writes it (pkttype 4: sent)."""
    return struct.pack(">HHIHBB8s", proto, 0, ifindex, hatype, pkttype, 6, mac(src_mac) + b"\0\0") + l3


def sll(l3, src_mac, pkttype=4, hatype=1, proto=0x0800):
    """A frame as tcpdump -i any writes it without -y (Linux cooked v1)."""
    return struct.pack(">HHH8sH", pkttype, hatype, 6, mac(src_mac) + b"\0\0", proto) + l3


def ping_marker(nonce, typ=8):
    """ping -p 414e54554d425241<nonce>: a time stamp, then the pattern."""
    return struct.pack(">BBHHH", typ, 0, 0, 1, 1) + b"\0" * 16 + (b"ANTUMBRA" + bytes.fromhex(nonce)) * 3


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write_pcap(path, frames, linktype=1, endian="<", nano=False):
    magic = 0xA1B23C4D if nano else 0xA1B2C3D4
    out = [struct.pack(endian + "IHHiIII", magic, 2, 4, 0, 0, 65535, linktype)]
    for ts, frame in frames:
        sec = int(ts)
        frac = int(round((ts - sec) * (1e9 if nano else 1e6)))
        out.append(struct.pack(endian + "IIII", sec, frac, len(frame), len(frame)) + frame)
    with open(path, "wb") as f:
        f.write(b"".join(out))


def write_pcapng(path, frames, linktype=1, tsresol=9):
    def block(btype, body):
        body += b"\0" * ((4 - len(body) % 4) % 4)
        n = len(body) + 12
        return struct.pack("<II", btype, n) + body + struct.pack("<I", n)
    shb = block(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1))
    opt = struct.pack("<HHB3x", 9, 1, tsresol) + struct.pack("<HH", 0, 0)
    idb = block(1, struct.pack("<HHI", linktype, 0, 65535) + opt)
    blocks = [shb, idb]
    for ts, frame in frames:
        ticks = int(round(ts * 10 ** tsresol))
        blocks.append(block(6, struct.pack("<IIIII", 0, ticks >> 32, ticks & 0xFFFFFFFF, len(frame), len(frame)) + frame))
    with open(path, "wb") as f:
        f.write(b"".join(blocks))


CONSENSUS = """network-status-version 3 microdesc
vote-status consensus
valid-after 2026-10-11 12:00:00
dir-source auth1 0123456789ABCDEF0123456789ABCDEF01234567 auth1.example 192.0.2.20 80 443
contact someone
r relayA AAAAAAAAAAAAAAAAAAAAAAAAAAA 2026-10-11 11:00:00 198.51.100.7 9001 0
a [2001:db8::7]:9001
m sha256=xyz
s Fast Guard Running Stable Valid
r relayB BBBBBBBBBBBBBBBBBBBBBBBBBBB 2026-10-11 11:00:00 198.51.100.8 443 80
s Fast Running Valid
"""

TOR_BINARY = (b"\x7fELF\x00junk\x00192.0.2.10:80 orport=443 id=" + b"A" * 40 + b" ipv6=[2001:db8::10]:443\x00"
              b"moria1 orport=9201 v3ident=F533C81CEF0BC0267857C99B2F471ADF249FA232 "
              b"128.31.0.39:9231 1A25 C6FC BC97\x00Bridge %s orport=%d\x00")

BRIDGES = """obfs4 192.0.2.44:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=abc iat-mode=0
192.0.2.45:9001 0123456789ABCDEF0123456789ABCDEF01234567
Bridge obfs4 [2001:db8::44]:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0
"""

# Host times (events.tsv) and capture times. The capture's clock runs 1 to
# 2 s ahead of the host's: the marker left at capture time 1010.0, the host
# saw 1008.0 before it and 1009.0 after it.
NONCE = "abc123"
ARM_HOST = 1020.0  # install_start; cutoff = 1020 + 1.0 (offset low) - 1.0 (margin) = 1020.0


def events_text(arm=True, extra=(), stop=1100.0):
    """events.tsv; extra events are (name, host time) or (name, host time,
    detail)."""
    lines = ["boot_completed\t995.0\t", "clock_marker_before\t1008.0\t" + NONCE, "clock_marker_after\t1009.0\t" + NONCE]
    if arm:
        lines.append("install_start\t%s\t" % ARM_HOST)
    lines.extend("%s\t%s\t%s" % (tuple(e) + ("",))[:3] for e in extra)
    lines.append("capture_stop\t%s\t" % stop)
    return "\n".join(lines) + "\n"


def base_frames():
    """Plain Android before arm, then tor's traffic after it."""
    return [
        (1000.0, out4("10.0.2.3", udp(40000, 53, dns_query("connectivitycheck.gstatic.com")), 17)),
        (1000.1, eth(SLIRP_DNS_MAC, GUEST_MAC, 0x0800, ipv4("10.0.2.3", GUEST, 17, udp(53, 40000, b"\x12\x34\x81\x80" + b"\0" * 8)))),
        (1001.0, out4("142.250.1.1", tcp(40001, 443, 0x18, client_hello("www.google.com")), 6)),
        (1001.5, eth(SLIRP_GW_MAC, GUEST_MAC, 0x0800, ipv4("142.250.1.1", GUEST, 6, tcp(443, 40001, 0x12)))),
        (1002.0, eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0806, arp(1, GUEST_MAC, GUEST, "00:00:00:00:00:00", "10.0.2.2"))),
        (1002.1, eth(SLIRP_GW_MAC, GUEST_MAC, 0x0806, arp(2, SLIRP_GW_MAC, "10.0.2.2", GUEST_MAC, GUEST))),
        (1003.0, eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0800,
                     ipv4("0.0.0.0", "255.255.255.255", 17, udp(68, 67, dhcp(1, GUEST_MAC, "android-1", "android-dhcp-16"))))),
        (1010.0, out4("10.0.2.2", udp(41000, 9, b"ANTUMBRA-CLOCK " + NONCE.encode() + b"\n"), 17)),
        (1019.5, out4("203.0.113.50", tcp(40002, 80, 0x18, b"GET / HTTP/1.1\r\nHost: before.example\r\n\r\n"), 6)),
        (1030.0, out4("198.51.100.7", tcp(40010, 9001), 6)),
        (1030.2, eth(SLIRP_GW_MAC, GUEST_MAC, 0x0800, ipv4("198.51.100.7", GUEST, 6, tcp(9001, 40010, 0x12)))),
        (1030.3, out4("198.51.100.7", tcp(40010, 9001, 0x10), 6)),
        (1031.0, out4("192.0.2.10", tcp(40011, 443), 6)),
        (1032.0, out4("192.0.2.20", tcp(40012, 443), 6)),
        (1033.0, out4("192.0.2.44", tcp(40013, 443), 6)),
        # A new lease after arm (SELECTING: the server's offer, with its identifier).
        (1034.0, eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0800,
                     ipv4("0.0.0.0", "255.255.255.255", 17,
                          udp(68, 67, dhcp(3, GUEST_MAC, requested="10.0.2.16", server="10.0.2.2"))))),
    ]


def leak_frames():
    return [
        (1040.0, out4("203.0.113.9", tcp(40020, 443, 0x18, client_hello("tracker.example")), 6)),
        (1041.0, out4("10.0.2.3", udp(40021, 53, dns_query("ads.example")), 17)),
        (1042.0, eth(GUEST_MAC, "33:33:00:00:00:02", 0x86DD,
                     ipv6("fe80::1", "ff02::2", 58, b"\x85\x00\x00\x00\x00\x00\x00\x00"))),
        (1043.0, out4("203.0.113.9", udp(40022, 443, b"quic"), 17)),
        (1044.0, out4("8.8.8.8", b"\x08\x00\x00\x00\x00\x01\x00\x01", 1)),
        (1045.0, out4("10.0.2.2", tcp(40023, 5000), 6)),
        (1046.0, out4("198.18.0.1", tcp(40024, 443), 6, src="198.18.0.99")),
        (1047.0, out4("10.0.2.3", tcp(40025, 853), 6)),
    ]


class TempDir(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def path(self, name):
        return os.path.join(self.dir, name)

    def write(self, name, content):
        p = self.path(name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "wb" if isinstance(content, bytes) else "w") as f:
            f.write(content)
        return p

    def analyse(self, frames, arm=True, extra=(), consensus=True, expect_seen=None, require_tor=True,
                events=(), stop=1100.0):
        write_pcap(self.path("c.pcap"), frames)
        args = ["analyse", "--scenario", "t", "--pcap", self.path("c.pcap"),
                "--events", self.write("events.tsv", events_text(arm, events, stop)), "--out", self.path("a.json"),
                "--tor-binary", self.write("tor", TOR_BINARY), "--bridges", self.write("bridges.txt", BRIDGES)]
        if arm:
            args += ["--arm-event", "install_start"]
        if consensus:
            args += ["--consensus", self.write("consensus", CONSENSUS)]
        if expect_seen is not None:
            args += ["--expect-seen", self.write("seen.txt", expect_seen)]
        if require_tor:
            args += ["--require-tor-traffic"]
        args += list(extra)
        with contextlib.redirect_stdout(io.StringIO()):
            rc = la.main(args)
        with open(self.path("a.json")) as f:
            return rc, json.load(f)


# --- Tests ---------------------------------------------------------------------

class PcapReaderTest(TempDir):
    def test_formats_read_the_same_packets(self):
        frames = base_frames()
        write_pcap(self.path("le.pcap"), frames)
        write_pcap(self.path("be-nano.pcap"), frames, endian=">", nano=True)
        write_pcapng(self.path("c.pcapng"), frames)
        results = []
        for name in ("le.pcap", "be-nano.pcap", "c.pcapng"):
            recs, info = pcapread.read_capture(self.path(name))
            self.assertFalse(info.truncated, name)
            results.append([(round(r.ts, 3), r.data) for r in recs])
        self.assertEqual(results[0], results[1])
        self.assertEqual(results[0], results[2])
        self.assertEqual(len(results[0]), len(frames))

    def test_truncated_file_reads_whole_records(self):
        write_pcap(self.path("c.pcap"), base_frames())
        with open(self.path("c.pcap"), "rb") as f:
            data = f.read()
        self.write("cut.pcap", data[:-7])
        recs, info = pcapread.read_capture(self.path("cut.pcap"))
        self.assertTrue(info.truncated)
        self.assertEqual(len(recs), len(base_frames()) - 1)

    def test_not_a_capture(self):
        with self.assertRaises(pcapread.CaptureError):
            pcapread.read_capture(self.write("x.pcap", b"hello world, not a pcap"))

    def test_decoders(self):
        p = pcapread.decode(pcapread.Record(1.0, 1, out4("1.2.3.4", tcp(1, 443, 0x18, client_hello("a.example")), 6), 100))
        self.assertEqual((p.l3, p.proto, p.src, p.dst, p.dport), ("ipv4", "tcp", GUEST, "1.2.3.4", 443))
        self.assertEqual(pcapread.tls_sni(p.payload), "a.example")
        p = pcapread.decode(pcapread.Record(1.0, 1, out4("10.0.2.3", udp(5, 53, dns_query("Foo.Example")), 17), 80))
        self.assertEqual(pcapread.dns_question(p.payload), ("foo.example", 1, False))
        self.assertEqual(pcapread.http_host(b"GET / HTTP/1.1\r\nHost: X.example\r\n\r\n"), "x.example")
        d = pcapread.dhcp_options(dhcp(1, GUEST_MAC, "h", "android-dhcp-16", requested="10.0.2.15"))
        self.assertEqual((d["message_type"], d["vendor_class"], d["requested_ip"]), ("DISCOVER", "android-dhcp-16", "10.0.2.15"))
        # A non-first fragment has no ports.
        p = pcapread.decode(pcapread.Record(1.0, 1, eth(GUEST_MAC, SLIRP_GW_MAC, 0x0800, ipv4(GUEST, "1.2.3.4", 6, b"x" * 30, frag=10)), 64))
        self.assertEqual(p.proto, "fragment")
        # VLAN-tagged Ethernet.
        inner = ipv4(GUEST, "1.2.3.4", 17, udp(1000, 53))
        vlan = mac(SLIRP_GW_MAC) + mac(GUEST_MAC) + b"\x81\x00\x00\x05\x08\x00" + inner
        self.assertEqual(pcapread.decode(pcapread.Record(0, 1, vlan, 0)).dport, 53)
        # Garbage never raises.
        for junk in (b"", b"\x00" * 13, b"\xff" * 40, eth(GUEST_MAC, SLIRP_GW_MAC, 0x0800, b"\x45\x00")):
            pcapread.decode(pcapread.Record(0, 1, junk, 0))

    def test_radiotap_80211_and_sll2(self):
        body = ipv4(GUEST, "198.51.100.7", 6, tcp(40000, 9001))
        wifi = (b"\x08\x01" + b"\x00\x00" + mac("00:13:10:85:fe:01") + mac(GUEST_MAC) + mac("00:13:10:85:fe:01")
                + b"\x00\x00" + b"\xaa\xaa\x03\x00\x00\x00\x08\x00" + body)
        radiotap = b"\x00\x00\x08\x00\x00\x00\x00\x00" + wifi
        p = pcapread.decode(pcapread.Record(0, 127, radiotap, len(radiotap)))
        self.assertEqual((p.src_mac, p.dst, p.dport), (GUEST_MAC, "198.51.100.7", 9001))
        p = pcapread.decode(pcapread.Record(0, 105, b"\x48\x01" + wifi[2:], 0))  # null data
        self.assertIsNone(p.l3)
        p = pcapread.decode(pcapread.Record(0, 276, sll2(3, body, GUEST_MAC), 0))
        self.assertEqual((p.direction_hint, p.dport, p.ifindex, p.hatype), ("out", 9001, 3, 1))
        p = pcapread.decode(pcapread.Record(0, 113, sll(body, GUEST_MAC, pkttype=0, hatype=772), 0))
        self.assertEqual((p.direction_hint, p.dport, p.ifindex, p.hatype), ("in", 9001, None, 772))
        # ICMP keeps its data (the clock marker is in it).
        p = pcapread.decode(pcapread.Record(0, 1, out4("10.0.2.2", ping_marker("abcd"), 1), 0))
        self.assertEqual((p.proto, p.icmp_type), ("icmp", 8))
        self.assertIn(b"ANTUMBRA\xab\xcd", p.payload)

    def test_write_pcap_slim(self):
        write_pcap(self.path("c.pcap"), base_frames())
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(la.main(["slim", self.path("c.pcap"), self.path("s.pcap"), "--snaplen", "60"]), 0)
        recs, _ = pcapread.read_capture(self.path("s.pcap"))
        self.assertEqual(len(recs), len(base_frames()))
        self.assertTrue(all(len(r.data) <= 60 for r in recs))
        self.assertTrue(any(r.orig_len > 60 for r in recs))


class InputsTest(TempDir):
    def test_consensus_binary_and_bridges(self):
        td = la.TorDirectory()
        la.load_consensus(td, self.write("consensus", CONSENSUS))
        la.load_tor_binary(td, self.write("tor", TOR_BINARY))
        la.load_bridges(td, self.write("bridges.txt", BRIDGES))
        self.assertEqual(td.info["consensus"]["relays"], 2)
        self.assertEqual(td.info["consensus"]["flavour"], "microdesc")
        self.assertEqual(td.lookup("198.51.100.7", 9001)[0], "tor-relay")
        self.assertEqual(td.lookup("2001:db8::7", 9001)[0], "tor-relay")
        # DirPorts are never Tor traffic (clients use the ORPort); they are only named.
        self.assertIsNone(td.lookup("198.51.100.8", 80))
        self.assertEqual(td.dirport("198.51.100.8", 80), "relay relayB (DirPort)")
        self.assertIsNone(td.lookup("128.31.0.39", 9231))
        self.assertIsNone(td.lookup("192.0.2.10", 80))
        self.assertEqual(td.lookup("192.0.2.20", 443), ("tor-directory", "authority auth1"))
        self.assertEqual(td.lookup("192.0.2.10", 443)[0], "tor-directory")  # fallback
        self.assertEqual(td.lookup("128.31.0.39", 9201), ("tor-directory", "authority moria1"))
        self.assertEqual(td.lookup("192.0.2.44", 443), ("bridge", "bridge (obfs4)"))
        self.assertEqual(td.lookup("192.0.2.45", 9001), ("bridge", "bridge (vanilla)"))
        self.assertEqual(td.lookup("2001:db8::44", 443)[0], "bridge")
        self.assertIsNone(td.lookup("198.51.100.7", 443))  # a relay's other port is not Tor
        self.assertEqual(td.info["tor_binary"]["fallbacks"], 1)
        self.assertEqual(td.info["tor_binary"]["authorities"], 1)

    def test_not_a_consensus(self):
        with self.assertRaises(ValueError):
            la.load_consensus(la.TorDirectory(), self.write("c", "hello\n"))

    def test_proc_net_tcp(self):
        def v4(addr, port):
            return "%08X:%04X" % (struct.unpack("<I", ipaddress.IPv4Address(addr).packed)[0], port)

        def v6(addr, port):
            b = ipaddress.IPv6Address(addr).packed
            return "".join("%08X" % struct.unpack("<I", b[i:i + 4])[0] for i in range(0, 16, 4)) + ":%04X" % port

        def row(n, local, remote, st, uid):
            return "  %d: %s %s %s 00000000:00000000 00:00000000 00000000 %5d 0 1234 1" % (n, local, remote, st, uid)

        text = "\n".join([
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode",
            row(0, v4(GUEST, 40010), v4("198.51.100.7", 9001), "01", 2950),
            row(1, v4("127.0.0.1", 9040), v4("127.0.0.1", 50000), "01", 2950),
            row(2, v4(GUEST, 40011), v4("203.0.113.1", 443), "01", 10100),
            row(3, v4("127.0.0.1", 9040), v4("0.0.0.0", 0), "0A", 2950),
            row(4, v6("::ffff:10.0.2.15", 1), v6("::ffff:198.51.100.8", 443), "01", 2950),
            row(5, v6("2001:db8::1", 1), v6("2001:db8::7", 9001), "01", 2950),
        ])
        self.assertEqual(la.parse_proc_net_tcp(text), [("198.51.100.7", 9001), ("198.51.100.8", 443), ("2001:db8::7", 9001)])
        p = self.write("tcp", text)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            la.main(["tor-conns", p])
        self.assertEqual(out.getvalue().split(), ["198.51.100.7:9001", "198.51.100.8:443", "[2001:db8::7]:9001"])
        listen = "\n".join([
            row(0, v4("127.0.0.1", 9040), v4("0.0.0.0", 0), "0A", 2950),
            row(1, v4("0.0.0.0", 9050), v4("0.0.0.0", 0), "0A", 2950),
            row(2, v6("::", 5555), v6("::", 0), "0A", 0),
            row(3, v4(GUEST, 40010), v4("198.51.100.7", 9001), "01", 2950),
        ])
        self.assertEqual(la.parse_proc_net_listeners(listen),
                         [(0, "::", 5555), (2950, "0.0.0.0", 9050), (2950, "127.0.0.1", 9040)])
        udp = row(0, v4("127.0.0.1", 9053), v4("0.0.0.0", 0), "07", 2950)
        self.assertEqual(la.parse_proc_net_listeners(udp, "udp"), [(2950, "127.0.0.1", 9053)])
        self.assertEqual(la.load_expect_seen(self.write("seen", out.getvalue())),
                         [("198.51.100.7", 9001), ("198.51.100.8", 443), ("2001:db8::7", 9001)])


class AnalyserTest(TempDir):
    def test_pass(self):
        rc, a = self.analyse(base_frames(), expect_seen="198.51.100.7:9001\n")
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        self.assertEqual(rc, 0)
        self.assertEqual(a["guest"]["addresses"], [GUEST])
        self.assertEqual(a["leaks"], [])
        self.assertEqual(a["clock"]["source"], "marker")
        self.assertAlmostEqual(a["clock"]["offset_low"], 1.0)
        self.assertAlmostEqual(a["clock"]["offset_high"], 2.0)
        self.assertAlmostEqual(a["arm"]["cutoff"], 1020.0)
        post = a["phases"]["post-arm"]
        self.assertEqual(post, {"tor-relay": 2, "tor-directory": 2, "bridge": 1, "lan-dhcp": 1})
        pre = a["phases"]["pre-arm"]
        self.assertEqual(pre["LEAK"], 3)  # DNS, HTTPS and the HTTP request before arm: listed, not judged
        self.assertEqual(pre["ci-marker"], 1)
        self.assertEqual(pre["link-arp"], 1)
        self.assertEqual(pre["lan-dhcp"], 1)
        names = {n for f in a["flows"] for n in f["names"]}
        self.assertTrue({"connectivitycheck.gstatic.com", "www.google.com", "before.example"} <= names)
        self.assertEqual(a["coverage"]["status"], "complete")
        dhcp_flow = [f for f in a["flows"] if f.get("dhcp", {}).get("message_type") == "DISCOVER"][0]
        self.assertEqual(dhcp_flow["dhcp"]["vendor_class"], "android-dhcp-16")
        # Inbound frames from slirp are not the guest's traffic.
        self.assertEqual(a["totals"]["from_emulator"], 4)

    def test_leaks_after_arm_fail(self):
        rc, a = self.analyse(base_frames() + leak_frames())
        self.assertEqual(a["verdict"], "fail")
        self.assertEqual(rc, 1)
        kinds = sorted(f["kind"] for f in a["leaks"])
        self.assertEqual(kinds, ["dns", "dns", "icmp", "ipv6", "lan", "tcp", "udp", "unattributed"])
        names = {n for f in a["leaks"] for n in f["names"]}
        self.assertEqual(names, {"tracker.example", "ads.example"})
        self.assertIn("fe80::1", a["guest"]["addresses"])

    def test_marker_after_arm_is_a_leak(self):
        frames = base_frames() + [(1050.0, out4("10.0.2.2", udp(41000, 9, b"ANTUMBRA-CLOCK " + NONCE.encode()), 17))]
        _, a = self.analyse(frames)
        self.assertEqual(a["verdict"], "fail")
        self.assertEqual([f["kind"] for f in a["leaks"]], ["lan"])

    def test_cutoff_moves_without_marker(self):
        frames = [f for f in base_frames() if b"ANTUMBRA-CLOCK" not in f[1]]
        _, a = self.analyse(frames)
        self.assertEqual(a["clock"]["source"], "none")
        # No marker: host clock assumed, 3 s margin: cutoff 1017.0, so the
        # request at 1019.5 now counts and fails the run.
        self.assertAlmostEqual(a["arm"]["cutoff"], 1017.0)
        self.assertEqual(a["verdict"], "fail")
        self.assertEqual(a["leaks"][0]["names"], ["before.example"])

    def test_capture_misses_tor_connection(self):
        _, a = self.analyse(base_frames(), expect_seen="198.51.100.7:9001\n198.51.100.8:443\n")
        self.assertEqual(a["verdict"], "blind")
        self.assertEqual(a["coverage"]["missing"], ["198.51.100.8:443"])

    def test_no_tor_traffic_is_blind(self):
        frames = [f for f in base_frames() if f[0] < 1020]
        rc, a = self.analyse(frames)
        self.assertEqual((a["verdict"], rc), ("blind", 3))

    def test_no_guest_traffic_is_blind(self):
        frames = [f for f in base_frames() if f[1][6:12] == mac(SLIRP_GW_MAC) or f[1][6:12] == mac(SLIRP_DNS_MAC)]
        _, a = self.analyse(frames)
        self.assertEqual(a["verdict"], "blind")

    def test_missing_consensus_is_an_error(self):
        rc, a = self.analyse(base_frames(), consensus=False)
        self.assertEqual((a["verdict"], rc), ("error", 2))

    def test_missing_arm_event_is_an_error(self):
        write_pcap(self.path("c.pcap"), base_frames())
        self.write("ev.tsv", "boot_completed\t1.0\t\n")
        with contextlib.redirect_stdout(io.StringIO()):
            rc = la.main(["analyse", "--scenario", "t", "--pcap", self.path("c.pcap"), "--events", self.path("ev.tsv"),
                          "--arm-event", "install_start", "--out", self.path("a.json")])
        self.assertEqual(rc, 2)

    def test_empty_and_missing_capture(self):
        write_pcap(self.path("e.pcap"), [])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(la.main(["analyse", "--scenario", "t", "--pcap", self.path("e.pcap"), "--out", self.path("a.json")]), 2)
            self.assertEqual(la.main(["analyse", "--scenario", "t", "--pcap", self.path("none.pcap"), "--out", self.path("a.json")]), 2)

    def test_baseline_is_information(self):
        rc, a = self.analyse(base_frames() + leak_frames(), arm=False, require_tor=False)
        self.assertEqual((a["verdict"], rc), ("info", 0))
        self.assertEqual(set(a["phases"]), {"baseline"})
        self.assertIsNone(a["arm"])

    def test_explicit_guest(self):
        _, a = self.analyse(base_frames(), extra=["--guest", "10.0.2.15"])
        self.assertEqual(a["guest"]["source"], "given")
        self.assertEqual(a["verdict"], "pass")

    def test_report(self):
        rc1, _ = self.analyse(base_frames() + leak_frames())
        os.rename(self.path("a.json"), self.path("antumbra.json"))
        self.analyse(base_frames(), arm=False, require_tor=False)
        with open(self.path("a.json")) as f:
            b = json.load(f)
        b["scenario"] = "baseline"
        with open(self.path("baseline.json"), "w") as f:
            json.dump(b, f)
        with open(self.path("antumbra.json")) as f:
            a = json.load(f)
        a["scenario"] = "antumbra"
        with open(self.path("antumbra.json"), "w") as f:
            json.dump(a, f)
        la.main(["report", "--in", self.path("baseline.json"), "--in", self.path("antumbra.json"),
                 "--json", self.path("leak-report.json"), "--md", self.path("leak-report.md")])
        with open(self.path("leak-report.json")) as f:
            rep = json.load(f)
        self.assertEqual(sorted(rep["scenarios"]), ["antumbra", "baseline"])
        with open(self.path("leak-report.md")) as f:
            md = f.read()
        self.assertIn("LEAKs after arm: 8 destination(s)", md)
        self.assertIn("tracker.example", md)
        self.assertIn("What the phone contacted on its own", md)
        self.assertIn("What this test cannot see", md)


class FailClosedTest(TempDir):
    """Frames that are not slirp's own are the phone's, whatever they carry."""

    def one(self, frame):
        rc, a = self.analyse(base_frames() + [(1040.0, frame)])
        self.assertEqual((a["verdict"], rc), ("fail", 1), a["verdict_reasons"])
        return a["leaks"]

    def test_second_mac_high_udp_port(self):
        # A second interface whose only traffic is UDP to a high port.
        leaks = self.one(out4("203.0.113.9", udp(40100, 3478, b"stun"), 17, src="10.0.2.16", src_mac="02:aa:bb:cc:dd:ee"))
        self.assertEqual([(f["kind"], f["dst"]) for f in leaks], [("unattributed", "203.0.113.9")])

    def test_guest_mac_with_slirp_source(self):
        leaks = self.one(out4("203.0.113.9", udp(40101, 5000), 17, src="10.0.2.3"))
        self.assertEqual([f["kind"] for f in leaks], ["unattributed"])

    def test_random_mac_that_looks_like_slirp(self):
        leaks = self.one(out4("203.0.113.9", tcp(40102, 443), 6, src_mac="52:55:aa:bb:cc:dd"))
        self.assertEqual([f["kind"] for f in leaks], ["tcp"])

    def test_forged_slirp_mac(self):
        # slirp's exact MAC, but not addressed to the phone: the phone forged it.
        leaks = self.one(eth(SLIRP_GW_MAC, GUEST_MAC, 0x0800, ipv4("198.51.100.200", "203.0.113.9", 6, tcp(40103, 443))))
        self.assertEqual([f["kind"] for f in leaks], ["unattributed"])
        leaks = self.one(eth(SLIRP_GW_MAC, SLIRP_GW_MAC, 0x0800, ipv4("10.0.2.3", "10.0.2.2", 6, tcp(40104, 80))))
        self.assertEqual([f["kind"] for f in leaks], ["unattributed"])

    def test_dirport_is_a_leak(self):
        leaks = self.one(out4("198.51.100.8", tcp(40105, 80), 6))
        self.assertEqual([(f["kind"], f["label"]) for f in leaks], [("tcp", "relay relayB (DirPort)")])

    def test_slirp_traffic_is_not_judged(self):
        # Answers from slirp to the phone, a DHCP offer to a new address, slirp's
        # router advertisement and ARP: counted as the emulator's, never listed.
        frames = base_frames() + [
            (1041.0, eth(SLIRP_GW_MAC, "ff:ff:ff:ff:ff:ff", 0x0800,
                         ipv4("10.0.2.2", "255.255.255.255", 17, udp(67, 68, dhcp(2, GUEST_MAC))))),
            (1042.0, eth("52:56:00:00:00:02", "33:33:00:00:00:01", 0x86DD,
                         ipv6("fe80::2", "ff02::1", 58, b"\x86\x00\x00\x00" + b"\x00" * 12))),
            (1043.0, eth(SLIRP_GW_MAC, "ff:ff:ff:ff:ff:ff", 0x0806, arp(1, SLIRP_GW_MAC, "10.0.2.2", "00:00:00:00:00:00", GUEST))),
        ]
        rc, a = self.analyse(frames)
        self.assertEqual((a["verdict"], rc), ("pass", 0), a["verdict_reasons"])
        self.assertEqual(a["totals"]["from_emulator"], 7)

    def test_lan_mode_judges_by_address(self):
        # A capture on a real network: the router's frames are not the phone's,
        # the phone's own frames are, whatever their source.
        router = "00:11:22:33:44:55"
        frames = [f for f in base_frames() if f[0] >= 1030] + [
            (1035.0, eth(router, GUEST_MAC, 0x0800, ipv4("192.0.2.200", GUEST, 6, tcp(443, 40200, 0x12)))),
            (1036.0, eth(router, "ff:ff:ff:ff:ff:ff", 0x0800, ipv4("10.0.2.1", "10.0.2.255", 17, udp(137, 137)))),
        ]
        _, a = self.analyse(frames, arm=False, require_tor=False,
                            extra=["--network", "lan", "--judge-from-start", "--guest", GUEST, "--require-tor-traffic"])
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        self.assertEqual(a["totals"]["not_the_phone"], 3)  # the two above and the relay's SYN-ACK
        _, a = self.analyse(frames + [(1037.0, out4("10.0.2.1", udp(40201, 9), 17, src="10.0.2.99"))], arm=False,
                            require_tor=False, extra=["--network", "lan", "--judge-from-start", "--guest", GUEST])
        self.assertEqual([f["kind"] for f in a["leaks"]], ["unattributed"])


class JudgementsTest(TempDir):
    def test_judge_from_start(self):
        # No events at all, every packet judged: the DNS before 'arm' counts.
        _, a = self.analyse(base_frames(), arm=False, extra=["--judge-from-start", "--guest", GUEST])
        self.assertEqual(a["verdict"], "fail")
        self.assertIn("connectivitycheck.gstatic.com", {n for f in a["leaks"] for n in f["names"]})
        self.assertEqual(a["arm"]["event"], "(start of the capture)")

    def test_dhcp_lease_memory(self):
        reboot = eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0800, ipv4("0.0.0.0", "255.255.255.255", 17,
                                                                 udp(68, 67, dhcp(3, GUEST_MAC, requested=GUEST))))
        _, a = self.analyse(base_frames() + [(1040.0, reboot)])
        self.assertEqual(a["verdict"], "fail")
        self.assertEqual([(f["kind"], f["label"]) for f in a["leaks"]], [("dhcp-lease", "requested 10.0.2.15")])
        renew = out4("10.0.2.2", udp(68, 67, dhcp(3, GUEST_MAC, ciaddr=GUEST)), 17)
        _, a = self.analyse(base_frames() + [(1040.0, renew)])
        self.assertEqual([f["kind"] for f in a["leaks"]], ["dhcp-lease"])
        # The same address offered anew by the server (SELECTING) is not the lease memory.
        select = eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0800, ipv4("0.0.0.0", "255.255.255.255", 17,
                                                                 udp(68, 67, dhcp(3, GUEST_MAC, requested=GUEST, server="10.0.2.2"))))
        _, a = self.analyse(base_frames() + [(1040.0, select)])
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        self.assertEqual(a["dhcp_pre_arm_leases"], [GUEST])

    def test_dhcp_hostname(self):
        # After arm, a DHCP message with a host name (option 12) is a LEAK;
        # before arm (base_frames' DISCOVER, "android-1") it is listed only.
        named = eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0800, ipv4("0.0.0.0", "255.255.255.255", 17,
                                                                udp(68, 67, dhcp(1, GUEST_MAC, "OnePlus-7T-Pro"))))
        _, a = self.analyse(base_frames() + [(1040.0, named)])
        self.assertEqual(a["verdict"], "fail")
        self.assertEqual([(f["kind"], f["label"]) for f in a["leaks"]], [("dhcp-hostname", "host name OnePlus-7T-Pro")])
        # A phone capture judged from its start: the same.
        _, a = self.analyse([(1000.0, named)] + base_frames()[9:], arm=False,
                            extra=["--judge-from-start", "--guest", GUEST])
        self.assertIn("dhcp-hostname", [f["kind"] for f in a["leaks"]])

    def armed(self, frames, require=True, events=(("armed_probe_start", 1050.0), ("armed_probe_end", 1070.0))):
        extra = ["--armed-window", "armed_probe_start:armed_probe_end"]
        if require:
            extra.append("--require-armed-window")
        return self.analyse(base_frames() + frames, extra=extra, events=events)

    def test_armed_window(self):
        # Window: 1050 + 2.0 (offset high) + 0.5 to 1070 + 1.0 (offset low) - 0.5.
        link = [(1060.0, eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0806, arp(1, GUEST_MAC, GUEST, "00:00:00:00:00:00", "10.0.2.2"))),
                (1061.0, eth(GUEST_MAC, "ff:ff:ff:ff:ff:ff", 0x0800, ipv4("0.0.0.0", "255.255.255.255", 17,
                                                                           udp(68, 67, dhcp(1, GUEST_MAC)))))]
        _, a = self.armed(link + [(1052.0, out4("198.51.100.7", tcp(40010, 9001, 0x10), 6)),
                                  (1071.0, out4("198.51.100.7", tcp(40010, 9001, 0x10), 6))])
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        aw = a["armed_window"]
        self.assertEqual((aw["status"], aw["packets"], aw["allowed"], aw["leaks"]), ("ok", 2, 2, 0))
        self.assertAlmostEqual(aw["start"], 1052.5)
        self.assertAlmostEqual(aw["end"], 1070.5)
        # Tor's own traffic is a LEAK while only the arm set is loaded.
        _, a = self.armed(link + [(1065.0, out4("198.51.100.7", tcp(40010, 9001, 0x10), 6))])
        self.assertEqual(a["verdict"], "fail")
        self.assertEqual(a["armed_window"]["status"], "fail")
        self.assertEqual([(f["kind"], f["label"]) for f in a["leaks"]], [("armed", "relay relayA")])

    def test_armed_window_missing_is_blind(self):
        rc, a = self.armed([], events=(("armed_probe_start", 1050.0),))
        self.assertEqual((a["verdict"], rc), ("blind", 3))
        self.assertEqual(a["armed_window"]["status"], "not-run")
        _, a = self.armed([], events=(("armed_probe_start", 1050.0), ("armed_probe_end", 1052.0)))
        self.assertEqual((a["verdict"], a["armed_window"]["status"]), ("blind", "too-short"))

    def test_expect_guest(self):
        ip_addr = ("1: lo: <LOOPBACK,UP> mtu 65536\n    inet 127.0.0.1/8 scope host lo\n"
                   "2: eth0: <UP> mtu 1500\n    inet 10.0.2.15/24 brd 10.0.2.255 scope global eth0\n"
                   "    inet6 fe80::1/64 scope link\n"
                   "3: wlan0@if5: <UP> mtu 1500\n    inet 10.0.2.16/24 brd 10.0.2.255 scope global wlan0\n")
        self.assertEqual(la.load_expect_guest(self.write("ip.txt", ip_addr)), [("eth0", "10.0.2.15"), ("wlan0", "10.0.2.16")])
        _, a = self.analyse(base_frames(), extra=["--expect-guest", self.path("ip.txt")])
        self.assertEqual(a["verdict"], "blind")
        self.assertEqual(a["coverage"]["addresses_missing"], ["wlan0 10.0.2.16"])
        _, a = self.analyse(base_frames(), extra=["--expect-guest", self.write("ip2.txt", "eth0 10.0.2.15/24\n")])
        self.assertEqual((a["verdict"], a["coverage"]["status"]), ("pass", "complete"))

    def test_end_of_capture(self):
        _, a = self.analyse(base_frames(), stop=1300.0)
        self.assertEqual(a["verdict"], "blind")
        self.assertIn("before the scenario stopped", a["verdict_reasons"][0])
        write_pcap(self.path("c.pcap"), base_frames())
        with open(self.path("c.pcap"), "rb") as f:
            cut = f.read()[:-7]
        self.write("cut.pcap", cut)
        with contextlib.redirect_stdout(io.StringIO()):
            rc = la.main(["analyse", "--scenario", "t", "--pcap", self.path("cut.pcap"), "--events",
                          self.write("ev.tsv", events_text()), "--arm-event", "install_start",
                          "--consensus", self.write("consensus", CONSENSUS), "--tor-binary", self.write("tor", TOR_BINARY),
                          "--bridges", self.write("bridges.txt", BRIDGES), "--out", self.path("a.json")])
        self.assertEqual(rc, 3)
        with open(self.path("a.json")) as f:
            self.assertIn("ends in the middle of a frame", json.load(f)["verdict_reasons"][0])


class ClockTest(TempDir):
    """The clock marker: one per interface (ICMP) and one by the default
    route (UDP), each bounding its capture's offset to the host."""

    def test_icmp_marker_and_tight_bracket(self):
        # The UDP marker at 1010.0 (offset 1 to 2 s) and the ICMP marker at
        # 1009.4: the offset lies in both intervals, 1.0 to 1.4 s.
        frames = base_frames() + [(1009.4, out4("10.0.2.2", ping_marker(NONCE), 1)),
                                  # slirp's echo reply may come after the second time stamp: not a marker.
                                  (1012.5, eth(SLIRP_GW_MAC, GUEST_MAC, 0x0800, ipv4("10.0.2.2", GUEST, 1,
                                                                                    ping_marker(NONCE, 0))))]
        _, a = self.analyse(frames)
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        c = a["clock"]
        self.assertEqual((c["source"], c["markers"]), ("marker", 2))
        self.assertAlmostEqual(c["offset_low"], 1.0)
        self.assertAlmostEqual(c["offset_high"], 1.4)
        self.assertEqual(a["phases"]["pre-arm"]["ci-marker"], 2)
        # The same ICMP marker after arm is a LEAK.
        _, a = self.analyse(base_frames() + [(1040.0, out4("10.0.2.2", ping_marker(NONCE), 1))])
        self.assertEqual([f["kind"] for f in a["leaks"]], ["icmp"])

    def test_markers_that_disagree_are_blind(self):
        frames = base_frames() + [(1030.5, out4("10.0.2.2", ping_marker(NONCE), 1))]
        _, a = self.analyse(frames)
        self.assertTrue(a["clock"].get("conflict"))
        self.assertEqual(a["verdict"], "fail")  # the marker after arm is also a LEAK
        self.assertTrue(any("markers in c.pcap disagree" in r for r in a["verdict_reasons"]))

    def test_run4_bracket(self):
        # Run 4: mDNS 60 s before install_start was judged after arm because
        # nc's two time-outs left a 120 s bracket. With the bracket the
        # marker now has (1 s), it is before the cutoff, and a packet sent
        # just after install_start still counts.
        def mdns(t):
            return (t, out4("224.0.0.251", udp(5353, 5353, b"\0" * 12), 17))
        wide = (("clock_marker_before", 948.0), ("clock_marker_after", 1069.0))
        lines = [ln for ln in events_text(extra=()).splitlines() if not ln.startswith("clock_marker")]
        self.write("wide.tsv", "\n".join(lines + ["%s\t%s\t%s" % (n, t, NONCE) for n, t in wide]) + "\n")
        frames = base_frames() + [mdns(960.5)]
        write_pcap(self.path("c.pcap"), frames)
        with contextlib.redirect_stdout(io.StringIO()):
            la.main(["analyse", "--scenario", "t", "--pcap", self.path("c.pcap"), "--events", self.path("wide.tsv"),
                     "--arm-event", "install_start", "--consensus", self.write("consensus", CONSENSUS),
                     "--out", self.path("a.json")])
        with open(self.path("a.json")) as f:
            self.assertIn("multicast", [x["kind"] for x in json.load(f)["leaks"]])
        _, a = self.analyse(frames)
        self.assertNotIn("multicast", [f["kind"] for f in a["leaks"]])
        _, a = self.analyse(frames + [mdns(1022.0)])
        self.assertIn("multicast", [f["kind"] for f in a["leaks"]])


ETH0_MAC = "52:54:00:12:34:56"
WLAN_MAC = "02:15:b2:00:00:01"
WLAN = "10.0.2.16"
LINKS = """# capture_start 1000.0
1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN\\    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00
15: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP\\    link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
16: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP\\    link/ether 02:15:b2:00:00:01 brd ff:ff:ff:ff:ff:ff
15: eth0    inet 10.0.2.15/24 brd 10.0.2.255 scope global eth0\\       valid_lft forever preferred_lft forever
16: wlan0    inet 10.0.2.16/24 brd 10.0.2.255 scope global wlan0\\       valid_lft forever preferred_lft forever
"""
GUEST_STOP = ("guest_capture_stop", 1099.0, "captured=10 received=10 dropped=0")


def guest_frames():
    """tcpdump -i any inside the guest, on the device's clock (the markers
    put it 0.69 s behind the host to 0.3 s ahead; the cutoff is 1018.31)."""
    def tcp4(src, sport):
        return ipv4(src, "198.51.100.7", 6, tcp(sport, 9001))
    return [
        (1008.30, sll2(15, ipv4(GUEST, "10.0.2.2", 1, ping_marker(NONCE)), ETH0_MAC)),
        (1008.31, sll2(16, ipv4(WLAN, "10.0.2.2", 1, ping_marker(NONCE)), WLAN_MAC)),
        (1008.32, sll2(16, ipv4("10.0.2.2", WLAN, 1, ping_marker(NONCE, 0)), SLIRP_GW_MAC, pkttype=0)),
        # Loopback never leaves the phone, whatever it carries.
        (1009.0, sll2(1, ipv4("127.0.0.1", "127.0.0.1", 17, udp(5000, 53, dns_query("x.example"))),
                      "00:00:00:00:00:00", hatype=772)),
        (1015.0, sll2(16, ipv4(WLAN, "224.0.0.251", 17, udp(5353, 5353, b"\0" * 12)), WLAN_MAC)),
        # The emulator's capture has this one too (eth0, 1030.0): counted once.
        (1028.3, sll2(15, tcp4(GUEST, 40010), ETH0_MAC)),
        (1029.0, sll2(16, tcp4(WLAN, 41000), WLAN_MAC)),
        (1029.2, sll2(16, ipv4("198.51.100.7", WLAN, 6, tcp(9001, 41000, 0x12)), SLIRP_GW_MAC, pkttype=0)),
    ]


class GuestCaptureTest(TempDir):
    """The capture inside the guest: every interface, its own clock."""

    def run_guest(self, gframes, events=(GUEST_STOP,), linktype=276, links=LINKS, extra=(), **kw):
        write_pcap(self.path("g.pcap"), gframes, linktype=linktype)
        args = ["--pcap-iface", "eth0", "--guest-pcap", self.path("g.pcap"),
                "--expect-guest", self.write("ip.txt", "eth0 10.0.2.15/24\nwlan0 10.0.2.16/24\n")]
        if links:
            args += ["--guest-links", self.write("links.txt", links)]
        return self.analyse(base_frames(), expect_seen="198.51.100.7:9001\n", events=events,
                            extra=args + list(extra), **kw)

    def test_pass_with_both_views(self):
        rc, a = self.run_guest(guest_frames())
        self.assertEqual((a["verdict"], rc), ("pass", 0), a["verdict_reasons"])
        g = a["captures"][1]
        self.assertEqual((g["kind"], g["clock"]["markers"]), ("guest", 2))
        self.assertAlmostEqual(g["clock"]["offset_low"], -0.69)
        self.assertAlmostEqual(g["clock"]["offset_high"], 0.3)
        self.assertAlmostEqual(g["cutoff"], 1018.31)
        self.assertEqual(g["totals"]["loopback"], 1)
        self.assertEqual(g["tcpdump"]["dropped"], "0")
        self.assertEqual(a["interfaces"], {"eth0": ["emulator", "guest"], "wlan0": ["guest"]})
        self.assertEqual(a["coverage"]["status"], "complete")
        self.assertIn(WLAN, a["guest"]["addresses"])
        # eth0's tor connection: two packets in the emulator's view, one in
        # the guest's; wlan0's: one more. Each interface counts its largest view.
        flow = [f for f in a["flows"] if f["src"] == GUEST and f["dport"] == 9001][0]
        self.assertEqual(flow["packets"], 2)
        self.assertEqual(sorted(flow["seen"]), ["emulator:eth0", "guest:eth0"])
        self.assertEqual(a["phases"]["post-arm"]["tor-relay"], 3)
        # The markers: eth0's in both views (the emulator's UDP one, the
        # guest's ICMP one: one per interface counts), and wlan0's.
        self.assertEqual(a["phases"]["pre-arm"]["ci-marker"], 2)
        # mDNS on wlan0 before the cutoff is listed, not judged.
        self.assertEqual(a["phases"]["pre-arm"]["LEAK"], 4)
        la.main(["report", "--in", self.path("a.json"), "--json", self.path("r.json"), "--md", self.path("r.md")])
        md = read(self.path("r.md"))
        self.assertIn("inside the guest, every interface", md)
        self.assertIn("wlan0 (guest 1)", md)
        self.assertIn("eth0 (emulator 2, guest 1)", md)

    def test_wlan0_leak_seen_only_inside(self):
        leak = (1040.0, sll2(16, ipv4(WLAN, "224.0.0.251", 17, udp(5353, 5353, b"\0" * 12)), WLAN_MAC))
        rc, a = self.run_guest(guest_frames() + [leak])
        self.assertEqual((a["verdict"], rc), ("fail", 1))
        self.assertEqual([(f["kind"], sorted(f["seen"])) for f in a["leaks"]], [("multicast", ["guest:wlan0"])])

    def test_address_on_the_wrong_interface_is_blind(self):
        # wlan0's address seen only on eth0: wlan0 itself was not seen.
        frames = [(t, f) for t, f in guest_frames() if f[4:8] != struct.pack(">I", 16)]
        frames.append((1029.0, sll2(15, ipv4(WLAN, "198.51.100.7", 6, tcp(41000, 9001)), ETH0_MAC)))
        _, a = self.run_guest(frames)
        self.assertEqual(a["verdict"], "blind")
        self.assertEqual(a["coverage"]["addresses_missing"], ["wlan0 10.0.2.16"])

    def test_capture_problems_are_blind(self):
        no_marker = [f for f in guest_frames() if b"ANTUMBRA" not in f[1]]
        _, a = self.run_guest(no_marker)
        self.assertEqual(a["verdict"], "blind")
        self.assertTrue(any("holds no clock marker" in r for r in a["verdict_reasons"]))
        for events, why in (((), "never stopped"),
                            ((("guest_capture_stop", 1099.0, "captured=10 received=12 dropped=2"),), "dropped 2"),
                            ((("guest_capture_stop", 1099.0, "not running: tcpdump stopped before the end"),),
                             "gave no counters"),
                            ((GUEST_STOP, ("device_clock", 1050.0, "device=1055.0 host_after=1050.1")),
                             "device's clock moved")):
            rc, a = self.run_guest(guest_frames(), events=events)
            self.assertEqual((a["verdict"], rc), ("blind", 3), why)
            self.assertTrue(any(why in r for r in a["verdict_reasons"]), (why, a["verdict_reasons"]))
        # A reading of the device's clock that agrees with the marker is fine.
        _, a = self.run_guest(guest_frames(), events=(GUEST_STOP, ("device_clock", 1050.0,
                                                                   "device=1049.8 host_after=1050.1")))
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        self.assertAlmostEqual(a["captures"][1]["device_clock_moved"], 0.0)

    def test_sll_v1_named_by_hardware_address(self):
        frames = []
        for t, f in guest_frames():
            ifindex, hatype, pkttype = struct.unpack(">IHB", f[4:11])
            frames.append((t, sll(f[20:], ETH0_MAC if ifindex == 15 else WLAN_MAC if pkttype == 4 else SLIRP_GW_MAC,
                                  pkttype=pkttype, hatype=hatype)))
        _, a = self.run_guest(frames, linktype=113)
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        self.assertEqual(a["captures"][1]["totals"]["loopback"], 1)
        self.assertEqual(sorted(a["interfaces"]), ["eth0", "wlan0"])

    def test_module_log(self):
        log = "1970-01-01T00:17:02Z post-fs-data: firewall armed: only loopback until the full rule set is loaded\n"
        _, a = self.run_guest(guest_frames(), extra=["--module-log", self.write("module.log", log)])
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        ma = a["module_arm"]
        self.assertEqual(ma["device_utc"], "1970-01-01T00:17:02Z")
        self.assertAlmostEqual(ma["host_low"], 1021.7)
        self.assertAlmostEqual(ma["host_high"], 1023.69)
        self.assertGreater(ma["after_cutoff"], 0)
        self.assertIn("module log: firewall armed", [e["name"] for e in a["events"]])
        # Logged before install_start by the device's clock: that clock moved,
        # and the capture inside the guest runs on it.
        early = log.replace("00:17:02Z", "00:16:50Z")
        _, a = self.run_guest(guest_frames(), extra=["--module-log", self.write("module.log", early)])
        self.assertEqual(a["verdict"], "blind")
        self.assertTrue(any("before install_start" in r for r in a["verdict_reasons"]))
        # Without that capture it is only a note (the marker's reading of the clock).
        _, a = self.analyse(base_frames(), extra=["--module-log", self.path("module.log")],
                            events=(("clock_marker_after", 1009.0, NONCE + " device=1008.5"),))
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        self.assertTrue(any("before install_start" in n for n in a["notes"]))

    def test_links(self):
        links = la.load_links(self.write("links.txt", LINKS))
        self.assertEqual(links["index"], {1: "lo", 15: "eth0", 16: "wlan0"})
        self.assertEqual(links["mac"], {ETH0_MAC: "eth0", WLAN_MAC: "wlan0"})
        self.assertEqual(links["addr"][WLAN], "wlan0")


STREAMS = """ANTUMBRA-CI-STREAMS connect 120
250 OK
250 OK
650 STREAM 1 NEWRESOLVE 0 check.torproject.org:0 SOURCE_ADDR=127.0.0.1:5000 PURPOSE=DNS_REQUEST
650 STREAM 1 SUCCEEDED 3 check.torproject.org:0
650 STREAM 2 NEW 0 116.202.120.181:443 SOURCE_ADDR=127.0.0.1:40000 PURPOSE=USER
650 STREAM 2 SUCCEEDED 3 116.202.120.181:443
650 STREAM 3 NEW 0 10.0.2.2:80 SOURCE_ADDR=127.0.0.1:40001 PURPOSE=USER
650 STREAM 3 FAILED 0 10.0.2.2:80 REASON=MISC
650 STREAM 4 NEW 0 (Tor_internal):0 PURPOSE=DIR_FETCH
ANTUMBRA-CI-STREAMS connect 300
250 OK
250 OK
650 STREAM 1 NEWRESOLVE 0 connectivitycheck.gstatic.com:0 PURPOSE=DNS_REQUEST
650 STREAM 6 NEW 0 10.192.0.5:80 PURPOSE=USER
650 STREAM 6 REMAP 0 abcdefghijklmnop.onion:80 SOURCE=CACHE
650 STREAM 6 CLOSED 4 abcdefghijklmnop.onion:80 REASON=DONE
"""

FILTER_LOG = """antumbra-dnsfilter: 2026/10/11 06:38:00 debug mode: query names will be logged
antumbra-dnsfilter: 2026/10/11 06:38:19 query "check.torproject.org." A -> forwarded
antumbra-dnsfilter: 2026/10/11 06:38:19 query "doubleclick.net." A -> blocked
antumbra-dnsfilter: 2026/10/11 06:38:20 query "Connectivitycheck.gstatic.com." AAAA -> forwarded
antumbra-dnsfilter: 2026/10/11 06:38:20 query "odd\\x00na\\"me." A -> nxdomain (bad name)
"""

EXPECTED = """# test list
name check.torproject.org
name *.doubleclick.net
target 10.0.2.2:*
target 116.202.120.181:443
"""


class DestinationsTest(TempDir):
    def run_it(self, mode, streams=STREAMS):
        extra = ["--filter-log", self.write("dnsfilter.log", FILTER_LOG),
                 "--expected-destinations", self.write("expected.txt", EXPECTED), "--destinations-mode", mode]
        if streams is not None:
            extra += ["--tor-streams", self.write("streams.txt", streams)]
        return self.analyse(base_frames(), extra=extra)

    def test_parsers(self):
        streams, info = la.load_tor_streams(self.write("s", STREAMS))
        self.assertEqual(info, {"enabled": True, "connections": 2})
        self.assertEqual([s["target"] for s in streams], ["check.torproject.org:0", "116.202.120.181:443", "10.0.2.2:80",
                                                         "(Tor_internal):0", "connectivitycheck.gstatic.com:0",
                                                         "10.192.0.5:80"])
        self.assertEqual(streams[5]["remaps"], ["abcdefghijklmnop.onion:80"])
        q, info = la.load_filter_log(self.write("f", FILTER_LOG))
        self.assertTrue(info["debug"])
        self.assertEqual(q[2], ("connectivitycheck.gstatic.com", "AAAA", "forwarded"))
        self.assertEqual(q[3][0], 'odd\x00na"me')
        exp = la.load_expected_destinations(self.write("e", EXPECTED))
        self.assertTrue(la.name_expected("doubleclick.net", exp["name"]))
        self.assertTrue(la.name_expected("ad.doubleclick.net", exp["name"]))
        self.assertFalse(la.name_expected("notdoubleclick.net", exp["name"]))
        self.assertTrue(la.target_expected("10.0.2.2", 5000, exp["target"]))
        self.assertFalse(la.target_expected("10.0.2.3", 53, exp["target"]))
        with self.assertRaises(ValueError):
            la.load_expected_destinations(self.write("bad", "target 1.2.3.4\n"))

    def test_learning(self):
        _, a = self.run_it("learning")
        self.assertEqual(a["verdict"], "pass", a["verdict_reasons"])
        d = a["destinations"]
        self.assertEqual(d["status"], "unexpected")
        self.assertEqual(len(d["unexpected"]), 2)
        self.assertTrue(d["unexpected"][0].startswith("name connectivitycheck.gstatic.com"))
        self.assertTrue(d["unexpected"][1].startswith("target 10.192.0.5:80"))
        blocked = [r for r in d["names"] if r["name"] == "doubleclick.net"][0]
        self.assertEqual((blocked["reached"], blocked["expected"]), (False, True))
        self.assertTrue(any("learning mode" in n for n in a["notes"]))
        la.main(["report", "--in", self.path("a.json"), "--json", self.path("r.json"), "--md", self.path("r.md")])
        md = read(self.path("r.md"))
        self.assertIn("Names and destinations through Tor", md)
        self.assertIn("abcdefghijklmnop.onion", md)

    def test_strict(self):
        rc, a = self.run_it("strict")
        self.assertEqual((a["verdict"], rc), ("fail", 1))
        self.assertIn("unexpected", a["verdict_reasons"][-1])
        rc, a = self.run_it("strict", streams=None)
        self.assertEqual((a["verdict"], rc), ("blind", 3))
        self.assertEqual(a["destinations"]["status"], "not-recorded")
        rc, a = self.run_it("strict", streams="ANTUMBRA-CI-STREAMS connect 1\n515 Authentication failed\n")
        self.assertEqual(a["destinations"]["status"], "not-recorded")
        # SETEVENTS refused; a later GETINFO's OK does not count.
        rc, a = self.run_it("strict", streams="ANTUMBRA-CI-STREAMS connect 1\n250 OK\n552 Unrecognized event\n"
                                              "250-version=0.4.9.3\n250 OK\n")
        self.assertEqual(a["destinations"]["status"], "not-recorded")


class CitoolTest(TempDir):
    XML = """<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0">
<node index="0" text="" resource-id="" bounds="[0,0][1080,2400]">
<node index="1" text="Connect to Tor directly" resource-id="tor_direct" checked="true" bounds="[42,300][1038,420]"/>
<node index="2" text="Administration" resource-id="org.antumbra.welcome:id/switch_admin" checked="false" enabled="true" bounds="[42,900][1038,1020]"/>
<node index="3" text="" content-desc="Start Antumbra" resource-id="" bounds="[100,2200][980,2340]"/>
<node index="4" text="Zero" resource-id="zero" bounds="[5,5][5,9]"/>
</node></hierarchy>"""

    def test_ui_find(self):
        self.assertEqual(citool.ui_find(self.XML, "tor_direct"), (540, 360, "true", "true"))
        self.assertEqual(citool.ui_find(self.XML, "switch_admin"), (540, 960, "false", "true"))
        self.assertEqual(citool.ui_find(self.XML, "start_button", "^start antumbra$"), (540, 2270, "false", "true"))
        self.assertIsNone(citool.ui_find(self.XML, "zero"))
        self.assertIsNone(citool.ui_find("<not xml", "x"))
        # The tag wins over an earlier node whose text matches.
        self.assertEqual(citool.ui_find(self.XML, "switch_admin", "Connect|Administration"), (540, 960, "false", "true"))

    def test_dns_over_tcp(self):
        def serve(sock, rcode, answer):
            conn, _ = sock.accept()
            with conn:
                n = struct.unpack(">H", conn.recv(2))[0]
                q = b""
                while len(q) < n:
                    q += conn.recv(n - len(q))
                qid = q[:2]
                question = q[12:]
                resp = qid + struct.pack(">HHHHH", 0x8180 | rcode, 1, 1 if answer else 0, 0, 0) + question
                if answer:
                    resp += b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton(answer)
                conn.sendall(struct.pack(">H", len(resp)) + resp)

        for rcode, answer, want_blocked in ((3, None, True), (0, "0.0.0.0", True), (0, "198.51.100.9", False)):
            with socket.socket() as s:
                s.bind(("127.0.0.1", 0))
                s.listen(1)
                t = threading.Thread(target=serve, args=(s, rcode, answer))
                t.start()
                res = citool.dns_query_tcp("127.0.0.1", s.getsockname()[1], "doubleclick.net", timeout=5)
                t.join(5)
            self.assertEqual(res["rcode"], {3: "NXDOMAIN", 0: "NOERROR"}[rcode])
            self.assertEqual(citool.blocked(res), want_blocked)
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        res = citool.dns_query_tcp("127.0.0.1", port, "x.example", timeout=2)
        self.assertIsNone(res["rcode"])
        self.assertFalse(citool.blocked(res))

    def test_json_get_and_pack(self):
        p = self.write("s.json", json.dumps({"module": {"tor": {"bootstrap": 100, "ok": True}}, "l": [1, 2]}))
        self.assertEqual(citool.json_get(p, "module.tor.bootstrap"), "100")
        self.assertEqual(citool.json_get(p, "module.tor.ok"), "true")
        self.assertEqual(citool.json_get(p, "l.1"), "2")
        self.assertEqual(citool.json_get(p, "module.nothing"), "")
        self.assertEqual(citool.json_get(self.path("missing.json"), "a"), "")
        root = os.path.join(self.dir, "art")
        self.write("art/capture/big.pcap", b"x" * 900000)
        self.write("art/logs/a.txt", b"y" * 300000)
        self.write("art/screenshots/s.png", b"z" * 100000)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(citool.pack(root, 1, ["capture/*.pcap"]), 0)
        self.assertFalse(os.path.exists(os.path.join(root, "capture/big.pcap")))
        self.assertTrue(os.path.exists(os.path.join(root, "logs/a.txt")))
        self.assertIn("capture/big.pcap", read(os.path.join(root, "omitted.txt")))


class SummaryTest(TempDir):
    def scenario(self, name, result, checks, verdict):
        self.write("r/%s/result" % name, "%s\n" % result)
        self.write("r/%s/checks.tsv" % name, "".join("%s\t%s\t%s\n" % c for c in checks))
        self.write("r/%s/events.tsv" % name, "welcome_start\t10.0\t\ntor_bootstrapped\t40.0\tfrom /status\n")
        self.write("r/%s/analysis.json" % name, json.dumps({"verdict": verdict, "verdict_reasons": ["r"],
                                                             "flows": [], "leaks": [], "phases": {}}))

    def test_judge(self):
        root = self.path("r")
        self.scenario("baseline", 0, [("system_ready", "ok", "")], "info")
        self.scenario("antumbra", 0, [("tor_bootstrap", "ok", "100%")], "pass")
        ok, problems, _ = summary.judge(root)
        self.assertTrue(ok, problems)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(summary.main([root, "--verdict"]), 0)
            summary.main([root, "--run", "7"])
        self.assertIn("CI run 7: PASS", read(os.path.join(root, "summary.md")))
        self.assertIn("Tor bootstrapped 30 s after", read(os.path.join(root, "summary.md")))
        self.scenario("antumbra", 1, [("tracker_blocked:x", "fail", "not blocked")], "fail")
        ok, problems, _ = summary.judge(root)
        self.assertFalse(ok)
        self.assertEqual(len(problems), 2)
        os.remove(os.path.join(root, "baseline", "result"))
        ok, problems, _ = summary.judge(root)
        self.assertIn("did not run to the end", problems[0])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(summary.main([root, "--verdict"]), 1)
            # Written before the artifact is uploaded, judged afterwards.
            self.assertEqual(summary.main([root, "--verdict", "--no-fail"]), 0)
            self.assertEqual(summary.main([root, "--check"]), 1)
        self.assertFalse(json.loads(read(os.path.join(root, "verdict.json")))["ok"])
        self.scenario("baseline", 0, [("system_ready", "ok", "")], "info")
        self.scenario("antumbra", 0, [("tor_bootstrap", "ok", "100%"), ("wifi_mac_new", "warn", "same")], "pass")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(summary.main([root, "--verdict", "--no-fail"]), 0)
            self.assertEqual(summary.main([root, "--check"]), 0)
        self.assertEqual(json.loads(read(os.path.join(root, "verdict.json")))["warnings"],
                         ["antumbra: wifi_mac_new: same"])
        os.remove(os.path.join(root, "verdict.json"))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(summary.main([root, "--check"]), 1)

    def test_captures_and_seen_on(self):
        root = self.path("r")
        self.scenario("baseline", 0, [], "info")
        self.scenario("antumbra", 0, [], "fail")
        leak = {"first": 1.0, "kind": "multicast", "dst": "224.0.0.251", "dport": 5353, "names": [],
                "phases": {"post-arm": 3}, "reason": "UDP to a group", "seen": {"guest:wlan0": {"packets": 3}}}
        self.write("r/antumbra/analysis.json", json.dumps({
            "verdict": "fail", "verdict_reasons": ["r"], "flows": [], "leaks": [leak], "phases": {},
            "captures": [{"name": "antumbra.pcap", "kind": "emulator"},
                         {"name": "antumbra-guest.pcap", "kind": "guest"}]}))
        with contextlib.redirect_stdout(io.StringIO()):
            summary.main([root, "--run", "8"])
        text = read(os.path.join(root, "summary.md"))
        self.assertIn("`antumbra-guest.pcap` (inside the guest, every interface)", text)
        self.assertIn("| Seen on |", text)
        self.assertIn("| 3 | wlan0 |", text)


if __name__ == "__main__":
    unittest.main()
