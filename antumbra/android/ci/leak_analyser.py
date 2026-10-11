#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra CI: the leak analyser for the Android emulator's packet captures.

Lists every packet the emulated phone (the "guest") sent, groups them into
flows, and classifies each flow as one of:

  tor-relay      TCP to the ORPort of a relay in the consensus that the
                 phone's tor downloaded (cached-microdesc-consensus)
  tor-directory  TCP to the ORPort of a directory authority or a fallback
                 directory compiled into tor (from the consensus's dir-source
                 lines and from the tor binary's strings), which tor
                 contacts before it has a consensus. DirPorts are not
                 allowed: tor clients fetch directory documents over the
                 ORPort (BEGIN_DIR), so TCP to a DirPort is a LEAK, labelled
                 with the relay it belongs to
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
                 ipv6, multicast, dhcp, dhcp-lease, dhcp-hostname, armed,
                 fragment, unattributed, undecoded, other

Which frames are the phone's (--network emulator, the default). On the
emulator's virtual Ethernet there are only two kinds of station: QEMU's
user-mode network (slirp) and the phone. A frame counts as the emulator's
own, and is counted but not listed, only when all of this holds: its source
MAC address is exactly one of slirp's (52:55:0a:00:02:0X for its hosts
10.0.2.X, 52:56:00:00:00:02 and :03 for fec0::2 and fec0::3), it is not
addressed to one of those MACs, and it is an ARP frame from a slirp address
or an IP packet from an address that is not the phone's to the phone: to one
of its addresses, to a broadcast or multicast group, a DHCP answer (port 67
to 68), or to another address of slirp's network that is not one of slirp's
hosts (such a packet cannot leave the emulator). Every other frame is the
phone's: it is listed and judged, whatever its source address. A frame the
phone sent from an address that is not one of its own is a LEAK
("unattributed"). The phone's own packets TO slirp's hosts are judged like
any others: a lookup sent to 10.0.2.3 is the phone's DNS leaving outside Tor
(on a phone, to the Wi-Fi router's resolver); TCP to 10.0.2.2 reaches the
machine running the emulator (on a phone, the local network). Frames of
other link types (raw IP, Linux cooked, 802.11) and captures made on a real
network (--network lan, for example tcpdump on the phone or on a hotspot)
are attributed by address instead: a frame is the phone's when the capture
marks it outgoing, when it comes from one of the phone's MAC addresses, or
when its source is one of the phone's addresses; other stations' frames are
not counted.

Two views. The emulator's own capture (--pcap) records only its first
network card, the guest's eth0 (the emulated radio). The capture inside the
guest (--guest-pcap: tcpdump -i any, as root) records every interface,
Wi-Fi included, on its way out after netfilter: a frame it shows leaving is
a frame that left the phone. Its frames on loopback are left out (they
never leave), and every other frame is named with its interface: by the
index in its SLL2 header, else by its hardware or IP address, from the
guest's 'ip -o link' and 'ip -o addr' (--guest-links). Both views are
judged; a packet seen in both counts once in totals (the larger count per
interface), and each flow says which views saw it.

The phone's addresses: those given with --guest, or else every private,
link-local or site-local address seen acting as a client (sending a TCP
SYN, a query to a low UDP port, an ARP request, an echo request, an IPv6
router or neighbour solicitation, a DHCP request) from a MAC address that
is not slirp's, leaving out slirp's own addresses. With --expect-guest,
every address the device had at the end must be among them, or the
capture missed an interface ("blind").

Clocks. Each capture has its own clock: the emulator's (in run 4, 0.84 s
or more behind the host's), and the device's for the capture inside the
guest. The scenario's events (events.tsv) come from the CI host. Before
the module is installed the scenario sends the clock marker between two
host time stamps a second or two apart: an ICMP echo request whose data
holds "ANTUMBRA" and a nonce from each interface with an address, and a UDP
datagram "ANTUMBRA-CLOCK <nonce>" by the default route. In each capture,
every marker sent by the phone bounds that capture's offset to the host
(the bounds of several markers are intersected; bounds that do not meet
make the capture blind). The arm cutoff is the host time of the arm event
(taken just before the module's installation starts, so before
'antumbra-fw arm' ran) moved into each capture's clock with the lower
bound of its offset, minus a margin. Every packet at or after the cutoff
counts. The cutoff can only be early, never late. The capture inside the
guest must hold a marker (which also shows it ran before the module was
installed), and the device's clock, read between two host time stamps
again later (device_clock events), must not have moved from it by more
than 0.5 s. The module's own log line "post-fs-data: firewall armed"
(--module-log) is placed on the time line and checked against the arm
event, but it is not the cutoff: it is written after the arm and after the
runtime directory is set up, to the second, by the device's clock.
--judge-from-start judges every packet instead (a capture on the phone,
which has no marker and no arm event).

The armed window (--armed-window START:END). Between two events the
scenario puts the firewall back into its armed state ('antumbra-fw flush')
with the network up and makes traffic as root and as an app. In that
window nothing but loopback may pass: every packet the phone sent other
than ARP and DHCP (which Android sends from packet sockets, outside the
firewall) is a LEAK ("armed"), Tor traffic included. The window is moved
inward by the clock's uncertainty, so that it never takes in packets sent
before the flush or after the rule set was loaded again.

DHCP lease memory. After arm, a DHCP REQUEST that asks for an address the
phone held before arm (option 50 without a server identifier, INIT-REBOOT;
or a renewal with that address in ciaddr) is a LEAK ("dhcp-lease"): the new
session announces the previous one's lease. After arm, a DHCP client
message that carries a host name (option 12; Android 15 and later send the
device's name unless a device owner restricts it) is a LEAK
("dhcp-hostname"): every network the phone joins learns its name.

Names and destinations through Tor. A capture cannot see what goes through
Tor. With --tor-streams (tor's STREAM events, recorded over its control
socket) and --filter-log (the DNS filter's -debug-log-queries log), every
name the phone looked up and every destination it reached through Tor is
listed, and compared with --expected-destinations. In "learning" mode an
unexpected one is listed and noted; in "strict" mode it fails the run, and
missing records make it blind.

Verdicts: "pass" (zero LEAK after arm, the capture saw the guest, and,
when asked, saw Tor traffic, every connection tor reported, every address
the device had sending on its own interface, a whole armed window, and no
unexpected destination in strict mode), "fail" (a LEAK after arm, or an
unexpected destination in strict mode), "blind" (a capture missed traffic,
ended early, dropped packets or cannot be placed in time: it cannot prove
anything), "error" (an input is missing or unreadable), and "info" for a
scenario without an arm event (the baseline).

Usage:
  leak_analyser.py analyse --scenario NAME [--pcap FILE...] [--pcap-iface NAME]
      [--guest-pcap FILE] [--guest-links FILE]
      [--network emulator|lan] [--events FILE] [--module-log FILE]
      [--arm-event NAME | --judge-from-start] [--arm-margin SECONDS]
      [--armed-window START:END [--require-armed-window]]
      [--consensus FILE] [--tor-binary FILE] [--bridges FILE]
      [--guest ADDR...] [--expect-seen FILE] [--expect-guest FILE]
      [--require-tor-traffic] [--max-tail-gap SECONDS]
      [--tor-streams FILE] [--filter-log FILE]
      [--expected-destinations FILE] [--destinations-mode learning|strict]
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

SCHEMA = 2
TOR_UID = 2950

SLIRP_V4 = {
    "10.0.2.1": "emulator gateway",
    "10.0.2.2": "emulator host alias, gateway and DHCP server",
    "10.0.2.3": "emulator DNS forwarder",
    "10.0.2.4": "emulator DNS forwarder",
    "10.0.2.5": "emulator DNS forwarder",
    "10.0.2.6": "emulator DNS forwarder",
}
SLIRP_V6 = {"fec0::2": "emulator host alias", "fec0::3": "emulator DNS forwarder"}
# slirp's own MAC addresses, exactly: 52:55 and the four bytes of the IPv4
# address of the virtual host, 52:56 and the last four bytes of the IPv6 one
# (QEMU slirp: if_encap, arp_input, in6_compute_ethaddr).
SLIRP_MACS = {"52:55:0a:00:02:%02x" % i: "10.0.2.%d" % i for i in range(1, 7)}
SLIRP_MACS.update({"52:56:00:00:00:02": "fec0::2", "52:56:00:00:00:03": "fec0::3"})
SLIRP_DNS = {"10.0.2.3", "10.0.2.4", "10.0.2.5", "10.0.2.6", "fec0::3"}
# slirp's virtual network. A packet to an address in it that is not one of
# slirp's hosts never leaves the emulator: slirp forwards only to outside
# addresses and to its own hosts (10.0.2.2 is the host machine).
SLIRP_NETS = [ipaddress.ip_network("10.0.2.0/24"), ipaddress.ip_network("fec0::/64")]
MARKER = b"ANTUMBRA-CLOCK "
# The ICMP marker's data (ping -p): "ANTUMBRA" and the nonce's bytes.
ICMP_MARKER = b"ANTUMBRA"
# How far the device's clock may move from the host's after the marker
# before the capture inside the guest, which runs on it, is not trusted
# (the arm cutoff's margin is 1 s, the armed window's 0.5 s).
DEVICE_CLOCK_TOLERANCE = 0.5
# The module's log line written once 'antumbra-fw arm' has succeeded.
_MODULE_ARM_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) post-fs-data: firewall armed\b")
# The phone's own network: RFC 1918, shared (carrier-grade NAT), link-local,
# unique-local and site-local addresses. Python's is_private is wider (it
# also covers documentation and benchmark ranges), so it is not used.
LOCAL_NETS = [ipaddress.ip_network(n) for n in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "100.64.0.0/10",
    "fc00::/7", "fe80::/10", "fec0::/10")]

ALLOWED = ("tor-relay", "tor-directory", "bridge", "lan-dhcp", "link-arp", "link-80211", "ci-marker")
# What may pass while the firewall is only armed: link-level frames, and
# DHCP, which Android sends from a packet socket outside the firewall.
ALLOWED_ARMED = ("lan-dhcp", "link-arp", "link-80211")
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
    """True only for one of slirp's own MAC addresses, exactly (a random
    Wi-Fi address may begin with 52:55 too)."""
    return mac in SLIRP_MACS


class TorDirectory:
    """The addresses tor may legitimately connect to: ORPorts and bridges.
    DirPorts are kept only to name them in a LEAK's label."""

    def __init__(self):
        self.orports = {}   # (ip, port) -> (class, label)
        self.dirports = {}  # (ip, port) -> label (never allowed)
        self.bridges = {}   # (ip, port) -> label
        self.info = {"consensus": None, "tor_binary": None, "bridges": 0}

    def add_or(self, ip, port, cls, label, overwrite=False):
        key = (str(ipaddress.ip_address(ip)), int(port))
        if overwrite or key not in self.orports:
            self.orports[key] = (cls, label)

    def lookup(self, ip, port):
        hit = self.orports.get((ip, port))
        if hit:
            return hit
        if (ip, port) in self.bridges:
            return ("bridge", self.bridges[(ip, port)])
        return None

    def dirport(self, ip, port):
        return self.dirports.get((ip, port))


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
                tordir.dirports[(ip, int(dirport))] = "relay %s (DirPort)" % nick
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
                tordir.dirports[(ip, int(dirport))] = "authority %s (DirPort)" % name
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
            tordir.dirports.setdefault((ip, int(m.group(2))), "fallback directory %s (DirPort)" % fp[:8])
        fallbacks += 1
    for m in _AUTHORITY_RE.finditer(data):
        name, ip = m.group(1).decode(), m.group(3).decode()
        if ip_or_none(ip) is None:
            continue
        tordir.add_or(ip, m.group(2).decode(), "tor-directory", "authority " + name)
        tordir.dirports.setdefault((ip, int(m.group(4))), "authority %s (DirPort)" % name)
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


def marker_brackets(events):
    """{nonce: (host time before, host time after)} of the clock markers.
    The nonce is the first word of the events' detail."""
    before = {}
    out = {}
    for n, t, d in events:
        words = d.split()
        if not words:
            continue
        if n == "clock_marker_before":
            before.setdefault(words[0], t)
        elif n == "clock_marker_after" and words[0] in before:
            out.setdefault(words[0], (before[words[0]], t))
    return out


def _detail_values(detail):
    return dict(w.split("=", 1) for w in detail.split() if "=" in w)


def device_clock_samples(events):
    """[(host time, low, high)]: the device's clock minus the host's, from
    each reading of it between two host time stamps (the marker's
    "device=", and the device_clock events' "device=" and "host_after=")."""
    brackets = marker_brackets(events)
    out = []
    for n, t, d in events:
        kv = _detail_values(d)
        try:
            dev = float(kv["device"])
            if n == "clock_marker_after":
                low, high = dev - t, dev - brackets[d.split()[0]][0]
            elif n == "device_clock":
                low, high = dev - float(kv["host_after"]), dev - t
            else:
                continue
        except (KeyError, ValueError, IndexError):
            continue
        out.append((t, low, high))
    return out


def load_module_arm(path):
    """The device time (seconds, to the second) of the module's first
    "post-fs-data: firewall armed" line, or None."""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = _MODULE_ARM_RE.match(line)
            if m:
                return datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%SZ").replace(
                    tzinfo=datetime.timezone.utc).timestamp()
    return None


