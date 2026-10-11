#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra CI: the leak analyser for the Android emulator's packet captures.

Lists every packet the emulated phone (the "guest") sent, groups them into
flows, and classifies each flow as one of:

  tor-relay      TCP to the ORPort of a relay in the consensus that the
                 phone's tor downloaded (cached-microdesc-consensus)
  tor-directory  TCP to a directory authority or a fallback directory
                 compiled into tor (from the consensus's dir-source lines
                 and from the tor binary's strings), which tor contacts
                 before it has a consensus
  bridge         TCP to a bridge the session configured
  lan-dhcp       a DHCP client message (UDP 68 to 67) to the broadcast
                 address or a local server: link configuration, which
                 Android sends from a packet socket outside the firewall
                 on purpose (the design allows it for NetworkStack)
  link-arp       ARP: link-level address resolution, never routed
  link-80211     802.11 association and power-save frames (in a capture
                 of the Wi-Fi radio, such as netsim's)
  ci-marker      the clock marker this CI sends before the module is
                 installed (see "Clocks" below); never after arm
  LEAK           anything else, with a kind: dns, tcp, udp, lan, icmp,
                 ipv6, multicast, dhcp, fragment, unattributed, undecoded,
                 other

Emulator infrastructure that is not the guest's own traffic, and is
therefore not listed: every frame sent by the emulator's user-mode network
(QEMU slirp) itself. Its virtual hosts use MAC addresses 52:55:<IPv4> and
52:56:<IPv6>: 10.0.2.2 (the host's loopback alias, gateway and DHCP
server), 10.0.2.3 to 10.0.2.6 (DNS forwarders), fec0::2 and fec0::3. The
guest's own packets TO those hosts are listed: a lookup sent to 10.0.2.3
is the phone's own DNS leaving outside Tor (on a phone, to the Wi-Fi
router's resolver) and is a LEAK; TCP to 10.0.2.2 reaches the machine
running the emulator (on a phone, the local network) and is a LEAK.

Which addresses are the guest's: those given with --guest, or else every
private, link-local or site-local address seen acting as a client (sending
a TCP SYN, a query to a low UDP port, an ARP request, an echo request, an
IPv6 router or neighbour solicitation, a DHCP request) from a MAC address
that is not slirp's, leaving out slirp's own addresses. A frame from one of
the guest's MAC addresses with a source address that is not the guest's
is counted too, as "unattributed" (a forged source).

Clocks. pcap time stamps come from the emulator, the scenario's events
(events.tsv) from the CI host. Before the module is installed the
scenario sends one UDP datagram "ANTUMBRA-CLOCK <nonce>" to 10.0.2.2:9 and
records the host time just before and just after. The analyser finds that
datagram and so knows the offset between the two clocks to within that
interval. The arm cutoff is the host time of the arm event (taken just
before the module's installation starts, so before 'antumbra-fw arm' ran)
moved into the capture's clock with the lower bound of the offset, minus
a margin. Every packet at or after the cutoff counts. The cutoff can only
be early, never late, so a packet near it is counted rather than missed;
the scenario keeps the phone in airplane mode around the installation so
that nothing is sent near it.

Verdicts: "pass" (zero LEAK after arm, the capture saw the guest, and,
when asked, saw Tor traffic and every connection tor reported), "fail"
(a LEAK after arm), "blind" (the capture missed the guest's traffic: it
cannot prove anything), "error" (an input is missing or unreadable), and
"info" for a scenario without an arm event (the baseline).

Usage:
  leak_analyser.py analyse --scenario NAME --pcap FILE [--pcap FILE...]
      [--events FILE] [--arm-event NAME] [--arm-margin SECONDS]
      [--consensus FILE] [--tor-binary FILE] [--bridges FILE]
      [--guest ADDR...] [--expect-seen FILE] [--require-tor-traffic]
      --out FILE.json
  leak_analyser.py report --in FILE.json [--in FILE.json...] --json OUT --md OUT
  leak_analyser.py tor-conns [--uid 2950] PROC_NET_TCP_FILE...
  leak_analyser.py listeners [--proto tcp|udp] PROC_NET_FILE...
  leak_analyser.py slim IN.pcap OUT.pcap [--snaplen 256]

Exit status of analyse: 0 pass or info, 1 fail, 2 error, 3 blind.
"""

import argparse
import datetime
import hashlib
import ipaddress
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pcapread  # noqa: E402

SCHEMA = 1
TOR_UID = 2950

SLIRP_MAC_PREFIXES = ("52:55:", "52:56:")
SLIRP_V4 = {
    "10.0.2.1": "emulator gateway",
    "10.0.2.2": "emulator host alias, gateway and DHCP server",
    "10.0.2.3": "emulator DNS forwarder",
    "10.0.2.4": "emulator DNS forwarder",
    "10.0.2.5": "emulator DNS forwarder",
    "10.0.2.6": "emulator DNS forwarder",
}
SLIRP_V6 = {"fec0::2": "emulator host alias", "fec0::3": "emulator DNS forwarder"}
SLIRP_DNS = {"10.0.2.3", "10.0.2.4", "10.0.2.5", "10.0.2.6", "fec0::3"}
MARKER = b"ANTUMBRA-CLOCK "
# The phone's own network: RFC 1918, shared (carrier-grade NAT), link-local,
# unique-local and site-local addresses. Python's is_private is wider (it
# also covers documentation and benchmark ranges), so it is not used.
LOCAL_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10",
    "fc00::/7", "fe80::/10", "fec0::/10")]

ALLOWED = ("tor-relay", "tor-directory", "bridge", "lan-dhcp", "link-arp", "link-80211", "ci-marker")
LEAK = "LEAK"
CLASS_ORDER = ("tor-relay", "tor-directory", "bridge", "lan-dhcp", "link-arp", "link-80211",
               "ci-marker", LEAK)

EXIT = {"pass": 0, "info": 0, "fail": 1, "error": 2, "blind": 3}

MAX_FLOWS_JSON = 5000


# ---------------------------------------------------------------------------
# Inputs
# ---------------------------------------------------------------------------

def ip_or_none(s):
    try:
        return ipaddress.ip_address(s)
    except ValueError:
        return None


def is_local(addr):
    """Private, link-local, site-local or shared: an address on the
    phone's own network, never a Tor relay."""
    ip = ip_or_none(addr)
    if ip is None:
        return False
    return any(ip.version == n.version and ip in n for n in LOCAL_NETS)


def is_group(addr):
    """Multicast, the limited broadcast, or a local /24's broadcast."""
    ip = ip_or_none(addr)
    if ip is None:
        return False
    if ip.is_multicast or str(ip) == "255.255.255.255":
        return True
    return ip.version == 4 and ip.packed[3] == 255 and is_local(addr)


def slirp_service(addr):
    return SLIRP_V4.get(addr) or SLIRP_V6.get(addr)


def slirp_mac(mac):
    return bool(mac) and mac.startswith(SLIRP_MAC_PREFIXES)


class TorDirectory:
    """The addresses tor may legitimately connect to."""

    def __init__(self):
        self.orports = {}   # (ip, port) -> (class, label)
        self.dirports = {}  # (ip, port) -> (class, label)
        self.bridges = {}   # (ip, port) -> label
        self.info = {"consensus": None, "tor_binary": None, "bridges": 0}

    def add_or(self, ip, port, cls, label, overwrite=False):
        key = (str(ipaddress.ip_address(ip)), int(port))
        if overwrite or key not in self.orports:
            self.orports[key] = (cls, label)

    def lookup(self, ip, port):
        hit = self.orports.get((ip, port)) or self.dirports.get((ip, port))
        if hit:
            return hit
        if (ip, port) in self.bridges:
            return ("bridge", self.bridges[(ip, port)])
        return None


def load_consensus(tordir, path):
    with open(path, "rb") as f:
        raw = f.read()
    text = raw.decode("utf-8", "replace")
    relays = 0
    authorities = 0
    valid_after = None
    nick = None
    for line in text.splitlines():
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "valid-after" and len(parts) >= 3:
            valid_after = parts[1] + " " + parts[2]
        elif parts[0] == "r" and len(parts) >= 8:
            # r nickname identity [digest] date time IP ORPort DirPort
            nick = parts[1]
            ip, orport, dirport = parts[-3], parts[-2], parts[-1]
            if ip_or_none(ip) is None or not orport.isdigit():
                continue
            tordir.add_or(ip, orport, "tor-relay", "relay " + nick, overwrite=True)
            if dirport.isdigit() and int(dirport):
                tordir.dirports[(ip, int(dirport))] = ("tor-directory", "relay %s (DirPort)" % nick)
            relays += 1
        elif parts[0] == "a" and len(parts) >= 2 and nick:
            m = re.match(r"^\[([0-9a-fA-F:.]+)\]:(\d+)$", parts[1])
            if m and ip_or_none(m.group(1)):
                tordir.add_or(m.group(1), m.group(2), "tor-relay", "relay %s (IPv6)" % nick, overwrite=True)
        elif parts[0] == "dir-source" and len(parts) >= 7:
            # dir-source nickname identity address IP dirport orport
            name, ip, dirport, orport = parts[1], parts[4], parts[5], parts[6]
            if ip_or_none(ip) is None:
                continue
            if orport.isdigit():
                tordir.add_or(ip, orport, "tor-directory", "authority " + name)
            if dirport.isdigit() and int(dirport):
                tordir.dirports[(ip, int(dirport))] = ("tor-directory", "authority %s (DirPort)" % name)
            authorities += 1
    if relays == 0:
        raise ValueError("%s has no relay ('r') lines: not a consensus" % path)
    tordir.info["consensus"] = {
        "path": path, "sha256": hashlib.sha256(raw).hexdigest(), "valid_after": valid_after,
        "relays": relays, "authorities": authorities,
        "flavour": "microdesc" if "network-status-version 3 microdesc" in text else "ns",
    }


# "193.11.114.43:80 orport=9001 id=<40 hex>" (fallback_dirs.inc) and
# "moria1 orport=9201 ... 128.31.0.39:9231 <fingerprint>" (auth_dirs.inc),
# both compiled into tor as C string literals.
_FALLBACK_RE = re.compile(rb"(?<![0-9.])(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{1,5}))? orport=(\d{1,5}) id=([0-9A-F]{40})")
_AUTHORITY_RE = re.compile(rb"([A-Za-z][A-Za-z0-9]{0,18}) orport=(\d{1,5})[^\x00\"]{0,400}? (\d{1,3}(?:\.\d{1,3}){3}):(\d{1,5}) ")


def load_tor_binary(tordir, path):
    with open(path, "rb") as f:
        data = f.read()
    fallbacks = 0
    authorities = 0
    for m in _FALLBACK_RE.finditer(data):
        ip = m.group(1).decode()
        if ip_or_none(ip) is None:
            continue
        fp = m.group(4).decode()
        tordir.add_or(ip, m.group(3).decode(), "tor-directory", "fallback directory " + fp[:8])
        if m.group(2) and int(m.group(2)):
            tordir.dirports.setdefault((ip, int(m.group(2))), ("tor-directory", "fallback directory %s (DirPort)" % fp[:8]))
        fallbacks += 1
    for m in _AUTHORITY_RE.finditer(data):
        name, ip = m.group(1).decode(), m.group(3).decode()
        if ip_or_none(ip) is None:
            continue
        tordir.add_or(ip, m.group(2).decode(), "tor-directory", "authority " + name)
        tordir.dirports.setdefault((ip, int(m.group(4))), ("tor-directory", "authority %s (DirPort)" % name))
        authorities += 1
    tordir.info["tor_binary"] = {"path": path, "sha256": hashlib.sha256(data).hexdigest(),
                                 "fallbacks": fallbacks, "authorities": authorities}


_BRIDGE_ADDR_RE = re.compile(r"(?:^|\s)(\d{1,3}(?:\.\d{1,3}){3}|\[[0-9a-fA-F:.]+\]):(\d{1,5})(?=\s|$)")


def load_bridges(tordir, path):
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    n = 0
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.lower().startswith("bridge "):
            line = line[7:]
        m = _BRIDGE_ADDR_RE.search(line)
        if not m:
            continue
        ip = m.group(1).strip("[]")
        if ip_or_none(ip) is None:
            continue
        transport = line.split()[0] if not _BRIDGE_ADDR_RE.match(line) else "vanilla"
        tordir.bridges[(str(ipaddress.ip_address(ip)), int(m.group(2)))] = "bridge (%s)" % transport
        n += 1
    tordir.info["bridges"] = n


def load_events(path):
    """[(name, host_time, detail)] from a TSV file: NAME TAB TIME [TAB DETAIL]."""
    events = []
    if not path:
        return events
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            try:
                t = float(parts[1])
            except ValueError:
                continue
            events.append((parts[0], t, parts[2] if len(parts) > 2 else ""))
    return events


def _hex_addr(h):
    b = bytes.fromhex(h)
    if len(b) == 4:
        return str(ipaddress.IPv4Address(b[::-1]))
    if len(b) == 16:
        words = [b[i:i + 4][::-1] for i in range(0, 16, 4)]
        ip = ipaddress.IPv6Address(b"".join(words))
        return str(ip.ipv4_mapped) if ip.ipv4_mapped else str(ip)
    raise ValueError("bad address " + h)


def parse_proc_net_tcp(text, uid=TOR_UID):
    """Remote (address, port) of every ESTABLISHED socket of uid in the
    text of /proc/net/tcp or tcp6, leaving out loopback peers."""
    out = []
    for line in text.splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":") or f[3] != "01":
            continue
        try:
            if int(f[7]) != uid:
                continue
            raddr, rport = f[2].split(":")
            addr = _hex_addr(raddr)
            port = int(rport, 16)
        except ValueError:
            continue
        if ipaddress.ip_address(addr).is_loopback:
            continue
        out.append((addr, port))
    return sorted(set(out))


def parse_proc_net_listeners(text, proto="tcp"):
    """[(uid, address, port)] of the listening TCP sockets (state 0A), or
    of the bound, unconnected UDP sockets (state 07), in the text of
    /proc/net/{tcp,tcp6} or /proc/net/{udp,udp6}."""
    want = "0A" if proto == "tcp" else "07"
    out = []
    for line in text.splitlines():
        f = line.split()
        if len(f) < 8 or not f[0].endswith(":") or f[3] != want:
            continue
        try:
            laddr, lport = f[1].split(":")
            out.append((int(f[7]), _hex_addr(laddr), int(lport, 16)))
        except ValueError:
            continue
    return sorted(set(out))


def load_expect_seen(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            m = re.match(r"^\[?([0-9a-fA-F:.]+?)\]?:(\d+)$", line)
            if m and ip_or_none(m.group(1)):
                out.append((str(ipaddress.ip_address(m.group(1))), int(m.group(2))))
    return out


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

def client_evidence(p):
    """True when p looks like it was sent by a client (the guest), not a
    server answering it."""
    if p.direction_hint == "out":
        return True
    if p.proto == "tcp":
        return p.tcp_syn_only
    if p.proto == "udp":
        if p.sport == 68 and p.dport == 67:
            return True
        if is_group(p.dst):
            return True  # mDNS, SSDP, LLMNR and the like
        return p.dport is not None and p.dport < 1024 and p.sport >= 1024
    if p.proto == "icmp":
        return p.icmp_type == 8
    if p.proto == "icmpv6":
        return p.icmp_type in (128, 131, 133, 135, 143)
    if p.proto == "arp":
        return p.arp_op == 1
    return False


def find_guest(packets, explicit):
    guest = set(str(ipaddress.ip_address(a)) for a in explicit)
    if not guest:
        for p in packets:
            if p.l3 is None or slirp_mac(p.src_mac) or not client_evidence(p):
                continue
            if is_local(p.src) and not slirp_service(p.src):
                guest.add(p.src)
    macs = set()
    for p in packets:
        if p.src in guest and p.src_mac and not slirp_mac(p.src_mac):
            macs.add(p.src_mac)
    return guest, macs


def find_clock(packets, events):
    """Offset (capture time minus host time) from the clock marker."""
    before = {d: t for n, t, d in events if n == "clock_marker_before"}
    after = {d: t for n, t, d in events if n == "clock_marker_after"}
    for p in packets:
        if p.proto != "udp" or not p.payload.startswith(MARKER):
            continue
        words = p.payload[len(MARKER):].split()
        nonce = words[0].decode("ascii", "replace") if words else ""
        if nonce in before and nonce in after:
            low, high = p.ts - after[nonce], p.ts - before[nonce]
            return {"source": "marker", "nonce": nonce, "offset_low": low, "offset_high": high,
                    "offset": (low + high) / 2}
    return {"source": "none", "nonce": None, "offset_low": 0.0, "offset_high": 0.0, "offset": 0.0}


def app_name(p):
    if p.proto in ("udp", "tcp") and p.dport == 53:
        q = pcapread.dns_question(p.payload, tcp=(p.proto == "tcp"))
        if q and not q[2]:
            return q[0]
        return None
    if p.proto == "tcp" and p.payload:
        return pcapread.tls_sni(p.payload) or pcapread.http_host(p.payload)
    return None


def classify(p, tordir, marker_nonce, phase):
    """(class, kind, reason, label) for one outbound packet."""
    if p.proto == "arp":
        return ("link-arp", None, "ARP: link-level, never routed", "who-has " + (p.dst or "?"))
    if (marker_nonce and phase != "post-arm" and p.proto == "udp"
            and p.payload.startswith(MARKER + marker_nonce.encode())):
        return ("ci-marker", None, "the CI's clock marker, sent before the module was installed", None)
    hit = tordir.lookup(p.dst, p.dport) if p.proto == "tcp" else None
    if p.l3 == "ipv6":
        why = "IPv6 must not leave the phone at all (it is switched off on every interface)"
        if hit:
            why += "; this is to " + hit[1]
        return (LEAK, "ipv6", why, hit[1] if hit else None)
    if p.proto == "udp" and p.sport == 68 and p.dport == 67:
        if p.dst == "255.255.255.255" or is_local(p.dst):
            return ("lan-dhcp", None, "DHCP to the local network (sent outside the firewall by design)", None)
        return (LEAK, "dhcp", "DHCP to an address outside the local network", None)
    if p.dst in SLIRP_DNS and p.dport == 53:
        return (LEAK, "dns", "DNS to the emulator's resolver: a lookup outside Tor "
                "(on the phone, the Wi-Fi router's resolver)", SLIRP_V4.get(p.dst) or SLIRP_V6.get(p.dst))
    if p.proto == "tcp":
        if hit:
            return (hit[0], None, "Tor network", hit[1])
        if p.dport == 853:
            return (LEAK, "dns", "DNS over TLS outside Tor (Android's Private DNS)", slirp_service(p.dst))
        if is_local(p.dst) or slirp_service(p.dst):
            return (LEAK, "lan", "TCP to the local network or the machine running the emulator",
                    slirp_service(p.dst))
        return (LEAK, "tcp", "TCP to an address that is neither a Tor relay nor a configured bridge", None)
    if p.proto == "udp":
        if p.dport == 53:
            return (LEAK, "dns", "DNS sent straight to a server, outside the filter and Tor", None)
        if is_group(p.dst):
            return (LEAK, "multicast", "UDP to a broadcast or multicast group on the local network", None)
        if is_local(p.dst) or slirp_service(p.dst):
            return (LEAK, "lan", "UDP to the local network or the machine running the emulator",
                    slirp_service(p.dst))
        return (LEAK, "udp", "UDP: Tor never uses it", None)
    if p.proto == "icmp":
        return (LEAK, "icmp", "ICMP type %s" % p.icmp_type, None)
    if p.proto == "fragment":
        return (LEAK, "fragment", "an IP fragment without ports (Tor's TCP is never fragmented)", None)
    return (LEAK, "other", "protocol %s" % p.proto, None)


def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def analyse(args):
    notes = []
    errors = []
    result = {
        "schema": SCHEMA, "scenario": args.scenario, "verdict": None, "verdict_reasons": [],
        "generated": iso(datetime.datetime.now(datetime.timezone.utc).timestamp()),
    }

    # The Tor network.
    tordir = TorDirectory()
    if args.consensus:
        try:
            load_consensus(tordir, args.consensus)
        except (OSError, ValueError) as e:
            errors.append("consensus: %s" % e)
    if args.tor_binary:
        try:
            load_tor_binary(tordir, args.tor_binary)
        except OSError as e:
            notes.append("tor binary not read (%s): fallback directories are not known" % e)
    if args.bridges:
        try:
            load_bridges(tordir, args.bridges)
        except OSError as e:
            errors.append("bridges: %s" % e)

    # The captures.
    records = []
    captures = []
    for path in args.pcap:
        try:
            recs, info = pcapread.read_capture(path)
        except (OSError, pcapread.CaptureError) as e:
            errors.append("capture: %s" % e)
            continue
        d = info.as_dict()
        with open(path, "rb") as f:
            d["sha256"] = hashlib.sha256(f.read()).hexdigest()
        unsupported = sorted(set(info.linktypes) - pcapread.SUPPORTED_LINKTYPES)
        if unsupported:
            notes.append("%s: link types %s are not decoded" % (path, unsupported))
        if info.truncated:
            notes.append("%s ends in the middle of a record; read up to the last whole one" % path)
        captures.append(d)
        records.extend(recs)
    records.sort(key=lambda r: r.ts)
    packets = [pcapread.decode(r) for r in records]
    result["captures"] = captures
    result["tor_directory"] = dict(tordir.info, orports=len(tordir.orports))

    events = []
    if args.events:
        try:
            events = load_events(args.events)
        except OSError as e:
            errors.append("events: %s" % e)

    first = packets[0].ts if packets else None
    clock = find_clock(packets, events)
    result["clock"] = clock
    if clock["source"] == "none" and args.arm_event:
        notes.append("no clock marker found: the capture's clock is taken to be the host's, "
                     "with a wider margin")

    cutoff = None
    arm_host = None
    if args.arm_event:
        times = [t for n, t, _ in events if n == args.arm_event]
        if times:
            arm_host = times[0]
            margin = args.arm_margin if args.arm_margin is not None else (
                1.0 if clock["source"] == "marker" else 3.0)
            cutoff = arm_host + clock["offset_low"] - margin
            result["arm"] = {"event": args.arm_event, "host_time": arm_host, "margin": margin,
                             "cutoff": cutoff, "cutoff_utc": iso(cutoff),
                             "cutoff_t": (cutoff - first) if first is not None else None}
        else:
            errors.append("the arm event '%s' is not in the events file" % args.arm_event)
            result["arm"] = None
    else:
        result["arm"] = None

    result["events"] = [
        {"name": n, "host_time": t, "detail": d, "capture_time": t + clock["offset"],
         "t": (t + clock["offset"] - first) if first is not None else None}
        for n, t, d in events
    ]

    guest, guest_macs = find_guest(packets, args.guest or [])
    result["guest"] = {"addresses": sorted(guest), "macs": sorted(guest_macs),
                       "source": "given" if args.guest else "detected"}

    totals = {"frames": len(packets), "outbound": 0, "from_emulator": 0, "to_guest": 0,
              "unattributed": 0, "undecoded": 0}
    flows = {}
    phase_counts = {}
    names = {}
    undecoded_notes = {}
    for p in packets:
        if cutoff is None:
            phase = "baseline"
        else:
            phase = "post-arm" if p.ts >= cutoff else "pre-arm"
        if p.l3 is None:
            totals["undecoded"] += 1
            note = p.note or ("EtherType 0x%04x" % p.ethertype if p.ethertype is not None else "not decoded")
            undecoded_notes[note] = undecoded_notes.get(note, 0) + 1
            if p.src_mac in guest_macs:
                # Something the guest sent that has no IP header here.
                if note.startswith(("802.11 management", "802.11 null")):
                    cls = ("link-80211", None, "802.11 association or power-save frame", p.src_mac)
                else:
                    cls = (LEAK, "undecoded", "a frame from the guest's MAC address that this "
                           "analyser cannot read (%s)" % note, p.src_mac)
                totals["outbound"] += 1
                _add_flow(flows, ("link", note, p.src_mac, p.dst_mac), p, cls, phase, None)
                phase_counts.setdefault(phase, {}).setdefault(cls[0], 0)
                phase_counts[phase][cls[0]] += 1
            continue
        unspecified_src = p.src in ("0.0.0.0", "::") and p.src_mac is not None and not slirp_mac(p.src_mac)
        out = (p.direction_hint == "out" or p.src in guest or unspecified_src)
        if p.direction_hint == "in":
            out = False
        if not out:
            if slirp_mac(p.src_mac) or slirp_service(p.src):
                totals["from_emulator"] += 1
            elif p.dst in guest:
                totals["to_guest"] += 1
            elif p.src_mac in guest_macs and p.l3 in ("ipv4", "ipv6"):
                # From the guest's own MAC address, but with a source address
                # that is not the guest's: a forged or unexpected source.
                totals["unattributed"] += 1
                if phase != "pre-arm":
                    key = ("unattributed", p.l3, p.proto, p.src, p.dst)
                    _add_flow(flows, key, p, (LEAK, "unattributed",
                                              "sent from the guest's MAC address with a source "
                                              "address that is not the guest's", None), phase, None)
                    phase_counts.setdefault(phase, {}).setdefault(LEAK, 0)
                    phase_counts[phase][LEAK] += 1
            else:
                totals["unattributed"] += 1
            continue
        totals["outbound"] += 1
        cls = classify(p, tordir, clock["nonce"], phase)
        name = app_name(p)
        if p.proto in ("tcp", "udp"):
            key = (p.l3, p.proto, p.src, p.sport, p.dst, p.dport)
        elif p.proto in ("icmp", "icmpv6"):
            key = (p.l3, p.proto, p.src, p.icmp_type, p.dst, None)
        else:
            key = (p.l3, p.proto, p.src, None, p.dst, None)
        _add_flow(flows, key, p, cls, phase, name)
        phase_counts.setdefault(phase, {}).setdefault(cls[0], 0)
        phase_counts[phase][cls[0]] += 1
        if name and p.dport == 53:
            nk = (phase, name)
            names[nk] = names.get(nk, 0) + 1

    flow_list = sorted(flows.values(), key=lambda f: f["first_ts"])
    for f in flow_list:
        f["first"] = round(f["first_ts"] - first, 3) if first is not None else None
        f["last"] = round(f["last_ts"] - first, 3) if first is not None else None
        f["first_utc"] = iso(f["first_ts"])
        f["names"] = sorted(f["names"])
        del f["first_ts"], f["last_ts"]
    leaks = [f for f in flow_list if f["class"] == LEAK and f["phases"].get("post-arm", 0) > 0]
    result["totals"] = totals
    result["undecoded"] = undecoded_notes
    result["phases"] = phase_counts
    result["dns_names"] = [{"phase": ph, "name": n, "queries": c} for (ph, n), c in sorted(names.items())]
    result["flows_total"] = len(flow_list)
    result["flows"] = flow_list[:MAX_FLOWS_JSON]
    if len(flow_list) > MAX_FLOWS_JSON:
        notes.append("only the first %d of %d flows are listed" % (MAX_FLOWS_JSON, len(flow_list)))
    result["leaks"] = leaks

    # Coverage: did the capture see the connections tor said it had?
    coverage = {"status": "not-checked", "expected": [], "seen": [], "missing": []}
    if args.expect_seen:
        try:
            expected = load_expect_seen(args.expect_seen)
        except OSError as e:
            expected = None
            errors.append("expect-seen: %s" % e)
        if expected is not None:
            seen_out = {(f["dst"], f["dport"]) for f in flow_list if f["proto"] == "tcp"}
            coverage["expected"] = ["%s:%d" % e for e in expected]
            coverage["seen"] = ["%s:%d" % e for e in expected if e in seen_out]
            coverage["missing"] = ["%s:%d" % e for e in expected if e not in seen_out]
            if not expected:
                coverage["status"] = "nothing-to-check"
            else:
                coverage["status"] = "complete" if not coverage["missing"] else "incomplete"
    result["coverage"] = coverage

    tor_after_arm = sum(phase_counts.get("post-arm", {}).get(c, 0)
                        for c in ("tor-relay", "tor-directory", "bridge"))
    result["post_arm_tor_packets"] = tor_after_arm

    # Verdict.
    reasons = []
    if errors:
        verdict = "error"
        reasons += errors
    elif not packets:
        verdict = "error"
        reasons.append("the capture holds no frames")
    elif totals["outbound"] == 0:
        verdict = "blind"
        reasons.append("the capture shows no packet from the guest: it cannot show a leak either")
    elif cutoff is None:
        verdict = "info"
        reasons.append("no arm event: everything is listed, nothing is judged (baseline)")
    else:
        verdict = "pass"
        if leaks:
            verdict = "fail"
            reasons.append("%d flow(s) after arm are LEAKs (%d packets)" % (
                len(leaks), sum(f["phases"].get("post-arm", 0) for f in leaks)))
        if coverage["status"] == "incomplete":
            if verdict == "pass":
                verdict = "blind"
            reasons.append("the capture misses %d of tor's %d connections (%s): it does not see "
                           "every path out of the phone" % (len(coverage["missing"]),
                                                             len(coverage["expected"]),
                                                             ", ".join(coverage["missing"][:5])))
        if args.require_tor_traffic and tor_after_arm == 0:
            if verdict == "pass":
                verdict = "blind"
            reasons.append("no Tor traffic after arm: either tor never connected or the capture "
                           "misses the path it used")
        if tordir.info["consensus"] is None:
            reasons.append("no consensus: Tor relays cannot be told apart from other servers")
            if args.require_tor_traffic:
                verdict = "error"
        if verdict == "pass":
            reasons.append("zero LEAK after arm (%d packets after arm, %d of them to the Tor network)"
                           % (sum(phase_counts.get("post-arm", {}).values()), tor_after_arm))
    result["verdict"] = verdict
    result["verdict_reasons"] = reasons
    result["notes"] = notes
    return result


def _add_flow(flows, key, p, cls, phase, name):
    f = flows.get(key)
    if f is None:
        f = flows[key] = {
            "l3": p.l3, "proto": p.proto, "src": p.src, "sport": p.sport if p.proto in ("tcp", "udp") else None,
            "dst": p.dst, "dport": p.dport if p.proto in ("tcp", "udp") else None,
            "icmp_type": p.icmp_type, "src_mac": p.src_mac, "class": cls[0], "kind": cls[1],
            "reason": cls[2], "label": cls[3], "packets": 0, "bytes": 0, "syn": False,
            "phases": {}, "names": set(), "first_ts": p.ts, "last_ts": p.ts,
        }
    elif cls[0] == LEAK and f["class"] != LEAK:
        # A flow that was allowed before arm and continues after it is a
        # LEAK from that packet on (for example the marker after arm).
        f.update({"class": cls[0], "kind": cls[1], "reason": cls[2], "label": cls[3]})
    f["packets"] += 1
    f["bytes"] += p.length or 0
    f["last_ts"] = p.ts
    f["phases"][phase] = f["phases"].get(phase, 0) + 1
    if p.tcp_syn_only:
        f["syn"] = True
    if name:
        f["names"].add(name)
    if p.proto == "udp" and p.sport == 68 and p.dport == 67 and "dhcp" not in f:
        d = pcapread.dhcp_options(p.payload)
        if d:
            f["dhcp"] = d


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def _dest_rows(flows, phase_filter=None):
    """Flows merged by (proto, destination, port, class)."""
    rows = {}
    for f in flows:
        if phase_filter and f["phases"].get(phase_filter, 0) == 0:
            continue
        key = (f["l3"], f["proto"], f["dst"], f["dport"], f["class"], f["kind"])
        r = rows.get(key)
        if r is None:
            r = rows[key] = {"proto": f["proto"], "l3": f["l3"], "dst": f["dst"], "dport": f["dport"],
                             "class": f["class"], "kind": f["kind"], "reason": f["reason"],
                             "label": f["label"], "flows": 0, "packets": 0, "names": set(),
                             "first": f["first"], "dhcp": f.get("dhcp")}
        r["flows"] += 1
        r["packets"] += f["phases"].get(phase_filter, 0) if phase_filter else f["packets"]
        r["names"].update(f["names"])
        if f["first"] is not None and (r["first"] is None or f["first"] < r["first"]):
            r["first"] = f["first"]
    out = sorted(rows.values(), key=lambda r: (r["first"] if r["first"] is not None else 0))
    for r in out:
        r["names"] = sorted(r["names"])
    return out


def _dest(r):
    d = r["dst"] or "?"
    if r["l3"] == "ipv6":
        d = "[%s]" % d
    if r["dport"] is not None:
        d += ":%d" % r["dport"]
    return d


def _md_escape(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


VERDICT_WORD = {"pass": "PASS", "fail": "FAIL", "blind": "BLIND (capture incomplete)",
                "error": "ERROR", "info": "INFORMATION (not judged)"}


def scenario_md(s):
    lines = []
    v = s.get("verdict")
    lines.append("## Scenario `%s`: %s" % (s.get("scenario"), VERDICT_WORD.get(v, v)))
    lines.append("")
    for r in s.get("verdict_reasons", []):
        lines.append("- " + _md_escape(r))
    lines.append("")
    caps = s.get("captures", [])
    t = s.get("totals", {})
    for c in caps:
        dur = (c["last"] - c["first"]) if c.get("first") is not None and c.get("last") is not None else 0
        lines.append("- Capture `%s`: %s, %d frames over %.0f s%s." % (
            os.path.basename(c["path"]), c["format"], c["records"], dur,
            " (cut short at the end)" if c.get("truncated") else ""))
    lines.append("- Frames: %d; sent by the phone: %d; from the emulator's network: %d; to the phone: %d; "
                 "not attributed: %d; not decoded: %d." % (
                     t.get("frames", 0), t.get("outbound", 0), t.get("from_emulator", 0),
                     t.get("to_guest", 0), t.get("unattributed", 0), t.get("undecoded", 0)))
    g = s.get("guest", {})
    lines.append("- The phone's addresses (%s): %s." % (g.get("source"), ", ".join(g.get("addresses", [])) or "none"))
    td = s.get("tor_directory", {})
    if td.get("consensus"):
        c = td["consensus"]
        lines.append("- Consensus (%s, valid after %s): %d relays, %d authorities." % (
            c.get("flavour"), c.get("valid_after"), c.get("relays", 0), c.get("authorities", 0)))
    if td.get("tor_binary"):
        b = td["tor_binary"]
        lines.append("- Compiled into tor: %d fallback directories, %d authorities." % (
            b.get("fallbacks", 0), b.get("authorities", 0)))
    if td.get("bridges"):
        lines.append("- Configured bridges: %d." % td["bridges"])
    clock = s.get("clock", {})
    if clock.get("source") == "marker":
        lines.append("- Clock: capture minus host = %.3f s (between %.3f and %.3f, from the marker)." % (
            clock["offset"], clock["offset_low"], clock["offset_high"]))
    arm = s.get("arm")
    if arm:
        lines.append("- Arm cutoff: t+%.1f s in the capture (%s; event `%s`, margin %.1f s). "
                     "Every packet from there on counts." % (
                         arm.get("cutoff_t") or 0, arm.get("cutoff_utc"), arm.get("event"), arm.get("margin", 0)))
    lines.append("")

    phases = s.get("phases", {})
    if phases:
        order = [ph for ph in ("baseline", "pre-arm", "post-arm") if ph in phases]
        lines.append("| Class | " + " | ".join("%s packets" % ph for ph in order) + " |")
        lines.append("|---|" + "---|" * len(order))
        for cls in CLASS_ORDER:
            if any(cls in phases[ph] for ph in order):
                lines.append("| %s | %s |" % (cls, " | ".join(str(phases[ph].get(cls, 0)) for ph in order)))
        lines.append("")

    flows = s.get("flows", [])
    if arm:
        leak_rows = _dest_rows(s.get("leaks", []), "post-arm")
        lines.append("### LEAKs after arm: %d destination(s)" % len(leak_rows))
        lines.append("")
        if leak_rows:
            lines.append("| First (t+s) | Kind | Destination | Name | Packets | Why |")
            lines.append("|---|---|---|---|---|---|")
            for r in leak_rows[:200]:
                lines.append("| %s | %s | `%s` | %s | %d | %s |" % (
                    r["first"], r["kind"], _dest(r), _md_escape(", ".join(r["names"][:3]) or r["label"] or ""),
                    r["packets"], _md_escape(r["reason"])))
            lines.append("")
        tor_rows = [r for r in _dest_rows(flows, "post-arm") if r["class"] in ("tor-relay", "tor-directory", "bridge")]
        lines.append("### Tor network after arm: %d destination(s)" % len(tor_rows))
        lines.append("")
        if tor_rows:
            lines.append("| First (t+s) | Class | Destination | What | Packets |")
            lines.append("|---|---|---|---|---|")
            for r in tor_rows[:60]:
                lines.append("| %s | %s | `%s` | %s | %d |" % (r["first"], r["class"], _dest(r),
                                                              _md_escape(r["label"] or ""), r["packets"]))
            lines.append("")
        other = [r for r in _dest_rows(flows, "post-arm") if r["class"] in ("lan-dhcp", "link-arp", "link-80211")]
        if other:
            lines.append("Link-level traffic after arm (allowed): " + ", ".join(
                "%s `%s` (%d)" % (r["class"], _dest(r), r["packets"]) for r in other[:20]) + ".")
            lines.append("")
        pre = _dest_rows(flows, "pre-arm")
        lines.append("### Before arm (listed, not judged): %d destination(s)" % len(pre))
        lines.append("")
        lines.extend(_dest_table(pre, 60))
    else:
        rows = _dest_rows(flows, "baseline")
        lines.append("### What the phone contacted on its own: %d destination(s)" % len(rows))
        lines.append("")
        lines.append("The class column says how each one would be judged after Antumbra's firewall is armed.")
        lines.append("")
        lines.extend(_dest_table(rows, 150))
    dns = [d for d in s.get("dns_names", [])]
    if dns:
        lines.append("Names the phone looked up through the emulator's resolver: " + ", ".join(
            "`%s` (%s, %d)" % (d["name"], d["phase"], d["queries"]) for d in dns[:80]) + ".")
        lines.append("")

    cov = s.get("coverage", {})
    if cov.get("status") != "not-checked":
        lines.append("### Coverage")
        lines.append("")
        lines.append("tor reported %d established connection(s); the capture saw %d; missing: %s." % (
            len(cov.get("expected", [])), len(cov.get("seen", [])), ", ".join(cov.get("missing", [])) or "none"))
        lines.append("")
    evs = s.get("events", [])
    if evs:
        lines.append("### Timeline")
        lines.append("")
        lines.append("| t (s) | Event | Detail |")
        lines.append("|---|---|---|")
        for e in evs:
            tt = "%.1f" % e["t"] if e.get("t") is not None else "?"
            lines.append("| %s | %s | %s |" % (tt, e["name"], _md_escape(e.get("detail", ""))))
        lines.append("")
    if s.get("notes"):
        lines.append("Notes: " + " ".join(_md_escape(n) + "." for n in s["notes"]))
        lines.append("")
    return lines


def _dest_table(rows, limit):
    if not rows:
        return ["(none)", ""]
    out = ["| First (t+s) | Proto | Destination | Name | Class | Packets |", "|---|---|---|---|---|---|"]
    for r in rows[:limit]:
        name = ", ".join(r["names"][:3]) or r["label"] or ""
        if r.get("dhcp"):
            d = r["dhcp"]
            name = "DHCP %s%s%s" % (d.get("message_type", ""),
                                    (" vendor=" + d["vendor_class"]) if d.get("vendor_class") else "",
                                    (" requested-ip=" + d["requested_ip"]) if d.get("requested_ip") else "")
        cls = r["class"] + (" (%s)" % r["kind"] if r["kind"] else "")
        out.append("| %s | %s | `%s` | %s | %s | %d |" % (r["first"], r["proto"], _dest(r), _md_escape(name),
                                                         cls, r["packets"]))
    if len(rows) > limit:
        out.append("")
        out.append("(%d more in leak-report.json)" % (len(rows) - limit))
    out.append("")
    return out


BLIND_SPOTS = """### What this test cannot see

- Only what passes the emulator's virtual network is captured. Traffic the
  phone's hardware sends by itself (Wi-Fi keep-alive offload, the modem) has
  no equivalent in the emulator; the January capture on the phone covers it.
- A packet capture cannot tell which app sent a packet. A connection to a Tor
  relay counts as Tor traffic even if an app other than tor made it.
- What travels through Tor is not visible here. Names looked up through Tor
  are in the DNS filter's counters, not in this report.
- The emulator runs Android 16 (API 36, Google's image without Google
  services) on a 6.x kernel, not LineageOS 23.2 on the phone's 4.14 kernel."""


def report(args):
    scenarios = {}
    for path in args.inputs:
        with open(path, encoding="utf-8") as f:
            s = json.load(f)
        scenarios[s["scenario"]] = s
    out = {"schema": SCHEMA, "generated": iso(datetime.datetime.now(datetime.timezone.utc).timestamp()),
           "scenarios": scenarios}
    with open(args.json, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    lines = ["# Antumbra leak report", ""]
    for name, s in scenarios.items():
        lines.append("- `%s`: **%s** (%d flows, %d of them LEAKs after arm)" % (
            name, VERDICT_WORD.get(s.get("verdict"), s.get("verdict")), s.get("flows_total", 0),
            len(s.get("leaks", []))))
    lines.append("")
    for name, s in scenarios.items():
        lines.extend(scenario_md(s))
    lines.append(BLIND_SPOTS)
    lines.append("")
    with open(args.md, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return 0


def cmd_tor_conns(args):
    conns = []
    for path in args.files:
        with open(path, encoding="utf-8", errors="replace") as f:
            conns.extend(parse_proc_net_tcp(f.read(), args.uid))
    for addr, port in sorted(set(conns)):
        print("[%s]:%d" % (addr, port) if ":" in addr else "%s:%d" % (addr, port))
    return 0


def cmd_listeners(args):
    for path in args.files:
        with open(path, encoding="utf-8", errors="replace") as f:
            for uid, addr, port in parse_proc_net_listeners(f.read(), args.proto):
                print("%s %d %s %d" % (args.proto, uid, addr, port))
    return 0


def cmd_slim(args):
    records, _ = pcapread.read_capture(args.input)
    by_lt = {}
    for r in records:
        by_lt.setdefault(r.linktype, []).append(r)
    if len(by_lt) > 1:
        print("slim: several link types; keeping only the most common", file=sys.stderr)
    recs = max(by_lt.values(), key=len) if by_lt else []
    pcapread.write_pcap(args.output, recs, snaplen=args.snaplen)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("analyse", help="classify one scenario's capture")
    a.add_argument("--scenario", required=True)
    a.add_argument("--pcap", action="append", required=True)
    a.add_argument("--events")
    a.add_argument("--arm-event")
    a.add_argument("--arm-margin", type=float)
    a.add_argument("--consensus")
    a.add_argument("--tor-binary")
    a.add_argument("--bridges")
    a.add_argument("--guest", action="append")
    a.add_argument("--expect-seen")
    a.add_argument("--require-tor-traffic", action="store_true")
    a.add_argument("--out", required=True)

    r = sub.add_parser("report", help="merge scenario results into leak-report.json and .md")
    r.add_argument("--in", dest="inputs", action="append", required=True)
    r.add_argument("--json", required=True)
    r.add_argument("--md", required=True)

    t = sub.add_parser("tor-conns", help="tor's established connections from /proc/net/tcp")
    t.add_argument("--uid", type=int, default=TOR_UID)
    t.add_argument("files", nargs="+")

    ls = sub.add_parser("listeners", help="listening sockets from /proc/net/tcp or udp")
    ls.add_argument("--proto", choices=("tcp", "udp"), default="tcp")
    ls.add_argument("files", nargs="+")

    s = sub.add_parser("slim", help="copy a capture with every frame cut to a few bytes")
    s.add_argument("input")
    s.add_argument("output")
    s.add_argument("--snaplen", type=int, default=256)

    args = ap.parse_args(argv)
    if args.cmd == "analyse":
        res = analyse(args)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(res, f, indent=1, sort_keys=True)
            f.write("\n")
        print("%s: %s: %s" % (args.scenario, res["verdict"], "; ".join(res["verdict_reasons"])))
        return EXIT.get(res["verdict"], 2)
    if args.cmd == "report":
        return report(args)
    if args.cmd == "tor-conns":
        return cmd_tor_conns(args)
    if args.cmd == "listeners":
        return cmd_listeners(args)
    if args.cmd == "slim":
        return cmd_slim(args)
    return 2


if __name__ == "__main__":
    sys.exit(main())
