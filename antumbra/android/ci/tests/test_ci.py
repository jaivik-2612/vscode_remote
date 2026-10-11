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


def dhcp(msgtype, chaddr, hostname=None, vendor=None, requested=None, ciaddr="0.0.0.0"):
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
    return b + b"\xff"


def out4(dst, l4, proto, src=GUEST, src_mac=GUEST_MAC):
    return eth(src_mac, SLIRP_GW_MAC, 0x0800, ipv4(src, dst, proto, l4))


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


def events_text(arm=True):
    lines = ["boot_completed\t995.0\t", "clock_marker_before\t1008.0\t" + NONCE, "clock_marker_after\t1009.0\t" + NONCE]
    if arm:
        lines.append("install_start\t%s\t" % ARM_HOST)
    lines.append("capture_stop\t1100.0\t")
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
        (1034.0, out4("10.0.2.2", udp(68, 67, dhcp(3, GUEST_MAC, requested=GUEST, ciaddr=GUEST)), 17)),
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

    def analyse(self, frames, arm=True, extra=(), consensus=True, expect_seen=None, require_tor=True):
        write_pcap(self.path("c.pcap"), frames)
        args = ["analyse", "--scenario", "t", "--pcap", self.path("c.pcap"),
                "--events", self.write("events.tsv", events_text(arm)), "--out", self.path("a.json"),
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
        sll2 = struct.pack(">HHIHBB8s", 0x0800, 0, 3, 1, 4, 6, mac(GUEST_MAC) + b"\0\0") + body
        p = pcapread.decode(pcapread.Record(0, 276, sll2, 0))
        self.assertEqual((p.direction_hint, p.dport), ("out", 9001))

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
        self.assertEqual(td.lookup("198.51.100.8", 80)[0], "tor-directory")  # DirPort
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


if __name__ == "__main__":
    unittest.main()