def load_links(path):
    """The guest's interfaces by index, hardware address and IP address,
    from 'ip -o link' and 'ip -o addr' output (one-line or not), as
    lib/common.sh's guest_links records it. Later lines win."""
    links = {"index": {}, "mac": {}, "addr": {}}
    iface = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"^(\d+):\s+([^:@\s]+)", line)
            if m:
                iface = m.group(2)
                links["index"][int(m.group(1))] = iface
            if iface is None or line.startswith("#"):
                continue
            m = re.search(r"\blink/\S+\s+([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})\b", line)
            if m and m.group(1) != "00:00:00:00:00:00":
                links["mac"][m.group(1).lower()] = iface
            for m in re.finditer(r"\binet6?\s+([0-9a-fA-F:.]+)", line):
                ip = ip_or_none(m.group(1))
                if ip is not None:
                    links["addr"][str(ip)] = iface
    return links


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


def load_expect_guest(path):
    """[(interface, address)] from 'ip addr' output or from lines of
    "INTERFACE ADDRESS[/PREFIX]" or "ADDRESS": the addresses the device had.
    Loopback and link-local addresses are left out (they never reach the
    capture as a source on their own)."""
    out = []
    iface = ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"^\d+:\s+([^:@\s]+)", line)
            if m:
                iface = m.group(1)
                continue
            words = line.split()
            if not words:
                continue
            if words[0] in ("inet", "inet6") and len(words) > 1:
                addr, name = words[1], iface
            elif len(words) >= 2:
                name, addr = words[0], words[1]
            else:
                name, addr = "", words[0]
            ip = ip_or_none(addr.split("/")[0])
            if ip is None or ip.is_loopback or ip.is_link_local:
                continue
            out.append((name, str(ip)))
    return sorted(set(out))


_STREAM_RE = re.compile(r"^650[ -]STREAM (\d+) (\S+) (\d+) (\S+)(.*)$")
_KV_RE = re.compile(r'([A-Z_]+)=("(?:[^"\\]|\\.)*"|\S+)')
# tor's own streams (directory fetches and uploads, reachability tests).
TOR_INTERNAL_PURPOSES = ("DIR_FETCH", "DIR_UPLOAD", "DIRPORT_TEST")


def _split_target(target):
    """("host", port) from tor's "host:port" or "[v6]:port"."""
    m = re.match(r"^\[([^\]]+)\]:(\d+)$", target) or re.match(r"^(.*):(\d+)$", target)
    if not m:
        return target, None
    return m.group(1), int(m.group(2))


def load_tor_streams(path):
    """tor's STREAM events from a control-connection transcript (what
    ci/lib/tor-streams.sh records). Returns (streams, info): one dict per
    stream (target, kind "connect" or "resolve", purpose, the statuses it
    went through, remaps), and whether events were switched on."""
    streams = {}
    order = []
    epoch = 0
    replies = []
    enabled = False
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    for line in lines:
        line = line.rstrip("\r")
        if line.startswith("ANTUMBRA-CI-STREAMS connect"):
            epoch += 1
            replies = []
            continue
        if re.match(r"^[0-9]{3} ", line) and not line.startswith("650 "):
            # The first two final replies of a connection answer
            # AUTHENTICATE and SETEVENTS STREAM.
            replies.append(line.strip())
            if len(replies) == 2 and replies == ["250 OK", "250 OK"]:
                enabled = True
            continue
        m = _STREAM_RE.match(line)
        if not m:
            continue
        enabled = True
        sid, status, _circ, target, rest = m.groups()
        kv = {k: v.strip('"') for k, v in _KV_RE.findall(rest)}
        key = (epoch, sid)
        st = streams.get(key)
        if st is None:
            st = streams[key] = {"target": None, "kind": None, "purpose": kv.get("PURPOSE", ""),
                                 "statuses": [], "remaps": [], "reason": None}
            order.append(key)
        if status in ("NEW", "NEWRESOLVE") and st["target"] is None:
            st["target"] = target
            st["kind"] = "resolve" if status == "NEWRESOLVE" else "connect"
        elif status == "REMAP":
            st["remaps"].append(target)
        if kv.get("PURPOSE"):
            st["purpose"] = kv["PURPOSE"]
        if kv.get("REASON"):
            st["reason"] = kv["REASON"]
        if not st["statuses"] or st["statuses"][-1] != status:
            st["statuses"].append(status)
    out = [streams[k] for k in order if streams[k]["target"]]
    return out, {"enabled": enabled, "connections": epoch}


_QUERY_RE = re.compile(r'query "((?:[^"\\]|\\.)*)" (\S+) -> (.+?)\s*$')


def _go_unquote(s):
    """The text inside a Go %q string."""
    simple = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
              "\\": "\\", '"': '"', "'": "'"}

    def rep(m):
        e = m.group(1)
        if e[0] in "xuU" and len(e) > 1:
            return chr(int(e[1:], 16))
        return simple.get(e, e)
    return re.sub(r"\\(x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4}|U[0-9a-fA-F]{8}|.)", rep, s)


def normalise_name(name):
    name = name.strip().lower()
    if name.endswith(".") and name != ".":
        name = name[:-1]
    return name or "."


def load_filter_log(path):
    """[(name, qtype, decision)] from the DNS filter's log written with
    -debug-log-queries, and whether that mode was on."""
    out = []
    debug = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if "debug mode: query names will be logged" in line:
                debug = True
                continue
            m = _QUERY_RE.search(line)
            if m:
                out.append((normalise_name(_go_unquote(m.group(1))), m.group(2), m.group(3)))
    return out, {"debug": debug}


def load_expected_destinations(path):
    """{"name": [patterns], "target": [(host pattern, port or None)]} from
    lines "name PATTERN" and "target HOST:PORT" ('#' starts a comment).
    A name pattern is a name, or "*.NAME" for NAME and every name under
    it; a target is an address or name and a port, either of them "*"."""
    exp = {"name": [], "target": []}
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, line in enumerate(f, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            words = line.split()
            if len(words) != 2 or words[0] not in ("name", "target"):
                raise ValueError("%s line %d: want 'name PATTERN' or 'target HOST:PORT'" % (path, n))
            if words[0] == "name":
                exp["name"].append(normalise_name(words[1]))
            else:
                host, port = _split_target(words[1])
                if port is None and not words[1].endswith(":*"):
                    raise ValueError("%s line %d: a target needs a port (or ':*')" % (path, n))
                if words[1].endswith(":*"):
                    host = words[1][:-2].strip("[]")
                exp["target"].append((host.lower(), port))
    return exp


def name_expected(name, patterns):
    for pat in patterns:
        if pat.startswith("*."):
            if name == pat[2:] or name.endswith(pat[1:]):
                return True
        elif name == pat:
            return True
    return False


def target_expected(host, port, patterns):
    host = host.lower()
    for ph, pp in patterns:
        if pp is not None and pp != port:
            continue
        if ph == "*" or ph == host or (ph.startswith("*.") and name_expected(host, [ph])):
            return True
    return False


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


def find_guest(packets, explicit, emulator=True):
    """(addresses, MACs) of the guest. With emulator=True every station on
    the emulator's Ethernet that is not slirp is the guest."""
    guest = set(str(ipaddress.ip_address(a)) for a in explicit)
    if not guest:
        for p in packets:
            if p.l3 is None or slirp_mac(p.src_mac) or not client_evidence(p):
                continue
            if is_local(p.src) and not slirp_service(p.src):
                guest.add(p.src)
    macs = set()
    for p in packets:
        if not p.src_mac or slirp_mac(p.src_mac):
            continue
        if (emulator and p.linktype == pcapread.LINKTYPE_ETHERNET) or p.src in guest:
            macs.add(p.src_mac)
    return guest, macs


def from_emulator(p, guest):
    """True for a frame that the emulator's own network (slirp) sent to the
    guest; see "Which frames are the phone's" above. Anything else on the
    emulator's Ethernet is the guest's."""
    if not slirp_mac(p.src_mac) or p.dst_mac in SLIRP_MACS:
        return False
    if p.l3 == "arp":
        return p.src in SLIRP_V4
    if p.l3 not in ("ipv4", "ipv6") or p.src in guest:
        return False
    if p.dst in guest or is_group(p.dst):
        return True
    if p.proto == "udp" and p.sport == 67 and p.dport == 68:
        return True
    dst = ip_or_none(p.dst)
    return (dst is not None and not slirp_service(p.dst)
            and any(dst.version == n.version and dst in n for n in SLIRP_NETS))


def attribute(p, guest, guest_macs, emulator):
    """"out" (the guest sent it), "emulator" (slirp sent it) or "other"."""
    if emulator and p.linktype == pcapread.LINKTYPE_ETHERNET and p.src_mac is not None:
        return "emulator" if from_emulator(p, guest) else "out"
    if p.direction_hint == "in":
        return "emulator" if emulator and slirp_mac(p.src_mac) else "other"
    if p.direction_hint == "out":
        return "out"
    if p.src_mac is not None and p.src_mac in guest_macs:
        return "out"
    if p.l3 is not None and p.src in guest:
        return "out"
    if (p.l3 is not None and p.src in ("0.0.0.0", "::") and p.src_mac is not None
            and not slirp_mac(p.src_mac)):
        return "out"
    if emulator and (slirp_mac(p.src_mac) or (p.l3 is not None and slirp_service(p.src))):
        return "emulator"
    return "other"


def marker_nonce(p, brackets):
    """The nonce of the clock marker p is, or None: the UDP datagram
    "ANTUMBRA-CLOCK <nonce>", or an ICMP echo request whose data holds
    "ANTUMBRA" and the nonce's bytes (ping -p). Only what the phone sends:
    an echo reply may arrive after the second time stamp."""
    if p.proto == "udp" and p.payload.startswith(MARKER):
        words = p.payload[len(MARKER):].split()
        nonce = words[0].decode("ascii", "replace") if words else ""
        return nonce if nonce in brackets else None
    if p.proto == "icmp" and p.icmp_type == 8 and ICMP_MARKER in p.payload:
        for nonce in brackets:
            try:
                pattern = ICMP_MARKER + bytes.fromhex(nonce)
            except ValueError:
                continue
            if pattern in p.payload:
                return nonce
    return None


def find_clock(packets, brackets):
    """Offset (capture time minus host time) from the clock markers in one
    capture: each was sent between its two host time stamps, so the offset
    lies in every marker's interval. "conflict" when they do not meet."""
    lows, highs, nonces = [], [], []
    for p in packets:
        nonce = marker_nonce(p, brackets)
        if nonce is None:
            continue
        before, after = brackets[nonce]
        lows.append(p.ts - after)
        highs.append(p.ts - before)
        nonces.append(nonce)
    if not lows:
        return {"source": "none", "nonce": None, "markers": 0, "offset_low": 0.0, "offset_high": 0.0,
                "offset": 0.0}
    low, high = max(lows), min(highs)
    clock = {"source": "marker", "nonce": nonces[0], "markers": len(lows)}
    if low > high:
        clock["conflict"] = True
        low, high = min(lows), max(highs)
    clock.update({"offset_low": low, "offset_high": high, "offset": (low + high) / 2})
    return clock


def iface_of(p, default, links):
    """The name of the interface a frame was captured on, or None: by the
    SLL2 header's index, the loopback hardware type, the frame's hardware
    addresses, the capture's own interface (default), or its IP
    addresses."""
    if p.ifindex:
        return links["index"].get(p.ifindex, "if%d" % p.ifindex)
    if p.hatype == pcapread.ARPHRD_LOOPBACK:
        return "lo"
    for mac in (p.src_mac, p.dst_mac):
        if mac in links["mac"]:
            return links["mac"][mac]
    if default:
        return default
    for addr in (p.src, p.dst):
        if addr in links["addr"]:
            return links["addr"][addr]
    return None


def merged(counts):
    """A total over views ("capture:interface" -> count). Two captures of
    one interface see the same packets: each interface counts with its
    largest view, and the interfaces add up."""
    best = {}
    for view, n in counts.items():
        iface = view.split(":", 1)[1]
        best[iface] = max(best.get(iface, 0), n)
    return sum(best.values())


def app_name(p):
    if p.proto in ("udp", "tcp") and p.dport == 53:
        q = pcapread.dns_question(p.payload, tcp=(p.proto == "tcp"))
        if q and not q[2]:
            return q[0]
        return None
    if p.proto == "tcp" and p.payload:
        return pcapread.tls_sni(p.payload) or pcapread.http_host(p.payload)
    return None


def classify(p, tordir, brackets, phase):
    """(class, kind, reason, label) for one outbound packet."""
    if p.proto == "arp":
        return ("link-arp", None, "ARP: link-level, never routed", "who-has " + (p.dst or "?"))
    if phase != "post-arm" and marker_nonce(p, brackets):
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
        dirport = tordir.dirport(p.dst, p.dport)
        if dirport:
            return (LEAK, "tcp", "TCP to a Tor DirPort: tor clients fetch directory documents over the "
                    "ORPort, so this is not tor's traffic", dirport)
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


def iso_s(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def event_time(events, name, after=None):
    """Host time of the first event NAME (after AFTER, if given), or None."""
    for n, t, _ in events:
        if n == name and (after is None or t >= after):
            return t
    return None


def destinations(args, notes, errors):
    """Names and destinations through Tor (see "Names and destinations
    through Tor" above), or None when neither record was given."""
    if not args.tor_streams and not args.filter_log:
        return None
    mode = args.destinations_mode
    expected = {"name": [], "target": []}
    if args.expected_destinations:
        try:
            expected = load_expected_destinations(args.expected_destinations)
        except (OSError, ValueError) as e:
            errors.append("expected destinations: %s" % e)
    sources = {"tor_streams": False, "tor_connections": 0, "filter_log": False, "filter_debug": False}
    streams = []
    if args.tor_streams:
        try:
            streams, info = load_tor_streams(args.tor_streams)
            sources["tor_streams"] = info["enabled"]
            sources["tor_connections"] = info["connections"]
        except OSError as e:
            notes.append("tor's STREAM events not read (%s)" % e)
    queries = []
    if args.filter_log:
        try:
            queries, info = load_filter_log(args.filter_log)
            sources["filter_log"] = True
            sources["filter_debug"] = info["debug"]
        except OSError as e:
            notes.append("the DNS filter's log not read (%s)" % e)

    names = {}

    def name_row(n):
        return names.setdefault(n, {"name": n, "types": set(), "decisions": {}, "queries": 0,
                                    "tor_resolves": 0, "reached": False})
    for n, qtype, decision in queries:
        r = name_row(n)
        r["types"].add(qtype)
        r["decisions"][decision] = r["decisions"].get(decision, 0) + 1
        r["queries"] += 1
        if decision.startswith("forwarded"):
            r["reached"] = True
    targets = {}
    for st in streams:
        if st["purpose"] in TOR_INTERNAL_PURPOSES or st["target"].startswith(("(", "$")):
            continue
        host, port = _split_target(st["target"])
        # .onion names are mapped to addresses; judge the name tor maps back.
        remapped = [h for h, _ in (_split_target(t) for t in st["remaps"]) if ip_or_none(h) is None]
        if st["kind"] == "resolve" or ip_or_none(host) is None:
            r = name_row(normalise_name(host))
            r["tor_resolves"] += 1
            r["reached"] = True
            if st["kind"] == "resolve":
                continue
        key = (host.lower(), port)
        t = targets.setdefault(key, {"target": st["target"], "host": host.lower(), "port": port,
                                     "streams": 0, "statuses": {}, "purposes": set(),
                                     "names": set(), "reasons": set()})
        t["streams"] += 1
        last = st["statuses"][-1] if st["statuses"] else "?"
        t["statuses"][last] = t["statuses"].get(last, 0) + 1
        if st["purpose"]:
            t["purposes"].add(st["purpose"])
        if st["reason"]:
            t["reasons"].add(st["reason"])
        t["names"].update(normalise_name(h) for h in remapped)

    unexpected = []
    name_rows = sorted(names.values(), key=lambda r: r["name"])
    for r in name_rows:
        r["types"] = sorted(r["types"])
        r["expected"] = name_expected(r["name"], expected["name"])
        if r["reached"] and not r["expected"]:
            how = []
            if r["tor_resolves"]:
                how.append("%d look-up(s) through Tor" % r["tor_resolves"])
            if r["decisions"]:
                how.append("filter: " + ", ".join("%s %d" % kv for kv in sorted(r["decisions"].items())))
            unexpected.append("name %s (%s)" % (repr(r["name"])[1:-1], "; ".join(how)))
    target_rows = sorted(targets.values(), key=lambda t: (t["host"], t["port"] or 0))
    for t in target_rows:
        t["purposes"] = sorted(t["purposes"])
        t["reasons"] = sorted(t["reasons"])
        t["names"] = sorted(t["names"])
        t["expected"] = (target_expected(t["host"], t["port"], expected["target"])
                         or any(name_expected(n, expected["name"]) for n in t["names"]))
        if not t["expected"]:
            unexpected.append("target %s (%d stream(s), %s)" % (
                t["target"], t["streams"], ", ".join("%s %d" % kv for kv in sorted(t["statuses"].items()))))
    if not sources["tor_streams"]:
        status = "not-recorded"
        notes.append("tor's STREAM events were not recorded: destinations reached through Tor are unknown")
    elif unexpected:
        status = "unexpected"
    else:
        status = "ok"
    if args.filter_log and not sources["filter_debug"]:
        notes.append("the DNS filter did not run with -debug-log-queries: the names it blocked are not listed")
    return {"mode": mode, "status": status, "sources": sources, "names": name_rows,
            "targets": target_rows, "unexpected": unexpected,
            "expected_file": args.expected_destinations}


def analyse(args):
    notes = []
    errors = []
    emulator = args.network == "emulator"
    result = {
        "schema": SCHEMA, "scenario": args.scenario, "verdict": None, "verdict_reasons": [],
        "network": args.network,
        "generated": iso(datetime.datetime.now(datetime.timezone.utc).timestamp()),
    }
    if args.judge_from_start and args.arm_event:
        errors.append("--judge-from-start and --arm-event exclude each other")
    if not args.pcap and not args.guest_pcap:
        errors.append("no capture: give --pcap or --guest-pcap")

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

    events = []
    if args.events:
        try:
            events = load_events(args.events)
        except OSError as e:
            errors.append("events: %s" % e)
    brackets = marker_brackets(events)
    links = {"index": {}, "mac": {}, "addr": {}}
    if args.guest_links:
        try:
            links = load_links(args.guest_links)
        except OSError as e:
            notes.append("the guest's interfaces were not read (%s): frames are not named by interface" % e)

    # The captures, each on its own clock, placed by its own markers.
    caps = []
    capture_problems = []
    inputs = [("emulator" if emulator else "capture", p) for p in args.pcap or []]
    inputs += [("guest", p) for p in args.guest_pcap or []]
    for kind, path in inputs:
        try:
            recs, info = pcapread.read_capture(path)
        except (OSError, pcapread.CaptureError) as e:
            errors.append("capture: %s" % e)
            continue
        d = info.as_dict()
        d.update({"kind": kind, "name": os.path.basename(path),
                  "iface": None if kind == "guest" else args.pcap_iface})
        with open(path, "rb") as f:
            d["sha256"] = hashlib.sha256(f.read()).hexdigest()
        unsupported = sorted(set(info.linktypes) - pcapread.SUPPORTED_LINKTYPES)
        if unsupported:
            notes.append("%s: link types %s are not decoded" % (path, unsupported))
        if info.truncated:
            capture_problems.append("%s ends in the middle of a frame (it was not closed): "
                                    "frames at the end may be missing" % d["name"])
        recs.sort(key=lambda r: r.ts)
        packets = [pcapread.decode(r) for r in recs]
        d["clock"] = find_clock(packets, brackets)
        d["totals"] = {"frames": len(packets), "loopback": 0, "outbound": 0}
        caps.append((d, packets))
    result["captures"] = [d for d, _ in caps]
    result["tor_directory"] = dict(tordir.info, orports=len(tordir.orports))
    result["clock"] = caps[0][0]["clock"] if caps else find_clock([], {})

    # Each capture's clock: placed, and, for the guest's (the device's
    # clock), still where the marker put it at the device's later readings.
    samples = device_clock_samples(events)
    for d, _ in caps:
        c = d["clock"]
        if c.get("conflict"):
            capture_problems.append("the clock markers in %s disagree: its clock cannot be placed" % d["name"])
        if c["source"] == "none" and args.arm_event:
            if d["kind"] == "guest":
                capture_problems.append("%s, the capture inside the guest, holds no clock marker: it did not run "
                                        "from before the module was installed, or its clock cannot be placed"
                                        % d["name"])
            else:
                notes.append("no clock marker found in %s: its clock is taken to be the host's, with a wider margin"
                             % d["name"])
        if d["kind"] == "guest" and c["source"] == "marker" and args.arm_event:
            # The marker's own reading always agrees with the marker: only a
            # reading taken after the arm event shows the clock stayed put.
            arm_t = event_time(events, args.arm_event)
            if arm_t is None or not [t for t, _, _ in samples if t >= arm_t]:
                capture_problems.append("the device's clock was not read after %s (no usable device_clock "
                                        "reading): whether it stayed where the clock marker put it is unknown, "
                                        "so the times in %s cannot be trusted" % (args.arm_event, d["name"]))
        if d["kind"] == "guest" and c["source"] == "marker" and samples:
            moved = max(max(low - c["offset_high"], c["offset_low"] - high, 0.0) for _, low, high in samples)
            d["device_clock_moved"] = round(moved, 3)
            if moved > DEVICE_CLOCK_TOLERANCE:
                capture_problems.append("the device's clock moved %.1f s or more from where the clock marker put it: "
                                        "the times in %s, which runs on it, cannot be trusted" % (moved, d["name"]))

    # One time line: host time, estimated with each capture's offset.
    items = sorted(((p, ci) for ci, (_, pk) in enumerate(caps) for p in pk),
                   key=lambda x: x[0].ts - caps[x[1]][0]["clock"]["offset"])
    t0 = (items[0][0].ts - caps[items[0][1]][0]["clock"]["offset"]) if items else None

    def t_of(host):
        return (host - t0) if t0 is not None and host is not None else None

    # The arm cutoff, in each capture's clock.
    cutoffs = {}
    arm_host = None
    if args.judge_from_start:
        for ci, (d, _) in enumerate(caps):
            cutoffs[ci] = d["first"] if d["first"] is not None else 0.0
            d.update({"cutoff": cutoffs[ci], "margin": 0.0, "cutoff_t": t_of(cutoffs[ci] - d["clock"]["offset"])})
        c0 = cutoffs.get(0, 0.0)
        result["arm"] = {"event": "(start of the capture)", "host_time": None, "margin": 0.0,
                         "cutoff": c0, "cutoff_utc": iso(c0), "cutoff_t": 0.0}
    elif args.arm_event:
        arm_host = event_time(events, args.arm_event)
        if arm_host is not None and caps:
            for ci, (d, _) in enumerate(caps):
                c = d["clock"]
                margin = args.arm_margin if args.arm_margin is not None else (
                    1.0 if c["source"] == "marker" else 3.0)
                cutoffs[ci] = arm_host + c["offset_low"] - margin
                d.update({"cutoff": cutoffs[ci], "margin": margin,
                          "cutoff_t": t_of(cutoffs[ci] - c["offset"])})
            earliest = min(cutoffs[ci] - caps[ci][0]["clock"]["offset"] for ci in cutoffs)
            result["arm"] = {"event": args.arm_event, "host_time": arm_host, "margin": caps[0][0]["margin"],
                             "cutoff": cutoffs[0], "cutoff_utc": iso(earliest), "cutoff_t": t_of(earliest)}
        else:
            if arm_host is None:
                errors.append("the arm event '%s' is not in the events file" % args.arm_event)
            result["arm"] = None
    else:
        result["arm"] = None

    result["events"] = [
        {"name": n, "host_time": t, "detail": dt, "capture_time": t + result["clock"]["offset"], "t": t_of(t)}
        for n, t, dt in events
    ]

    # The module's own arm time, by the device's clock: on the time line,
    # and no earlier than the arm event. Not the cutoff (see "Clocks").
    module_arm = None
    if args.module_log:
        dev_t = None
        try:
            dev_t = load_module_arm(args.module_log)
            if dev_t is None:
                notes.append("the module's log has no 'post-fs-data: firewall armed' line")
        except OSError as e:
            notes.append("the module's log was not read (%s)" % e)
        if dev_t is not None:
            module_arm = {"device_time": dev_t, "device_utc": iso_s(dev_t)}
            dev = next((d["clock"] for d, _ in caps if d["kind"] == "guest" and d["clock"]["source"] == "marker"),
                       None)
            bounds = (dev["offset_low"], dev["offset_high"]) if dev else (samples[0][1:] if samples else None)
            if bounds:
                # Written within [dev_t, dev_t + 1) by the device's clock.
                module_arm.update({"host_low": dev_t - bounds[1], "host_high": dev_t + 1 - bounds[0]})
                module_arm["t"] = t_of((module_arm["host_low"] + module_arm["host_high"]) / 2)
                if result.get("arm") and result["arm"].get("cutoff_utc") is not None and cutoffs:
                    earliest = min(cutoffs[ci] - caps[ci][0]["clock"]["offset"] for ci in cutoffs)
                    module_arm["after_cutoff"] = round(module_arm["host_low"] - earliest, 1)
                result["events"].append({"name": "module log: firewall armed", "host_time": None,
                                         "detail": "device clock %s" % iso_s(dev_t),
                                         "capture_time": None, "t": module_arm["t"]})
                result["events"].sort(key=lambda e: (e["t"] is None, e["t"] or 0.0))
                early = (arm_host - module_arm["host_high"]) if arm_host is not None else 0.0
                if early > DEVICE_CLOCK_TOLERANCE:
                    msg = ("the module logged 'firewall armed' %.1f s or more before %s, by the device's clock as "
                           "the marker placed it: that clock moved, or the log is not this run's"
                           % (early, args.arm_event))
                    if any(d["kind"] == "guest" for d, _ in caps):
                        capture_problems.append(msg)
                    else:
                        notes.append(msg)
    result["module_arm"] = module_arm

    # The armed window, in each capture's clock, moved inward by its
    # uncertainty.
    windows = {}
    armed = {"status": "not-asked"}
    if args.armed_window:
        start_ev, _, end_ev = args.armed_window.partition(":")
        ws_host = event_time(events, start_ev)
        we_host = event_time(events, end_ev, after=ws_host) if ws_host is not None else None
        armed = {"status": "not-run", "start_event": start_ev, "end_event": end_ev,
                 "packets": 0, "allowed": 0, "leaks": 0}
        if ws_host is not None and we_host is not None and caps:
            armed["status"] = "ok"
            for ci, (d, _) in enumerate(caps):
                c = d["clock"]
                inward = 0.5 if c["source"] == "marker" else 3.0
                ws = ws_host + c["offset_high"] + inward
                we = we_host + c["offset_low"] - inward
                d["armed_window"] = {"start": ws, "end": we, "seconds": round(we - ws, 1), "status": "ok"}
                if we - ws < 5.0:
                    d["armed_window"]["status"] = armed["status"] = "too-short"
                else:
                    windows[ci] = (ws, we)
            w0 = caps[0][0]["armed_window"]
            armed.update({"start": w0["start"], "end": w0["end"],
                          "seconds": min(d["armed_window"]["seconds"] for d, _ in caps),
                          "start_t": t_of(max(d["armed_window"]["start"] - d["clock"]["offset"] for d, _ in caps)),
                          "end_t": t_of(min(d["armed_window"]["end"] - d["clock"]["offset"] for d, _ in caps))})

    # Loopback never leaves the phone; every other frame is named with its
    # interface and its view ("capture:interface").
    framed = []
    for p, ci in items:
        d = caps[ci][0]
        iface = iface_of(p, d["iface"], links)
        if p.hatype == pcapread.ARPHRD_LOOPBACK or iface == "lo":
            d["totals"]["loopback"] += 1
            continue
        framed.append((p, ci, iface, "%s:%s" % (d["kind"], iface or "?")))

    guest, guest_macs = find_guest([p for p, _, _, _ in framed], args.guest or [], emulator)
    result["guest"] = {"addresses": sorted(guest), "macs": sorted(guest_macs),
                       "source": "given" if args.guest else "detected"}

    def phase_of(p, ci):
        if ci not in cutoffs:
            return "baseline"
        return "post-arm" if p.ts >= cutoffs[ci] else "pre-arm"

    # The addresses the guest held before arm (sources, DHCP requests, and
    # the leases slirp acknowledged), for the DHCP lease-memory check.
    pre_leases = set()
    directions = []
    for p, ci, _, _ in framed:
        d = attribute(p, guest, guest_macs, emulator)
        directions.append(d)
        if ci not in cutoffs or p.ts >= cutoffs[ci] or p.l3 != "ipv4":
            continue
        if d == "out" and p.src in guest:
            pre_leases.add(p.src)
        if p.proto == "udp" and {p.sport, p.dport} == {67, 68}:
            opt = pcapread.dhcp_options(p.payload) or {}
            if d == "out" and p.sport == 68:
                pre_leases.update(a for a in (opt.get("requested_ip"), opt.get("ciaddr")) if a)
            elif d == "emulator" and opt.get("message_type") == "ACK":
                pre_leases.add(opt.get("yiaddr"))
    pre_leases.discard("0.0.0.0")
    pre_leases.discard(None)

    def count(table, key, view):
        table.setdefault(key, {})
        table[key][view] = table[key].get(view, 0) + 1

    tv = {}
    flows = {}
    phase_v = {}
    armed_v = {}
    names_v = {}
    undecoded_notes = {}
    seen_on = {}
    iface_views = {}
    for (p, ci, iface, view), direction in zip(framed, directions):
        d = caps[ci][0]
        phase = phase_of(p, ci)
        iface_views.setdefault(iface or "?", set()).add(d["kind"])
        if p.l3 is None:
            count(tv, "undecoded", view)
            note = p.note or ("EtherType 0x%04x" % p.ethertype if p.ethertype is not None else "not decoded")
            undecoded_notes[note] = undecoded_notes.get(note, 0) + 1
        if direction == "emulator":
            count(tv, "from_emulator", view)
            continue
        if direction != "out":
            count(tv, "not_the_phone", view)
            continue
        count(tv, "outbound", view)
        d["totals"]["outbound"] += 1
        in_window = ci in windows and windows[ci][0] <= p.ts <= windows[ci][1]
        if p.l3 is None:
            # Something the guest sent that has no IP header here.
            if note.startswith(("802.11 management", "802.11 null")):
                cls = ("link-80211", None, "802.11 association or power-save frame", p.src_mac)
            else:
                cls = (LEAK, "undecoded", "a frame from the phone that this analyser cannot read (%s)"
                       % note, p.src_mac)
            key = ("link", note, p.src_mac, p.dst_mac)
            name = None
        else:
            known = iface if iface and not re.match(r"^if\d+$", iface) else None
            seen_on.setdefault(p.src, set()).add(known)
            cls = classify(p, tordir, brackets, phase)
            src_ip = ip_or_none(p.src)
            if (p.src not in guest and p.src not in ("0.0.0.0", "::")
                    and not (src_ip is not None and src_ip.is_link_local)):
                count(tv, "unattributed", view)
                cls = (LEAK, "unattributed", "sent by the phone (MAC %s) with a source address that is "
                       "not one of its own: %s" % (p.src_mac or "?", cls[2]), cls[3])
            name = app_name(p)
            if p.proto in ("tcp", "udp"):
                key = (p.l3, p.proto, p.src, p.sport, p.dst, p.dport)
            elif p.proto in ("icmp", "icmpv6"):
                key = (p.l3, p.proto, p.src, p.icmp_type, p.dst, None)
            else:
                key = (p.l3, p.proto, p.src, None, p.dst, None)
            if cls[0] == "unattributed" or cls[1] == "unattributed":
                key = ("unattributed", p.src_mac) + key
            if (phase == "post-arm" and p.proto == "udp" and p.sport == 68 and p.dport == 67
                    and pre_leases):
                opt = pcapread.dhcp_options(p.payload) or {}
                if opt.get("message_type") == "REQUEST":
                    asked = opt.get("requested_ip") if not opt.get("server_id") else None
                    renew = opt.get("ciaddr") if opt.get("ciaddr") != "0.0.0.0" else None
                    reused = sorted({a for a in (asked, renew) if a and a in pre_leases})
                    if reused:
                        cls = (LEAK, "dhcp-lease", "a DHCP request after arm for %s, which the phone "
                               "held before arm: the lease memory links this session to the previous "
                               "one" % ", ".join(reused), "requested " + ", ".join(reused))
                        key = ("dhcp-lease", p.src_mac) + key
            if (phase == "post-arm" and p.proto == "udp" and p.sport == 68 and p.dport == 67
                    and cls[0] != LEAK):
                opt = pcapread.dhcp_options(p.payload) or {}
                if opt.get("hostname"):
                    host = opt["hostname"][:64]
                    cls = (LEAK, "dhcp-hostname", "a DHCP message after arm that names the device "
                           "(option 12, host name %r): every network the phone joins learns it" % host,
                           "host name " + host)
                    key = ("dhcp-hostname", p.src_mac) + key
        if in_window and cls[0] not in ALLOWED_ARMED:
            cls = (LEAK, "armed", "sent while the firewall was armed, when nothing but loopback may "
                   "pass (%s: %s)" % (cls[1] or cls[0], cls[2]), cls[3])
            key = ("armed",) + key
            count(armed_v, "leaks", view)
        if in_window:
            count(armed_v, "packets", view)
            if cls[0] in ALLOWED_ARMED:
                count(armed_v, "allowed", view)
        _add_flow(flows, key, p, cls, phase, name, view, p.ts - d["clock"]["offset"])
        count(phase_v, (phase, cls[0]), view)
        if name and p.dport == 53:
            count(names_v, (phase, name), view)
    if args.armed_window and armed["status"] != "not-run":
        armed.update({k: merged(armed_v.get(k, {})) for k in ("packets", "allowed", "leaks")})
        if armed["status"] == "ok" and armed["leaks"]:
            armed["status"] = "fail"

    totals = {k: merged(tv.get(k, {})) for k in ("outbound", "from_emulator", "not_the_phone", "unattributed",
                                                 "undecoded")}
    totals["frames"] = sum(d["totals"]["frames"] for d, _ in caps)
    totals["loopback"] = sum(d["totals"]["loopback"] for d, _ in caps)
    phase_counts = {}
    for (phase, cls), views in sorted(phase_v.items()):
        phase_counts.setdefault(phase, {})[cls] = merged(views)

    flow_list = sorted(flows.values(), key=lambda f: f["first_ts"])
    for f in flow_list:
        _finish_flow(f)
        f["first"] = round(f["first_ts"] - t0, 3) if t0 is not None else None
        f["last"] = round(f["last_ts"] - t0, 3) if t0 is not None else None
        f["first_utc"] = iso(f["first_ts"])
        f["names"] = sorted(f["names"])
        del f["first_ts"], f["last_ts"]
    leaks = [f for f in flow_list if f["class"] == LEAK and f["phases"].get("post-arm", 0) > 0]
    result["totals"] = totals
    result["undecoded"] = undecoded_notes
    result["phases"] = phase_counts
    result["armed_window"] = armed
    result["dhcp_pre_arm_leases"] = sorted(pre_leases)
    result["dns_names"] = [{"phase": ph, "name": n, "queries": merged(v)} for (ph, n), v in sorted(names_v.items())]
    result["interfaces"] = {i: sorted(k) for i, k in sorted(iface_views.items())}
    result["flows_total"] = len(flow_list)
    result["flows"] = flow_list[:MAX_FLOWS_JSON]
    if len(flow_list) > MAX_FLOWS_JSON:
        notes.append("only the first %d of %d flows are listed" % (MAX_FLOWS_JSON, len(flow_list)))
    result["leaks"] = leaks

    # Coverage: did the captures see the connections tor said it had, and
    # every address the device had, sending on its own interface?
    coverage = {"status": "not-checked", "expected": [], "seen": [], "missing": [],
                "addresses": [], "addresses_missing": []}
    checked = False
    if args.expect_seen:
        try:
            expected = load_expect_seen(args.expect_seen)
        except OSError as e:
            expected = None
            errors.append("expect-seen: %s" % e)
        if expected is not None:
            checked = True
            seen_out = {(f["dst"], f["dport"]) for f in flow_list if f["proto"] == "tcp"}
            coverage["expected"] = ["%s:%d" % e for e in expected]
            coverage["seen"] = ["%s:%d" % e for e in expected if e in seen_out]
            coverage["missing"] = ["%s:%d" % e for e in expected if e not in seen_out]
    if args.expect_guest:
        try:
            addrs = load_expect_guest(args.expect_guest)
        except OSError as e:
            addrs = None
            errors.append("expect-guest: %s" % e)
        if addrs is not None:
            checked = True

            def sent(iface, addr):
                # On that interface, or on one the capture could not name.
                got = seen_on.get(addr, set())
                return bool(got) and (not iface or iface in got or None in got)
            coverage["addresses"] = ["%s %s" % a for a in addrs]
            coverage["addresses_missing"] = ["%s %s" % a for a in addrs if not sent(*a)]
    if checked:
        if coverage["missing"] or coverage["addresses_missing"]:
            coverage["status"] = "incomplete"
        elif coverage["expected"] or coverage["addresses"]:
            coverage["status"] = "complete"
        else:
            coverage["status"] = "nothing-to-check"
    result["coverage"] = coverage

    # The end of each capture, and the capture inside the guest's own
    # counters (tcpdump's, when the scenario stopped it).
    for d, _ in caps:
        stop_ev = "guest_capture_stop" if d["kind"] == "guest" else "capture_stop"
        stop_host = event_time(events, stop_ev)
        if stop_host is not None and d["last"] is not None:
            gap = stop_host + d["clock"]["offset_low"] - d["last"]
            d["tail_gap"] = round(gap, 1)
            if gap > args.max_tail_gap:
                capture_problems.append("the last frame of %s is %.0f s before the scenario stopped the capture: "
                                        "frames at the end may be missing" % (d["name"], gap))
        if d["kind"] == "guest" and args.arm_event:
            stops = [dt for n, _, dt in events if n == "guest_capture_stop"]
            kv = _detail_values(stops[-1]) if stops else {}
            d["tcpdump"] = kv
            if not stops:
                capture_problems.append("%s was never stopped by the scenario (no guest_capture_stop event): "
                                        "frames at the end may be missing" % d["name"])
            elif not kv.get("dropped", "").isdigit():
                capture_problems.append("tcpdump in the guest gave no counters when it was stopped (%s): it may "
                                        "have stopped early" % (stops[-1] or "no detail"))
            elif kv["dropped"] != "0":
                capture_problems.append("tcpdump in the guest dropped %s packet(s): %s misses them"
                                        % (kv["dropped"], d["name"]))
    result["tail_gap"] = caps[0][0].get("tail_gap") if caps else None
    result["capture_problems"] = capture_problems

    dest = destinations(args, notes, errors)
    result["destinations"] = dest

    tor_after_arm = sum(phase_counts.get("post-arm", {}).get(c, 0)
                        for c in ("tor-relay", "tor-directory", "bridge"))
    result["post_arm_tor_packets"] = tor_after_arm

    # Verdict.
    reasons = []

    def blind(reason):
        reasons.append(reason)
        return "blind" if verdict == "pass" else verdict

    if errors:
        verdict = "error"
        reasons += errors
    elif not items:
        verdict = "error"
        reasons.append("the capture holds no frames")
    elif totals["outbound"] == 0:
        verdict = "blind"
        reasons.append("the capture shows no packet from the guest: it cannot show a leak either")
    elif not cutoffs:
        verdict = "info"
        reasons.append("no arm event: everything is listed, nothing is judged (baseline)")
        notes.extend(capture_problems)
    else:
        verdict = "pass"
        if leaks:
            verdict = "fail"
            reasons.append("%d flow(s) after arm are LEAKs (%d packets)" % (
                len(leaks), sum(f["phases"].get("post-arm", 0) for f in leaks)))
        if coverage["missing"]:
            verdict = blind("the capture misses %d of tor's %d connections (%s): it does not see every "
                            "path out of the phone" % (len(coverage["missing"]), len(coverage["expected"]),
                                                       ", ".join(coverage["missing"][:5])))
        if coverage["addresses_missing"]:
            verdict = blind("the device had address(es) the capture never saw sending on their interface (%s): "
                            "the capture misses an interface" % ", ".join(coverage["addresses_missing"][:5]))
        for problem in capture_problems:
            verdict = blind(problem)
        if args.require_armed_window and armed["status"] in ("not-asked", "not-run", "too-short"):
            verdict = blind("the armed window (%s) is %s: the armed state was not tested"
                            % (args.armed_window or "not given", armed["status"]))
        elif armed["status"] == "fail":
            reasons.append("%d packet(s) left while the firewall was armed" % armed["leaks"])
        if args.require_tor_traffic and tor_after_arm == 0:
            verdict = blind("no Tor traffic after arm: either tor never connected or the capture "
                            "misses the path it used")
        if tordir.info["consensus"] is None:
            reasons.append("no consensus: Tor relays cannot be told apart from other servers")
            if args.require_tor_traffic:
                verdict = "error"
        if dest is not None and dest["mode"] == "strict":
            if dest["status"] == "unexpected":
                if verdict in ("pass", "blind"):
                    verdict = "fail"
                reasons.append("%d unexpected name(s) or destination(s) through Tor: %s" % (
                    len(dest["unexpected"]), "; ".join(dest["unexpected"][:5])))
            elif dest["status"] == "not-recorded":
                verdict = blind("names and destinations through Tor were not recorded")
        elif dest is not None and dest["unexpected"]:
            notes.append("%d name(s) or destination(s) through Tor are not on the expected list "
                         "(learning mode: listed, not judged)" % len(dest["unexpected"]))
        if verdict == "pass":
            reasons.append("zero LEAK after arm (%d packets after arm, %d of them to the Tor network)"
                           % (sum(phase_counts.get("post-arm", {}).values()), tor_after_arm))
    result["verdict"] = verdict
    result["verdict_reasons"] = reasons
    result["notes"] = notes
    return result


def _add_flow(flows, key, p, cls, phase, name, view, host_ts):
    """Adds packet p to its flow, counted under its view."""
    f = flows.get(key)
    if f is None:
        f = flows[key] = {
            "l3": p.l3, "proto": p.proto, "src": p.src, "sport": p.sport if p.proto in ("tcp", "udp") else None,
            "dst": p.dst, "dport": p.dport if p.proto in ("tcp", "udp") else None,
            "icmp_type": p.icmp_type, "src_mac": p.src_mac, "class": cls[0], "kind": cls[1],
            "reason": cls[2], "label": cls[3], "packets": 0, "bytes": 0, "syn": False,
            "phases": {}, "seen": {}, "names": set(), "first_ts": host_ts, "last_ts": host_ts,
        }
    elif cls[0] == LEAK and f["class"] != LEAK:
        # A flow that was allowed before arm and continues after it is a
        # LEAK from that packet on (for example the marker after arm).
        f.update({"class": cls[0], "kind": cls[1], "reason": cls[2], "label": cls[3]})
    s = f["seen"].setdefault(view, {"packets": 0, "bytes": 0})
    s["packets"] += 1
    s["bytes"] += p.length or 0
    s[phase] = s.get(phase, 0) + 1
    f["first_ts"] = min(f["first_ts"], host_ts)
    f["last_ts"] = max(f["last_ts"], host_ts)
    if p.tcp_syn_only:
        f["syn"] = True
    if name:
        f["names"].add(name)
    if p.proto == "udp" and p.sport == 68 and p.dport == 67 and "dhcp" not in f:
        d = pcapread.dhcp_options(p.payload)
        if d:
            f["dhcp"] = d


def _finish_flow(f):
    """A flow's packets, bytes and phases over its views (see merged)."""
    seen = f["seen"]
    f["packets"] = merged({v: s["packets"] for v, s in seen.items()})
    f["bytes"] = merged({v: s["bytes"] for v, s in seen.items()})
    phases = sorted({k for s in seen.values() for k in s if k not in ("packets", "bytes")})
    f["phases"] = {ph: merged({v: s.get(ph, 0) for v, s in seen.items()}) for ph in phases}


# ---------------------------------------------------------------------------
# Reports
# ---------------------------------------------------------------------------

def _dest_rows(flows, phase_filter=None):
    """Flows merged by (proto, destination, port, class), with their
    packets per view ("seen") and over the views (see merged)."""
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
                             "first": f["first"], "dhcp": f.get("dhcp"), "seen": {}}
        r["flows"] += 1
        views = f.get("seen") or {"?:?": dict(f["phases"], packets=f["packets"])}
        for view, s in views.items():
            n = s.get(phase_filter, 0) if phase_filter else s.get("packets", 0)
            if n:
                r["seen"][view] = r["seen"].get(view, 0) + n
        r["names"].update(f["names"])
        if f["first"] is not None and (r["first"] is None or f["first"] < r["first"]):
            r["first"] = f["first"]
    out = sorted(rows.values(), key=lambda r: (r["first"] if r["first"] is not None else 0))
    for r in out:
        r["names"] = sorted(r["names"])
        r["packets"] = merged(r["seen"])
    return out


def seen_text(seen):
    """'wlan0 (guest 3), eth0 (emulator 2, guest 2)' from packets per view."""
    by_iface = {}
    for view, n in seen.items():
        kind, iface = view.split(":", 1)
        by_iface.setdefault(iface, []).append("%s %d" % (kind, n))
    return ", ".join(("%s (%s)" % (i, ", ".join(sorted(v)))) if i != "?" else ", ".join(sorted(v))
                     for i, v in sorted(by_iface.items()))


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
    what = {"emulator": "the emulator's own, its first network card", "capture": "a capture",
            "guest": "inside the guest, every interface after netfilter; loopback left out"}
    for c in caps:
        dur = (c["last"] - c["first"]) if c.get("first") is not None and c.get("last") is not None else 0
        extra = []
        clock = c.get("clock") or {}
        if clock.get("source") == "marker":
            extra.append("Clock: capture minus host = %.3f s (between %.3f and %.3f, from %d marker(s))" % (
                clock["offset"], clock["offset_low"], clock["offset_high"], clock.get("markers", 1)))
        else:
            extra.append("Clock: no marker")
        if c.get("cutoff_t") is not None:
            extra.append("arm cutoff at t+%.1f s (margin %.1f s)" % (c["cutoff_t"], c.get("margin", 0)))
        if (c.get("totals") or {}).get("loopback"):
            extra.append("%d loopback frame(s) left out" % c["totals"]["loopback"])
        if c.get("tcpdump"):
            extra.append("tcpdump: %s" % ", ".join("%s %s" % kv for kv in sorted(c["tcpdump"].items())))
        if c.get("device_clock_moved") is not None:
            extra.append("the device's clock, read again later, %s" % (
                "moved %.1f s beyond the marker's bounds" % c["device_clock_moved"] if c["device_clock_moved"]
                else "stayed within the marker's bounds"))
        lines.append("- Capture `%s` (%s%s): %s, %d frames over %.0f s%s. %s." % (
            os.path.basename(c["path"]), what.get(c.get("kind"), c.get("kind")),
            ": " + c["iface"] if c.get("iface") else "", c["format"], c["records"], dur,
            " (cut short at the end)" if c.get("truncated") else "", "; ".join(extra)))
    lines.append("- Frames: %d; sent by the phone: %d (from an address not its own: %d); from the "
                 "emulator's network: %d; other stations: %d; not decoded: %d; on loopback: %d. Packets seen "
                 "by two captures of one interface count once. Attribution: %s." % (
                     t.get("frames", 0), t.get("outbound", 0), t.get("unattributed", 0),
                     t.get("from_emulator", 0), t.get("not_the_phone", 0), t.get("undecoded", 0),
                     t.get("loopback", 0),
                     "every frame that is not slirp's is the phone's" if s.get("network") == "emulator"
                     else "by address (a capture on a real network)"))
    if s.get("interfaces"):
        lines.append("- Interfaces in the captures: %s." % ", ".join(
            "%s (%s)" % (i, ", ".join(k)) for i, k in sorted(s["interfaces"].items())))
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
    arm = s.get("arm")
    if arm:
        lines.append("- Arm cutoff: t+%.1f s (%s, host time; event `%s` minus each capture's margin and clock "
                     "uncertainty). Every packet from there on counts." % (
                         arm.get("cutoff_t") or 0, arm.get("cutoff_utc"), arm.get("event")))
    ma = s.get("module_arm")
    if ma:
        if ma.get("t") is not None:
            lines.append("- The module's log: `firewall armed` at %s by the device's clock, t+%.1f s (host time "
                         "%s to %s)%s. It is written after the arm, so it is not the cutoff." % (
                             ma["device_utc"], ma["t"], iso(ma["host_low"]), iso(ma["host_high"]),
                             ", %.1f s or more after the cutoff" % ma["after_cutoff"]
                             if ma.get("after_cutoff") is not None else ""))
        else:
            lines.append("- The module's log: `firewall armed` at %s by the device's clock (not placed: the "
                         "device's clock was not read)." % ma["device_utc"])
    aw = s.get("armed_window") or {}
    if aw.get("status") not in (None, "not-asked"):
        if aw.get("start_t") is not None:
            lines.append("- Armed window (`%s` to `%s`): t+%.1f to t+%.1f s, %s s; %d packet(s) from the phone, "
                         "%d of them ARP or DHCP; %d LEAK(s): **%s**." % (
                             aw.get("start_event"), aw.get("end_event"), aw["start_t"], aw["end_t"],
                             aw.get("seconds"), aw.get("packets", 0), aw.get("allowed", 0), aw.get("leaks", 0),
                             aw.get("status")))
        else:
            lines.append("- Armed window (`%s` to `%s`): **%s**." % (aw.get("start_event"), aw.get("end_event"),
                                                                    aw.get("status")))
    if s.get("dhcp_pre_arm_leases"):
        lines.append("- Addresses the phone held before arm (a DHCP request for one after arm is a LEAK): %s."
                     % ", ".join(s["dhcp_pre_arm_leases"]))
    for problem in s.get("capture_problems", []):
        lines.append("- Capture: " + _md_escape(problem) + ".")
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
            lines.append("| First (t+s) | Kind | Destination | Name | Packets | Seen on | Why |")
            lines.append("|---|---|---|---|---|---|---|")
            for r in leak_rows[:200]:
                lines.append("| %s | %s | `%s` | %s | %d | %s | %s |" % (
                    r["first"], r["kind"], _dest(r), _md_escape(", ".join(r["names"][:3]) or r["label"] or ""),
                    r["packets"], _md_escape(seen_text(r["seen"])), _md_escape(r["reason"])))
            lines.append("")
        tor_rows = [r for r in _dest_rows(flows, "post-arm") if r["class"] in ("tor-relay", "tor-directory", "bridge")]
        lines.append("### Tor network after arm: %d destination(s)" % len(tor_rows))
        lines.append("")
        if tor_rows:
            lines.append("| First (t+s) | Class | Destination | What | Packets | Seen on |")
            lines.append("|---|---|---|---|---|---|")
            for r in tor_rows[:60]:
                lines.append("| %s | %s | `%s` | %s | %d | %s |" % (
                    r["first"], r["class"], _dest(r), _md_escape(r["label"] or ""), r["packets"],
                    _md_escape(seen_text(r["seen"]))))
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
    if cov.get("status") not in (None, "not-checked"):
        lines.append("### Coverage")
        lines.append("")
        lines.append("tor reported %d established connection(s); the capture saw %d; missing: %s." % (
            len(cov.get("expected", [])), len(cov.get("seen", [])), ", ".join(cov.get("missing", [])) or "none"))
        if cov.get("addresses"):
            lines.append("")
            lines.append("The device's addresses at the end: %s; never seen sending on their interface: %s." % (
                ", ".join(cov["addresses"]), ", ".join(cov.get("addresses_missing", [])) or "none"))
        lines.append("")
    lines.extend(destinations_md(s.get("destinations")))
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


def destinations_md(d):
    if not d:
        return []
    src = d.get("sources", {})
    lines = ["### Names and destinations through Tor", ""]
    lines.append("Recorded: tor's STREAM events %s; the DNS filter's query log %s. Expected list: `%s`. "
                 "Mode: %s (%s)." % (
                     "yes" if src.get("tor_streams") else "**no**",
                     "yes" if src.get("filter_debug") else ("**no** (not in debug mode)" if src.get("filter_log")
                                                            else "**no**"),
                     os.path.basename(d.get("expected_file") or "none"), d.get("mode"),
                     "an unexpected one fails the run" if d.get("mode") == "strict"
                     else "unexpected ones are listed, not judged yet"))
    lines.append("")
    if d.get("unexpected"):
        lines.append("**Not on the expected list (%d):**" % len(d["unexpected"]))
        lines.append("")
        for u in d["unexpected"][:100]:
            lines.append("- " + _md_escape(u))
        lines.append("")
    names = d.get("names", [])
    lines.append("%d name(s) looked up:" % len(names))
    lines.append("")
    if names:
        lines.append("| Name | Types | Filter's answers | Through Tor | Expected |")
        lines.append("|---|---|---|---|---|")
        for r in names[:300]:
            lines.append("| `%s` | %s | %s | %s | %s |" % (
                _md_escape(repr(r["name"])[1:-1]), ", ".join(r.get("types", [])),
                _md_escape(", ".join("%s %d" % kv for kv in sorted(r.get("decisions", {}).items()))) or "-",
                ("yes (%d resolve(s))" % r.get("tor_resolves", 0)) if r.get("tor_resolves") else
                ("yes" if r.get("reached") else "no"),
                "yes" if r.get("expected") else "**no**"))
        lines.append("")
    targets = d.get("targets", [])
    lines.append("%d destination(s) asked of tor's TransPort:" % len(targets))
    lines.append("")
    if targets:
        lines.append("| Target | Streams | Outcome | Names | Expected |")
        lines.append("|---|---|---|---|---|")
        for t in targets[:300]:
            lines.append("| `%s` | %d | %s | %s | %s |" % (
                _md_escape(t["target"]), t["streams"],
                _md_escape(", ".join("%s %d" % kv for kv in sorted(t["statuses"].items()))
                           + ("; " + ", ".join(t["reasons"]) if t.get("reasons") else "")),
                _md_escape(", ".join(t.get("names", []))) or "-", "yes" if t.get("expected") else "**no**"))
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

- Two views are captured: the emulator's own capture of its first network
  card (eth0, the emulated radio) and tcpdump inside the guest on every
  interface (Wi-Fi included), which records a frame as it leaves an
  interface, after netfilter. Traffic the phone's hardware sends by itself
  (Wi-Fi keep-alive offload, the modem) has no equivalent in the emulator;
  the January capture on the phone covers it. The module's keep-alive
  overlay has no effect here either: without Magisk nothing mounts it.
- A packet capture cannot tell which app sent a packet. A connection to a Tor
  relay counts as Tor traffic even if an app other than tor made it.
- What travels through Tor is not in the capture. tor's STREAM events and
  the DNS filter's query log (debug mode, on the emulator only) list the
  names and destinations reached through Tor; see the section above.
- The emulator runs Android 16 (API 36, Google's image without Google
  services) on a 6.x kernel, not LineageOS 23.2 on the phone's 4.14 kernel,
  and is rooted with adb root, not Magisk: the module's scripts are started
  by hand after boot, so the boot path itself (the firewall armed before
  netd and zygote exist) is not what runs here. The armed window tests the
  armed rule set with the network up instead.
- Not covered yet (work queue): a reboot with the module (Magisk-rooted
  emulator), Magisk's Safe Mode and a start without the module, tor or the
  DNS filter killed during a session, a network change, IPv6 router
  advertisements, DHCP renewal over a long session, and the keep-alive
  offload check."""


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
    a.add_argument("--pcap", action="append",
                   help="the emulator's capture (-tcpdump: its first network card), or a capture on a real network")
    a.add_argument("--pcap-iface", help="the guest interface --pcap records (eth0 for the emulator's)")
    a.add_argument("--guest-pcap", action="append",
                   help="a capture inside the guest on every interface (tcpdump -i any), on the device's clock")
    a.add_argument("--guest-links", help="the guest's 'ip -o link' and 'ip -o addr' (interface names)")
    a.add_argument("--network", choices=("emulator", "lan"), default="emulator",
                   help="emulator: every frame on the Ethernet that is not slirp's is the phone's "
                        "(default); lan: a capture on a real network, attributed by address")
    a.add_argument("--events")
    a.add_argument("--module-log", help="the module's log: its 'firewall armed' line goes on the time line")
    a.add_argument("--arm-event")
    a.add_argument("--judge-from-start", action="store_true",
                   help="judge every packet (a capture on the phone, with no arm event)")
    a.add_argument("--arm-margin", type=float)
    a.add_argument("--armed-window", metavar="START:END",
                   help="two events between which the firewall was only armed")
    a.add_argument("--require-armed-window", action="store_true")
    a.add_argument("--consensus")
    a.add_argument("--tor-binary")
    a.add_argument("--bridges")
    a.add_argument("--guest", action="append")
    a.add_argument("--expect-seen")
    a.add_argument("--expect-guest", help="the device's addresses at the end ('ip addr' output)")
    a.add_argument("--require-tor-traffic", action="store_true")
    a.add_argument("--max-tail-gap", type=float, default=120.0,
                   help="seconds the last frame may lie before the capture_stop event (default 120)")
    a.add_argument("--tor-streams", help="tor's STREAM events (ci/lib/tor-streams.sh)")
    a.add_argument("--filter-log", help="the DNS filter's log, written with -debug-log-queries")
    a.add_argument("--expected-destinations", help="names and targets expected through Tor")
    a.add_argument("--destinations-mode", choices=("learning", "strict"), default="learning")
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
