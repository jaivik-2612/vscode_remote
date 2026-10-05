#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive an Antumbra qemu-virt VM started by build/vm.sh: serial-log waits,
commands over the debug console (hvc0), QMP (screenshots, power button),
packet-capture summaries, and the smoke test. Standard library only.

usage: antumbra_vm.py [--run-dir DIR] COMMAND ...
  smoke [--timeout-scale F] [--no-stop] [--through-welcome [--tour]] [--camera] [--android | --android-net | --persistence]
                                          boot, check, power down; exit 1 on any failure
                                          (--android, --android-net: images built with ANTUMBRA_ANDROID=1;
                                          --persistence: creates Persistent Storage, with -- --keep-disk unlocks it)
  wait REGEX [--timeout S]                wait for REGEX in the serial log
  shell CMD...                            run a command on the debug console, print its output
  screenshot FILE.png                     dump the display
  qmp COMMAND [key=value ...]             send a QMP command (e.g. system_powerdown, quit)
  pcap-summary                            summarise net.pcap by destination
  console                                 attach to the serial console (raw, Ctrl-] detaches)
"""
import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import socket
import struct
import subprocess
import sys
import time
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
VERSION = open(os.path.join(ROOT, "VERSION")).read().strip()


class Timeout(Exception):
    pass


# ---------------------------------------------------------------------------
# Serial log
# ---------------------------------------------------------------------------
class SerialLog:
    """The guest's ttyAMA0 output as QEMU appends it to serial.log."""

    def __init__(self, path):
        self.path = path
        self.pos = 0

    def read_new(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.pos)
                data = f.read()
        except FileNotFoundError:
            return ""
        self.pos += len(data)
        return data.decode("utf-8", "replace")

    def wait(self, pattern, timeout, fail_patterns=(r"Kernel panic", r"Rebooting automatically", r"end Kernel panic")):
        """Return the match when PATTERN appears in new output; raise on a
        failure pattern or when QEMU is gone (the log stops growing)."""
        rx = re.compile(pattern)
        fails = [re.compile(p) for p in fail_patterns]
        buf = ""
        deadline = time.monotonic() + timeout
        while True:
            chunk = self.read_new()
            if chunk:
                buf += chunk
                m = rx.search(buf)
                if m:
                    return m
                for frx in fails:
                    fm = frx.search(buf)
                    if fm:
                        raise Timeout(f"failure marker {frx.pattern!r} while waiting for {pattern!r}: ...{buf[max(0, fm.start()-200):fm.end()+200]}")
                buf = buf[-65536:]
            if time.monotonic() > deadline:
                raise Timeout(f"timeout ({timeout}s) waiting for {pattern!r}; last output: ...{buf[-800:]}")
            time.sleep(0.5)


# ---------------------------------------------------------------------------
# QMP
# ---------------------------------------------------------------------------
class Qmp:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(30)
        self.sock.connect(path)
        self.buf = b""
        self._recv()  # greeting
        self.execute("qmp_capabilities")

    def _recv(self):
        while True:
            nl = self.buf.find(b"\n")
            if nl >= 0:
                line, self.buf = self.buf[:nl], self.buf[nl + 1:]
                if line.strip():
                    msg = json.loads(line)
                    if "event" in msg:
                        continue
                    return msg
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("QMP connection closed")
            self.buf += chunk

    def execute(self, command, **arguments):
        self.sock.sendall(json.dumps({"execute": command, "arguments": arguments}).encode() + b"\n")
        reply = self._recv()
        if "error" in reply:
            raise RuntimeError(f"QMP {command}: {reply['error']}")
        return reply.get("return")

    def close(self):
        self.sock.close()


# ---------------------------------------------------------------------------
# Debug console (hvc0)
# ---------------------------------------------------------------------------
class Console:
    """A root shell on the virtio console of a debug build (antumbra.debug=1).
    Every command is bracketed by a unique marker so echo and prompts never
    confuse the parser."""

    def __init__(self, sock_path, log_path):
        self.sock_path = sock_path
        self.log_path = log_path
        self.sock = None

    def wait_ready(self, timeout):
        """The getty has started once a shell prompt shows in hvc0.log."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                text = open(self.log_path, "rb").read().decode("utf-8", "replace")
            except FileNotFoundError:
                text = ""
            if re.search(r"root@[^\s]*:[^\n]*# ", text) or re.search(r"\n[^\n]*# $", text):
                return
            time.sleep(1)
        raise Timeout(f"no shell prompt on hvc0 after {timeout}s (debug build with antumbra.debug=1?)")

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(self.sock_path)
        self.sock.settimeout(1)
        # A fresh shell without echo and with a known prompt.
        self._raw("stty -echo; export TERM=dumb PS1='antumbra-vm# ' LC_ALL=C\n")
        time.sleep(1)
        self._drain()

    def _raw(self, text):
        self.sock.sendall(text.encode())

    def _drain(self):
        try:
            while self.sock.recv(65536):
                pass
        except socket.timeout:
            pass

    def run(self, cmd, timeout=120):
        """Return (exit code, output) of CMD run by the root shell."""
        if self.sock is None:
            self.connect()
        marker = secrets.token_hex(6)
        self._drain()
        self._raw(f"{cmd}\nprintf '\\n@@%s rc=%s@@\\n' {marker} $?\n")
        rx = re.compile(r"@@" + marker + r" rc=(\d+)@@")
        buf = b""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise RuntimeError("console closed")
                buf += chunk
            except socket.timeout:
                pass
            text = buf.decode("utf-8", "replace")
            m = rx.search(text)
            if m:
                out = text[:m.start()].replace("\r\n", "\n")
                out = re.sub(r"antumbra-vm# ", "", out)
                return int(m.group(1)), out.strip("\n")
        raise Timeout(f"console command timed out: {cmd!r}; got {buf[-500:]!r}")

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None


# ---------------------------------------------------------------------------
# PPM -> PNG (QMP screendump writes binary PPM)
# ---------------------------------------------------------------------------
def ppm_to_png(ppm_path, png_path):
    data = open(ppm_path, "rb").read()
    # P6\n<w> <h>\n255\n<rgb bytes>; whitespace may vary.
    m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
    if not m:
        raise ValueError("not a binary PPM")
    w, h, maxval = int(m.group(1)), int(m.group(2)), int(m.group(3))
    pixels = data[m.end():]
    if maxval != 255 or len(pixels) < w * h * 3:
        raise ValueError("unsupported PPM")
    raw = b"".join(b"\x00" + pixels[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, body):
        c = struct.pack(">I", len(body)) + tag + body
        return c + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    open(png_path, "wb").write(png)
    return w, h


# ---------------------------------------------------------------------------
# pcap summary
# ---------------------------------------------------------------------------
def pcap_summary(path):
    """Count frames by (protocol, destination, port) from QEMU's filter-dump."""
    counts = {}
    try:
        data = open(path, "rb").read()
    except FileNotFoundError:
        return counts
    if len(data) < 24:
        return counts
    magic = struct.unpack("<I", data[:4])[0]
    endian = "<" if magic in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    pos = 24
    while pos + 16 <= len(data):
        _, _, incl, _ = struct.unpack(endian + "IIII", data[pos:pos + 16])
        frame = data[pos + 16:pos + 16 + incl]
        pos += 16 + incl
        if len(frame) < 14:
            continue
        src_mac = ":".join(f"{b:02x}" for b in frame[6:12])
        etype = struct.unpack(">H", frame[12:14])[0]
        key = None
        if etype == 0x0800 and len(frame) >= 34:
            ihl = (frame[14] & 0x0F) * 4
            proto = frame[23]
            dst = ".".join(str(b) for b in frame[30:34])
            l4 = frame[14 + ihl:]
            if proto in (6, 17) and len(l4) >= 4:
                dport = struct.unpack(">H", l4[2:4])[0]
                key = ({6: "tcp", 17: "udp"}[proto], dst, dport)
            else:
                key = (f"ip-proto-{proto}", dst, 0)
        elif etype == 0x0806:
            key = ("arp", "-", 0)
        elif etype == 0x86DD:
            key = ("ipv6", "-", 0)
        else:
            key = (f"ethertype-{etype:04x}", "-", 0)
        key = key + (src_mac,)
        counts[key] = counts.get(key, 0) + 1
    return counts


SLIRP_MAC_PREFIXES = ("52:55:", "52:56:")   # QEMU's user network: 52:55:<IPv4>, 52:56:<IPv6>


def pcap_tcp_syns(path):
    """{(source MAC, destination IP, destination port)} of every TCP SYN
    (without ACK) in the capture: the connections something tried to open."""
    syns = set()
    try:
        data = open(path, "rb").read()
    except FileNotFoundError:
        return syns
    if len(data) < 24:
        return syns
    endian = "<" if struct.unpack("<I", data[:4])[0] in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    pos = 24
    while pos + 16 <= len(data):
        _, _, incl, _ = struct.unpack(endian + "IIII", data[pos:pos + 16])
        frame = data[pos + 16:pos + 16 + incl]
        pos += 16 + incl
        if len(frame) < 34 or struct.unpack(">H", frame[12:14])[0] != 0x0800 or frame[23] != 6:
            continue
        l4 = frame[14 + (frame[14] & 0x0F) * 4:]
        if len(l4) >= 14 and (l4[13] & 0x12) == 0x02:
            syns.add((":".join(f"{b:02x}" for b in frame[6:12]),
                      ".".join(str(b) for b in frame[30:34]), struct.unpack(">H", l4[2:4])[0]))
    return syns


def pcap_ipv4(path):
    """[(source MAC, source IP, destination IP, protocol, destination port)]
    of every IPv4 frame in the capture (port 0 for protocols without one)."""
    frames = []
    try:
        data = open(path, "rb").read()
    except FileNotFoundError:
        return frames
    if len(data) < 24:
        return frames
    endian = "<" if struct.unpack("<I", data[:4])[0] in (0xA1B2C3D4, 0xA1B23C4D) else ">"
    pos = 24
    while pos + 16 <= len(data):
        _, _, incl, _ = struct.unpack(endian + "IIII", data[pos:pos + 16])
        frame = data[pos + 16:pos + 16 + incl]
        pos += 16 + incl
        if len(frame) < 34 or struct.unpack(">H", frame[12:14])[0] != 0x0800:
            continue
        proto = frame[23]
        l4 = frame[14 + (frame[14] & 0x0F) * 4:]
        dport = struct.unpack(">H", l4[2:4])[0] if proto in (6, 17) and len(l4) >= 4 else 0
        frames.append((":".join(f"{b:02x}" for b in frame[6:12]), ".".join(str(b) for b in frame[26:30]),
                       ".".join(str(b) for b in frame[30:34]), proto, dport))
    return frames


def tor_builtin_addresses(text):
    """{(IP, port)} of the directory authorities and fallback directories compiled
    into Tor: the only places it connects to before it has a consensus."""
    addrs = {(ip, int(op)) for ip, op in re.findall(r"(\d+\.\d+\.\d+\.\d+) orport=(\d+)", text)}
    for op, ip, dp in re.findall(r"orport=(\d+)\S*(?: \S+)*? (\d+\.\d+\.\d+\.\d+):(\d+)(?: |$)", text, re.M):
        addrs |= {(ip, int(op)), (ip, int(dp))}
    return addrs


def ints(o, n):
    """Exactly N integers, one per line, or ValueError."""
    v = [int(x) for x in o.strip().split("\n")]
    if len(v) != n:
        raise ValueError(o)
    return v


# ---------------------------------------------------------------------------
# VM
# ---------------------------------------------------------------------------
class VM:
    def __init__(self, run_dir):
        self.run = os.path.abspath(run_dir)   # QEMU resolves paths from its own cwd
        self.serial = SerialLog(os.path.join(run_dir, "serial.log"))
        self.console = Console(os.path.join(run_dir, "hvc0.sock"), os.path.join(run_dir, "hvc0.log"))

    def start(self, args):
        subprocess.run([os.path.join(ROOT, "build", "vm.sh"), "start"] + list(args), check=True)
        self.serial.pos = 0

    def pid(self):
        try:
            return int(open(os.path.join(self.run, "qemu.pid")).read().strip())
        except (FileNotFoundError, ValueError):
            return None

    def alive(self):
        """True only for a live process whose command line names this run's
        QMP socket (a reused PID is not our VM)."""
        pid = self.pid()
        if pid is None:
            return False
        try:
            os.kill(pid, 0)
            return f"unix:{self.run}/qmp.sock".encode() in open(f"/proc/{pid}/cmdline", "rb").read()
        except OSError:
            return False

    def qmp(self, command, **arguments):
        q = Qmp(os.path.join(self.run, "qmp.sock"))
        try:
            return q.execute(command, **arguments)
        finally:
            q.close()

    def screenshot(self, png_path):
        ppm = os.path.join(self.run, "screendump.ppm")
        self.qmp("screendump", filename=ppm)
        for _ in range(50):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 64:
                break
            time.sleep(0.2)
        return ppm_to_png(ppm, png_path)

    def stop(self):
        subprocess.run([os.path.join(ROOT, "build", "vm.sh"), "stop"], check=False)

    # Input through QMP: the virtio tablet takes absolute coordinates (0..32767),
    # given here in display pixels (720x1440 unless vm.sh is changed).
    DISPLAY_W, DISPLAY_H = 720, 1440

    def _abs(self, x, y):
        return [{"type": "abs", "data": {"axis": "x", "value": int(x * 32767 / (self.DISPLAY_W - 1))}},
                {"type": "abs", "data": {"axis": "y", "value": int(y * 32767 / (self.DISPLAY_H - 1))}}]

    def tap(self, x, y):
        self.qmp("input-send-event", events=self._abs(x, y))
        time.sleep(0.2)
        self.qmp("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": "left"}}])
        time.sleep(0.15)
        self.qmp("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "left"}}])

    def swipe(self, x1, y1, x2, y2, steps=12):
        self.qmp("input-send-event", events=self._abs(x1, y1))
        self.qmp("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": "left"}}])
        for i in range(1, steps + 1):
            time.sleep(0.04)
            self.qmp("input-send-event", events=self._abs(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps))
        self.qmp("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "left"}}])

    def pixels(self):
        """(width, height, rgb bytes) of the current display."""
        ppm = os.path.join(self.run, "screendump.ppm")
        if os.path.exists(ppm):
            os.unlink(ppm)
        self.qmp("screendump", filename=ppm)
        for _ in range(50):
            if os.path.exists(ppm) and os.path.getsize(ppm) > 64:
                break
            time.sleep(0.2)
        data = open(ppm, "rb").read()
        m = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", data)
        return int(m.group(1)), int(m.group(2)), data[m.end():]

    def find_color(self, rgb, tol=40, region=None, min_pixels=200):
        """Centre of the pixels within TOL of RGB (optionally inside region
        (x0, y0, x1, y1)), or None if fewer than MIN_PIXELS match."""
        w, h, px = self.pixels()
        x0, y0, x1, y1 = region or (0, 0, w, h)
        xs = ys = n = 0
        for y in range(y0, min(y1, h), 2):
            row = y * w * 3
            for x in range(x0, min(x1, w), 2):
                i = row + x * 3
                if abs(px[i] - rgb[0]) <= tol and abs(px[i + 1] - rgb[1]) <= tol and abs(px[i + 2] - rgb[2]) <= tol:
                    xs += x; ys += y; n += 1
        if n * 4 < min_pixels:
            return None
        return xs // n, ys // n

    def distinct_colors(self, step=8):
        """How many distinct (coarsely quantised) colours the display shows:
        a black or text-console screen has few, a rendered UI many."""
        w, h, px = self.pixels()
        seen = set()
        for y in range(0, h, step):
            for x in range(0, w, step):
                i = (y * w + x) * 3
                seen.add((px[i] >> 4, px[i + 1] >> 4, px[i + 2] >> 4))
        return len(seen)


# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
class Report:
    def __init__(self):
        self.results = []
        self.t0 = time.monotonic()

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail, round(time.monotonic() - self.t0, 1)))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""), flush=True)
        return ok

    def failed(self):
        return [r for r in self.results if not r[1]]


QEMU_MAC = "52:54:00:a1:7b:01"   # build/vm.sh assigns it; spoofing must replace it
# The theme accent (--accent-bg-color in config/rootfs/usr/share/antumbra/theme/apps.css),
# which fills the Welcome screen's Start button.
WELCOME_ACCENT = (0xce, 0xbd, 0xfe)


def welcome_phase(vm, rep, T, sh, out, tour, android=False, android_net=False):
    """Press "Start Antumbra" with the defaults (amnesic, MAC anonymization on,
    connect to Tor automatically), with Android apps switched on if asked,
    and check what happens to the network."""
    # The button is drawn in exactly the accent colour; at a tolerance of 45
    # this light accent would also match the edges of near-white text.
    target = vm.find_color(WELCOME_ACCENT, tol=30, region=(0, 1100, 720, 1440))
    rep.check("welcome: Start button found on the display", target is not None, str(target))
    if target is None:
        return
    if android:
        # Found first: an Android switch turned on is drawn in the same accent.
        enable_android_switch(vm, rep, T, out)
    vm.tap(*target)
    # The session starts once the root-side applier has consumed the settings.
    session = False
    deadline = time.monotonic() + T(420)
    while time.monotonic() < deadline:
        rc, o = sh("pgrep -xc phosh; test -e /var/lib/antumbra/settings/applied/tails.network && echo applied", timeout=60)
        lines = o.strip().split("\n")
        if rc == 0 and len(lines) == 2 and lines[0].isdigit() and int(lines[0]) > 0 and lines[1] == "applied":
            session = True
            break
        time.sleep(5)
    rep.check("welcome: settings applied and the Phosh session started", session, o.replace("\n", " "))
    # Network: the driver loads only now, behind the spoofed address. Not
    # counted: the namespaces' and containers' veths and the Android bridge,
    # which exist without any driver.
    up = False
    deadline = time.monotonic() + T(300)
    while time.monotonic() < deadline:
        rc, o = sh(f"ip -o -4 addr show scope global | grep -vE ': ({HOST_ONLY_LINKS})' | awk '{{print $2, $4}}'", timeout=60)
        if rc == 0 and re.search(r"^\S+ \d+\.\d+\.\d+\.\d+/\d+$", o, re.M):
            up = True
            break
        time.sleep(5)
    rc, links = sh(f"ip -o link | grep -vE ': (lo|{HOST_ONLY_LINKS})[:@]' | sed -E 's/^[0-9]+: ([^:@]+).* link\\/ether ([0-9a-f:]+).*/\\1 \\2/'; lsmod | grep -c '^virtio_net'", timeout=60)
    rep.check("after Welcome: the network driver loaded and the interface got an address", up, (o.strip() + " | " + links.replace("\n", " ")).strip(" |"))
    macs = re.findall(r"([0-9a-f]{2}(?::[0-9a-f]{2}){5})", links)
    rep.check("after Welcome: the interface's MAC address is not the hardware one", bool(macs) and QEMU_MAC not in macs,
              f"hardware {QEMU_MAC}, interface {', '.join(macs) or 'none'}")
    traffic_checks(vm, rep, T, sh, "after Welcome", int(T(90)))
    try:
        vm.screenshot(os.path.join(out, "session.png"))
    except Exception:  # noqa: BLE001
        pass
    if tour:
        take_tour(vm, rep, sh, out, T)
    if android:
        android_phase(vm, rep, T, sh, out)
    if android_net:
        android_net_phase(vm, rep, T, sh, out)


# The confined applications' namespace veths, the containers' host-side veths
# (LXC names them vethXXXXXX) and the Android bridge: links without a driver
# that never carry the phone's traffic to a network themselves.
HOST_ONLY_LINKS = r"veth[^:@ ]*|waydroid-tor"


def traffic_checks(vm, rep, T, sh, label, polls):
    """Record every socket in the system once a second for POLLS seconds (Tor's
    peers, and anything else that talks to the network), then judge the
    packet capture: only Tor may have reached the network, DHCP aside.
    LABEL names the phase in the check names."""
    rc, o = sh(f"for i in $(seq {polls}); do ss -tunapH state all; sleep 1; done | "
               "grep -vE '127\\.0\\.0\\.1|\\[::1\\]|10\\.200\\.1\\.|10\\.200\\.2\\.|LISTEN|UNCONN' | sort -u; echo end", timeout=polls * 3 + 120)
    socks = [l for l in o.split("\n") if l.strip() and l.strip() != "end"] if rc is not None else []
    # NetworkManager's DHCP client (udp :68 -> :67) is the one non-Tor flow
    # the firewall allows, as in Tails. (Sockets on 10.200.1.0/24 and
    # 10.200.2.0/30 are the confined applications' and Android's connections
    # to Tor's own listeners on this machine.)
    dhcp = [l for l in socks if l.startswith("udp") and '(("NetworkManager"' in l and re.search(r":68\s+\S+:67\s", l)]
    non_tor = [l for l in socks if '(("tor"' not in l and l not in dhcp]
    tor_peers = set()
    for l in socks:
        if '(("tor"' in l:
            m = re.search(r"\s(\d+\.\d+\.\d+\.\d+):(\d+)\s+users:", l)
            if m:
                tor_peers.add((m.group(1), int(m.group(2))))
    rep.check(f"{label}: every connection to the network belongs to Tor (DHCP aside)", rc is not None and not non_tor,
              f"{len(tor_peers)} Tor peers, {len(dhcp)} DHCP client sockets" + ((": " + " | ".join(x[:120] for x in non_tor[:4])) if non_tor else ""))
    # Before it has a consensus Tor only knows the addresses built into it; read
    # them from the guest's own binary.
    rc, o = sh("grep -aoE '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+ orport=[0-9]+|orport=[0-9]+[[:print:]]{0,200} "
               "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+ ' \"$(readlink -f /usr/bin/tor)\" | sort -u", timeout=120)
    builtin = tor_builtin_addresses(o) if rc == 0 else set()
    cap = "packet capture" if label == "after Welcome" else f"{label}, packet capture"
    if label == "after Welcome":
        rep.check("Tor: its built-in directory addresses could be read from the guest", len(builtin) > 20, f"{len(builtin)} addresses")
    capture = os.path.join(vm.run, "net.pcap")
    counts = pcap_summary(capture)
    # The capture holds both directions: judge every frame QEMU's user
    # network did not generate, whatever source MAC it carries.
    sent = {k: v for k, v in counts.items() if not k[3].startswith(SLIRP_MAC_PREFIXES)}
    bad = {k: v for k, v in sent.items()
           if k[0] == "ipv6" or (k[0] == "udp" and k[2] != 67) or k[0].startswith("ip-proto") or k[0].startswith("ethertype")}
    from_hw = {k: v for k, v in sent.items() if k[3] == QEMU_MAC}
    udp67 = sum(v for k, v in sent.items() if k[0] == "udp" and k[2] == 67)
    rep.check(f"{cap}: the guest sent no DNS, NTP, IPv6 or other UDP (DHCP aside)", not bad,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(bad.items())) or f"{sum(sent.values())} frames sent, {udp67} of them DHCP")
    syns = {(dst, port) for src, dst, port in pcap_tcp_syns(capture) if not src.startswith(SLIRP_MAC_PREFIXES)}
    stray = sorted(syns - tor_peers - builtin)
    rep.check(f"{cap}: every TCP connection the guest opened went to a Tor directory or relay", bool(syns) and not stray,
              (("not Tor's: " + ", ".join(f"{d}:{p}" for d, p in stray[:8])) if stray else
               f"{len(syns)} destinations: {len(syns & builtin)} built into Tor, {len(syns - builtin)} seen on Tor's sockets"))
    rep.check(f"{cap}: no frame carried the hardware MAC address", not from_hw,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(from_hw.items())) or f"guest frames came from {', '.join(sorted({k[3] for k in sent}))} only")


def take_tour(vm, rep, sh, out, T):
    """Best-effort screenshots of the session (no checks)."""
    def shot(name):
        try:
            vm.screenshot(os.path.join(out, name))
            print(f"tour: {name}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"tour: {name} failed: {e}", flush=True)
    # Phosh: a swipe up from the home bar opens the app overview, a pull
    # down from the top bar opens the quick settings.
    vm.swipe(360, 1425, 360, 500); time.sleep(T(15)); shot("tour-apps.png")
    vm.swipe(360, 500, 360, 1425); time.sleep(T(10))
    vm.swipe(360, 4, 360, 1000); time.sleep(T(15)); shot("tour-quick-settings.png")
    vm.swipe(360, 1000, 360, 4); time.sleep(T(10))
    # Tor Browser through its normal launcher chain (sudo helper, tbb namespace).
    sh("runuser -u amnesia -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 "
       "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus XDG_SESSION_TYPE=wayland "
       "setsid -f /usr/local/bin/tor-browser >/dev/null 2>&1; echo started", timeout=60)
    time.sleep(T(150))
    rc, o = sh("P=$(pgrep -u amnesia -f '/firefox' | head -1); echo procs=$(pgrep -u amnesia -fc '/firefox'); "
               "echo netns=$([ -n \"$P\" ] && ip netns identify $P)", timeout=60)
    f = dict(line.split("=", 1) for line in o.split("\n") if "=" in line)
    rep.check("tour: Tor Browser runs inside its own network namespace (tbb)",
              f.get("procs", "0") not in ("", "0") and f.get("netns", "").strip() == "tbb", o.replace("\n", " "))
    shot("tour-tor-browser.png")


# ---------------------------------------------------------------------------
# Camera (--camera): the camera path on the VM's virtual camera, vimc
# (config/hooks/72-vm-camera.sh, docs/camera.md, docs/vm-testing.md)
# ---------------------------------------------------------------------------
AS_AMNESIA = ("runuser -u amnesia -- env XDG_RUNTIME_DIR=/run/user/1000 "
              "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus ")
AS_AMNESIA_GUI = AS_AMNESIA + "WAYLAND_DISPLAY=wayland-0 XDG_SESSION_TYPE=wayland "

# Runs in the guest on pw-dump's output and prints one line per camera object:
#   device API PRODUCT-NAME-AS-JSON DEVICE-NAME
#   node API STATE NODE-NAME
# A node's API is its own (device.api, api.libcamera.*, api.v4l2.*) or else
# its device's.
PW_CAMERAS = r'''
import json, sys
objs = json.load(open(sys.argv[1]))
def props(o):
    return (o.get("info") or {}).get("props") or {}
def api_of(p):
    if p.get("device.api"):
        return p["device.api"]
    for prefix, api in (("api.libcamera.", "libcamera"), ("api.v4l2.", "v4l2")):
        if any(k.startswith(prefix) for k in p):
            return api
    return None
devices = {}
for o in objs:
    p = props(o)
    if o.get("type", "").endswith(":Device") and p.get("media.class") == "Video/Device":
        devices[o.get("id")] = api_of(p) or "?"
        print("device", devices[o.get("id")], json.dumps(p.get("device.product.name")), p.get("device.name"))
for o in objs:
    p = props(o)
    if o.get("type", "").endswith(":Node") and str(p.get("media.class", "")).startswith("Video/Source"):
        api = api_of(p) or devices.get(p.get("device.id")) or "?"
        print("node", api, (o.get("info") or {}).get("state"), p.get("node.name"))
'''

# Records every call of the Access dialog (the camera portal's prompt) on the
# session bus, one JSON object per line.
ACCESS_MONITOR = """#!/bin/sh
exec timeout 900 stdbuf -oL busctl --user --json=short monitor \\
    --match "type='method_call',interface='org.freedesktop.impl.portal.Access',member='AccessDialog'"
"""

# vimc's sensors draw the 75% colour bars by default. A pixel counts as one
# of the bars' hues by which channels are high (>= 120) and low (<= 80).
BAR_HUES = {("h", "h", "l"): "yellow", ("l", "h", "h"): "cyan", ("l", "h", "l"): "green",
            ("h", "l", "h"): "magenta", ("h", "l", "l"): "red", ("l", "l", "h"): "blue"}


def colour_bars(vm):
    """{hue: share of the display} for the colour-bar hues on the display."""
    w, h, px = vm.pixels()
    counts = dict.fromkeys(BAR_HUES.values(), 0)
    n = 0
    for y in range(0, h, 4):
        row = y * w * 3
        for x in range(0, w, 4):
            i = row + x * 3
            key = tuple("h" if v >= 120 else "l" if v <= 80 else "m" for v in px[i:i + 3])
            n += 1
            if key in BAR_HUES:
                counts[BAR_HUES[key]] += 1
    return {k: v / max(n, 1) for k, v in counts.items()}


def put_file(sh, path, data):
    """Write DATA (bytes) to PATH in the guest in console-sized base64 pieces;
    True only if every step worked and the copy has the right SHA-256."""
    b64 = base64.b64encode(data).decode()
    rc, _ = sh(f"rm -f {path} {path}.b64 && : > {path}.b64")
    if rc != 0:
        return False
    for i in range(0, len(b64), 1500):
        rc, _ = sh(f"printf %s '{b64[i:i + 1500]}' >> {path}.b64")
        if rc != 0:
            return False
    rc, o = sh(f"base64 -d {path}.b64 > {path} && rm -f {path}.b64 && chmod 0644 {path} && sha256sum {path}")
    return rc == 0 and o.split()[:1] == [hashlib.sha256(data).hexdigest()]


def pw_cameras(sh):
    """[(kind, api, state-or-product, name)] from pw-dump run as amnesia, or
    None if pw-dump or the parser failed or printed anything unexpected."""
    rc, o = sh(AS_AMNESIA + "timeout 20 pw-dump > /tmp/antumbra-pw.json && "
               "python3 /tmp/antumbra-pw-cameras.py /tmp/antumbra-pw.json", timeout=90)
    if rc != 0:
        return None
    rows = []
    for line in o.split("\n"):
        f = line.split(" ", 3)
        if len(f) == 4 and f[0] in ("device", "node"):
            rows.append(tuple(f))
        elif line.strip():
            return None
    return rows


def camera_phase(vm, rep, T, sh, out):
    """The camera path on vimc. Without a session: the driver, udev's names
    for its nodes, libcamera's camera list, the packages, no OnePlus camera
    software in the image. In the amnesia session (--through-welcome):
    PipeWire's libcamera node and no raw V4L2 camera, the camera portal's
    prompt, Snapshot streaming once access is granted (the preview shows
    vimc's colour bars), a picture saved, the stream stopped when Snapshot
    quits and when it is killed."""
    def shot(name):
        try:
            vm.screenshot(os.path.join(out, name))
            print(f"camera: screenshot {name}", flush=True)
        except Exception as e:  # noqa: BLE001
            print(f"camera: screenshot {name} failed: {e}", flush=True)

    def flat(o, n=300):
        return o.strip().replace("\n", " | ")[:n]

    def key(qcode):
        """Press and release a key on the virtio keyboard; False if QMP failed."""
        try:
            for down in (True, False):
                vm.qmp("input-send-event", events=[{"type": "key", "data": {"down": down, "key": {"type": "qcode", "data": qcode}}}])
                time.sleep(0.1)
            return True
        except Exception as e:  # noqa: BLE001
            print(f"camera: key {qcode} failed: {e}", flush=True)
            return False

    # 1. The kernel: vimc is loaded (hook 72, VM debug builds only) and has
    #    registered its capture nodes.
    rc, o = sh("cat /sys/module/vimc/initstate; ls /sys/bus/platform/devices/vimc.0/video4linux | grep -c '^video'")
    lines = o.strip().split("\n")
    rep.check("camera: the vimc virtual camera is loaded and has video nodes (modules-load.d, VM debug build)",
              rc == 0 and len(lines) == 2 and lines[0] == "live" and lines[1].isdigit() and int(lines[1]) > 0, flat(o))
    # 2. udev's name for those nodes: v4l_id's ID_V4L_PRODUCT (the card name)
    #    is what PipeWire's udev monitor reports as device.product.name, the
    #    key the WirePlumber rules match (CAMSS's card on the phone, vimc's here).
    rc, o = sh("for d in /sys/bus/platform/devices/vimc.0/video4linux/video*; do "
               "udevadm info -q property -n \"/dev/${d##*/}\" | grep '^ID_V4L_PRODUCT='; done")
    products = o.strip().split("\n") if rc == 0 and o.strip() else []
    rep.check("camera: udev names vimc's video nodes by card name (ID_V4L_PRODUCT=vimc)",
              bool(products) and all(p == "ID_V4L_PRODUCT=vimc" for p in products), flat(o))
    # 3. libcamera's own list (cam, from libcamera-tools: VM debug builds only).
    rc, o = sh("LIBCAMERA_LOG_LEVELS='*:ERROR' timeout 60 cam -l 2>&1", timeout=120)
    listed = (rc == 0 and re.search(r"^Available cameras:$", o, re.M) is not None
              and re.search(r"^\d+: .*\bvimc\b", o, re.M) is not None)
    rep.check("camera: libcamera lists the vimc camera (cam -l)", listed, flat(o))
    # 4. The packages: Snapshot; libcamera 0.7 and its IPA modules from the
    #    same build (the modules are signed with that build's key); PipeWire's
    #    libcamera plugin at the version of the rest of PipeWire; no Megapixels.
    want = ["gnome-snapshot", "libcamera0.7", "libcamera-ipa", "libspa-0.2-libcamera",
            "libspa-0.2-modules", "pipewire", "wireplumber"]
    rc, o = sh("dpkg-query -W -f '${Package} ${Version} ${db:Status-Abbrev}\\n' " + " ".join(want))
    pk = {}
    for line in o.split("\n"):
        f = line.split()
        if len(f) == 3 and f[2] == "ii":
            pk[f[0]] = f[1]
    rc2, o2 = sh("if dpkg-query -W -f '${db:Status-Abbrev}' megapixels 2>/dev/null | grep -q '^ii'; "
                 "then echo installed; else echo absent; fi")
    ok = (rc == 0 and set(pk) == set(want) and rc2 == 0 and o2.strip() == "absent"
          and pk["libcamera0.7"].startswith("0.7.") and pk["libcamera-ipa"] == pk["libcamera0.7"]
          and pk["libspa-0.2-libcamera"] == pk["libspa-0.2-modules"] == pk["pipewire"])
    rep.check("camera: Snapshot, libcamera 0.7 with its IPA modules from one build, PipeWire's libcamera plugin "
              "at PipeWire's version; no Megapixels",
              ok, ", ".join(f"{k} {v}" for k, v in sorted(pk.items())) + f"; megapixels {o2.strip() or '?'}")
    # 5. No OnePlus camera software anywhere in the image (the same scanner
    #    tests/lint.sh runs over the source tree).
    name = "camera: no OnePlus/OxygenOS camera app or Qualcomm camera HAL file in the image"
    scanner = open(os.path.join(ROOT, "tests", "no-oneplus-camera.py"), "rb").read()
    if put_file(sh, "/tmp/antumbra-no-oneplus-camera.py", scanner):
        rc, o = sh("python3 /tmp/antumbra-no-oneplus-camera.py --xdev /", timeout=900)
        rep.check(name, rc == 0 and not o.strip(), flat(o) or "none found")
    else:
        rep.check(name, False, "could not copy the scanner to the guest")

    # --- In the amnesia session ------------------------------------------------
    rc, o = sh("pgrep -u amnesia -xc phosh", timeout=30)
    if not (rc == 0 and o.strip().isdigit() and int(o.strip()) > 0):
        rep.check("camera: an amnesia session runs (the PipeWire and Snapshot checks need --through-welcome)", False, o.strip())
        return
    if not (put_file(sh, "/tmp/antumbra-pw-cameras.py", PW_CAMERAS.encode())
            and put_file(sh, "/tmp/antumbra-access-monitor.sh", ACCESS_MONITOR.encode())):
        rep.check("camera: helper scripts copied to the guest", False, "")
        return

    # 6. PipeWire offers vimc through libcamera only: the WirePlumber rule
    #    removed the V4L2 devices (WirePlumber's own deduplication would only
    #    drop the V4L2 nodes libcamera uses, never the devices).
    cams = None
    deadline = time.monotonic() + T(120)
    while time.monotonic() < deadline:
        cams = pw_cameras(sh)
        if cams and any(c[0] == "node" and c[1] == "libcamera" for c in cams):
            break
        time.sleep(5)
    listing = "; ".join(" ".join(c) for c in cams or []) or ("no camera objects" if cams is not None else "pw-dump failed")
    rep.check("camera: PipeWire (as amnesia) offers the vimc camera as a libcamera node",
              any(c[0] == "node" and c[1] == "libcamera" for c in cams or []), listing)
    rep.check("camera: no V4L2 camera device or node in PipeWire (the WirePlumber rule matched device.product.name)",
              cams is not None and not [c for c in cams if c[1] == "v4l2"], listing)
    rc, o = sh("journalctl -b -o cat --no-pager _COMM=wireplumber | grep -E 'V4L2 device .* disabled' | head -n 5", timeout=60)
    print(f"camera: WirePlumber's own log of disabled V4L2 devices: {flat(o) or 'none logged'}", flush=True)

    def states():
        rows = pw_cameras(sh)
        return None if rows is None else [c[2] for c in rows if c[0] == "node" and c[1] == "libcamera"]

    def wait_states(pred, secs):
        st = None
        deadline = time.monotonic() + T(secs)
        while True:
            st = states()
            if st is not None and pred(st):
                return True, st
            if time.monotonic() >= deadline:
                return False, st
            time.sleep(5)

    def snapshots():
        rc, o = sh("pgrep -u amnesia -xc snapshot", timeout=30)
        return int(o.strip()) if rc in (0, 1) and o.strip().isdigit() else None

    def start_snapshot():
        rc, o = sh(AS_AMNESIA_GUI + "setsid -f snapshot >/dev/null 2>&1; echo started", timeout=60)
        return rc == 0 and o.strip() == "started"

    def portal_decision():
        """The stored camera decision for host programs (app id ""), or None."""
        rc, o = sh(AS_AMNESIA + "busctl --user --json=short call org.freedesktop.impl.portal.PermissionStore "
                   "/org/freedesktop/impl/portal/PermissionStore org.freedesktop.impl.portal.PermissionStore "
                   "Lookup ss devices camera 2>&1", timeout=60)
        if rc != 0:
            return None, flat(o)
        try:
            perms = json.loads(o.strip().split("\n")[-1])["data"][0]
            return perms.get("", [None])[0], json.dumps(perms)
        except (ValueError, KeyError, IndexError, TypeError, AttributeError):
            return None, flat(o)

    def bars(label):
        try:
            b = colour_bars(vm)
        except Exception as e:  # noqa: BLE001
            return 0, f"{label}: {e}"
        seen = sorted(k for k, v in b.items() if v >= 0.005)
        return len(seen), f"{label}: " + ", ".join(f"{k} {v:.1%}" for k, v in sorted(b.items()))

    # 7. First start in a fresh session: no decision is stored, so the camera
    #    portal asks through Phosh's Access dialog and Snapshot gets no stream.
    before, before_detail = portal_decision()
    sh("pkill -u amnesia -x busctl; rm -f /tmp/antumbra-access.log", timeout=30)
    rc, o = sh(AS_AMNESIA + "setsid -f sh -c 'sh /tmp/antumbra-access-monitor.sh > /tmp/antumbra-access.log 2>&1'; echo started", timeout=60)
    monitoring = rc == 0 and o.strip() == "started"
    time.sleep(T(5))
    sh("rm -rf /home/amnesia/Pictures/Camera", timeout=30)
    started = start_snapshot()
    asked = []
    deadline = time.monotonic() + T(180)
    while monitoring and time.monotonic() < deadline:
        rc, o = sh("cat /tmp/antumbra-access.log", timeout=60)
        asked = []
        for line in o.split("\n") if rc == 0 else []:
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if isinstance(m, dict) and m.get("member") == "AccessDialog":
                asked.append(m)
        if asked:
            break
        time.sleep(5)
    n = snapshots()
    rep.check("camera: Snapshot starts", started and n is not None and n > 0, f"{n} snapshot processes")
    time.sleep(T(10))
    shot("camera-portal-prompt.png")
    dest = asked[0].get("destination", "") if asked else ""
    comm = ""
    if re.fullmatch(r":\d+\.\d+", dest or ""):
        rc, o = sh(AS_AMNESIA + f"busctl --user status {dest} 2>/dev/null | sed -n 's/^Comm=//p'", timeout=60)
        comm = o.strip() if rc == 0 else ""
    try:
        title = asked[0]["payload"]["data"][3] if asked else ""
    except (KeyError, IndexError, TypeError):
        title = "?"
    rep.check("camera: with no stored decision the camera portal asks, through Phosh's Access dialog",
              before is None and bool(asked) and comm == "phosh",
              f"stored before: {before_detail}; dialog: {title!r} handled by {comm or dest or 'nobody'}")
    ok, st = wait_states(lambda s: bool(s), 30)
    rep.check("camera: while the portal waits for an answer, Snapshot gets no stream", ok and "running" not in st,
              ", ".join(st or []) or "no libcamera node")
    first_bars, first_detail = bars("before streaming")

    # 8. Answer for the user: stop Snapshot (which withdraws the request),
    #    dismiss what is left of the dialog, then store the decision the
    #    "Allow" button stores, and check it is in place before the restart.
    sh("pkill -u amnesia -x snapshot; sleep 5; pkill -9 -u amnesia -x snapshot; true", timeout=60)
    key("esc")
    time.sleep(T(30))
    sh(AS_AMNESIA + "busctl --user call org.freedesktop.impl.portal.PermissionStore /org/freedesktop/impl/portal/PermissionStore "
       "org.freedesktop.impl.portal.PermissionStore SetPermission sbssas devices true camera '' 1 yes", timeout=60)
    decision, decision_detail = portal_decision()
    rep.check("camera: the camera decision for host programs is stored as yes", decision == "yes", decision_detail)
    shot("camera-after-prompt.png")

    # 9. Second start: the portal grants access without asking, Snapshot
    #    streams, and the preview shows vimc's colour bars.
    start_snapshot()
    ok, st = wait_states(lambda s: "running" in s, 180)
    rep.check("camera: with access granted, Snapshot streams from vimc through PipeWire's libcamera node", ok,
              ", ".join(st or []) or "no libcamera node")
    time.sleep(T(15))
    shot("camera-preview.png")
    hues, detail = bars("preview")
    rep.check("camera: the preview shows vimc's colour bars", hues >= 4, f"{detail}; {first_detail}")

    # 10. A picture: Snapshot's shortcut "t" (its window action is not
    #     exported on D-Bus), saved under the user's Pictures directory.
    rc, o = sh(AS_AMNESIA + "xdg-user-dir PICTURES", timeout=30)
    pictures = o.strip() if rc == 0 else ""
    if not pictures.startswith("/home/amnesia/") or "\n" in pictures:
        rep.check("camera: the session has an XDG Pictures directory (Snapshot saves there)", False, o.strip())
    else:
        pressed = key("t")
        saved = ""
        deadline = time.monotonic() + T(90)
        while time.monotonic() < deadline:
            rc, o = sh(f"for f in '{pictures}'/Camera/*.jpeg '{pictures}'/Camera/*.jpg; do [ -s \"$f\" ] || continue; "
                       "printf '%s %s\\n' \"$(head -c 3 \"$f\" | od -An -tx1 | tr -d ' ')\" \"$f\"; done", timeout=60)
            if rc == 0 and re.search(r"^ffd8ff /.+\.jpe?g$", o, re.M):
                saved = o.strip()
                break
            time.sleep(5)
        rep.check("camera: Snapshot saves a JPEG picture to ~/Pictures/Camera", bool(saved),
                  saved or ("nothing saved" if pressed else "could not press t"))

    # 11. The stream stops when Snapshot quits (its quit action), and when it
    #     is killed: on the phone that is what retracts the pop-up camera.
    rc, o = sh(AS_AMNESIA + "busctl --user call org.gnome.Snapshot /org/gnome/Snapshot org.gtk.Actions "
               "Activate 'sava{sv}' quit 0 0 2>&1", timeout=60)
    how = "quit action" if rc == 0 else f"quit action failed ({flat(o, 120)}), SIGTERM"
    if rc != 0:
        sh("pkill -u amnesia -x snapshot; true", timeout=30)
    ok, st = wait_states(lambda s: bool(s) and "running" not in s, 60)
    rep.check("camera: the stream stops when Snapshot quits", ok and snapshots() == 0,
              f"{how}; " + (", ".join(st or []) or "no libcamera node"))
    start_snapshot()
    ok, st = wait_states(lambda s: "running" in s, 180)
    if ok:
        sh("pkill -9 -u amnesia -x snapshot; true", timeout=30)
        ok, st = wait_states(lambda s: bool(s) and "running" not in s, 60)
    rep.check("camera: the stream stops when Snapshot is killed (SIGKILL)", ok and snapshots() == 0,
              ", ".join(st or []) or "no libcamera node")
    sh("pkill -u amnesia -x snapshot; pkill -u amnesia -x busctl; true", timeout=30)


# ---------------------------------------------------------------------------
# Android apps (images built with ANTUMBRA_ANDROID=1; docs/vm-testing.md)
# ---------------------------------------------------------------------------
ANDROID_MAC = "00:16:3e:f9:d3:03"     # Waydroid's container MAC (config_3), reserved by the bridge's DHCP
ANDROID_NET = "10.200.2."              # the bridge's /30: 10.200.2.1 host, 10.200.2.2 container
ANDROID_LXC = "lxc-attach -P /var/lib/waydroid/lxc -n waydroid --clear-env --"
AMNESIA_ENV = ("XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 "
               "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus XDG_SESSION_TYPE=wayland")
# Destinations the simulated container probes; none may ever appear on the wire.
ANDROID_PROBE_DESTS = {"203.0.113.5", "198.51.100.7", "8.8.8.8", "192.168.1.1"}
# Any syntactically valid v3 onion name: Tor's DNSPort maps it into
# 127.192.0.0/10 without network access (AutomapHostsOnResolve), which only
# Tor would answer.
ONION_NAME = "2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion"

# Run in the guest from the android-sim namespace, a stand-in for the Android
# container (standard library only). "run JSON" runs a list of probes and
# prints one JSON object; "hold HOST PORT SECONDS" keeps a TCP connection open.
ANDROID_PROBE_PY = r'''
import errno, json, random, socket, struct, sys, time


def tcp(host, port, timeout=6.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return "connected"
    except socket.timeout:
        return "timeout"
    except OSError as e:
        return {errno.EHOSTUNREACH: "unreachable", errno.ECONNREFUSED: "refused",
                errno.ENETUNREACH: "no-route"}.get(e.errno, "error-%s" % e.errno)
    finally:
        s.close()


def udp(host, port, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(b"antumbra-probe", (host, port))
        s.recvfrom(4096)
        return "reply"
    except socket.timeout:
        return "no-reply"
    except OSError as e:
        return "error-%s" % e.errno
    finally:
        s.close()


def dns(server, name, timeout=6.0):
    qid = random.randint(0, 65535)
    query = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    query += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0" + struct.pack("!HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(query, (server, 53))
        r = s.recvfrom(2048)[0]
    except socket.timeout:
        return "no-reply"
    except OSError as e:
        return "error-%s" % e.errno
    finally:
        s.close()
    try:
        if struct.unpack("!H", r[:2])[0] != qid:
            return "wrong-id"
        rcode, answers = r[3] & 15, struct.unpack("!H", r[6:8])[0]
        p = 12
        while r[p]:
            p += r[p] + 1
        p += 5
        addrs = []
        for _ in range(answers):
            if r[p] & 0xC0 == 0xC0:
                p += 2
            else:
                while r[p]:
                    p += r[p] + 1
                p += 1
            rtype, _, _, rdlen = struct.unpack("!HHIH", r[p:p + 10])
            p += 10
            if rtype == 1 and rdlen == 4:
                addrs.append(socket.inet_ntoa(r[p:p + 4]))
            p += rdlen
        return "rcode=%d a=%s" % (rcode, ",".join(addrs) or "-")
    except (IndexError, struct.error):
        return "unparsable"


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    s = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return ~s & 0xFFFF


def raw_tcp(src, dst, dport, flags):
    """One TCP segment with the given flags and no handshake before it."""
    seg = struct.pack("!HHIIBBHHH", 40000 + flags, dport, 12345, 0, 5 << 4, flags, 65535, 0, 0)
    pseudo = struct.pack("!4s4sBBH", socket.inet_aton(src), socket.inet_aton(dst), 0, 6, len(seg))
    seg = seg[:16] + struct.pack("!H", checksum(pseudo + seg)) + seg[18:]
    s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_TCP)
    try:
        s.sendto(seg, (dst, 0))
        return "sent"
    except OSError as e:
        return "error-%s" % e.errno
    finally:
        s.close()


if sys.argv[1] == "hold":
    c = socket.create_connection((sys.argv[2], int(sys.argv[3])), timeout=10)
    time.sleep(float(sys.argv[4]))
    c.close()
    sys.exit(0)
results = {}
for kind, *args in json.loads(sys.argv[2]):
    key = " ".join([kind] + [str(a) for a in args])
    results[key] = {"tcp": tcp, "udp": udp, "dns": dns, "raw": raw_tcp}[kind](*args)
print("PROBES " + json.dumps(results, sort_keys=True))
'''

# udhcpc's event script in the simulated container: apply the lease, print it.
ANDROID_UDHCPC_SH = r'''#!/bin/sh
case "$1" in
    bound|renew)
        ip addr flush dev "$interface"
        ip addr add "$ip/${mask:-30}" dev "$interface"
        [ -z "${router:-}" ] || ip route replace default via "$router" dev "$interface"
        echo "LEASE ip=$ip subnet=${subnet:-} router=${router:-} dns=${dns:-} ntpsrv=${ntpsrv:-}" ;;
esac
'''


def android_probe_list(uplink):
    """What the stand-in container tries: the Internet over TCP (Tor's), the
    LAN, the host's own address and services, Tor's control, SOCKS and
    listener ports addressed directly, DNS over TLS, DNS to the DHCP server
    and to a hard-coded one, NTP, QUIC, and TCP segments without a handshake."""
    raw = [["raw", "10.200.2.2", "203.0.113.5", 80, flags] for flags in (0x04, 0x01, 0x10, 0x11)]
    return [["tcp", "198.51.100.7", 80], ["tcp", "198.51.100.7", 443],
            ["tcp", "10.0.2.2", 80], ["tcp", "192.168.1.1", 80], ["tcp", uplink, 22],
            ["tcp", "10.200.2.1", 9052], ["tcp", "10.200.2.1", 951], ["tcp", "10.200.2.1", 9041],
            ["tcp", "10.200.1.1", 9050], ["tcp", "198.51.100.7", 853],
            ["dns", "10.200.2.1", ONION_NAME], ["dns", "8.8.8.8", ONION_NAME],
            ["udp", "203.0.113.5", 123], ["udp", "203.0.113.5", 443], ["udp", "10.200.2.1", 5354]] + raw


def judge_android_probes(res, uplink):
    """[(check name, ok, detail)] for the results of android_probe_list."""
    def got(*keys):
        return [res.get(" ".join(str(k) for k in key)) for key in keys]
    tor = got(("tcp", "198.51.100.7", 80), ("tcp", "198.51.100.7", 443))
    # The bridge does not forward (forwarding=0), so the routing code drops
    # what is addressed past the host before the firewall's forward chain sees
    # it: the LAN gets nothing, and the connection times out.
    lan = got(("tcp", "10.0.2.2", 80), ("tcp", "192.168.1.1", 80))
    refused = got(("tcp", uplink, 22), ("tcp", "10.200.2.1", 9052), ("tcp", "10.200.2.1", 951), ("tcp", "10.200.2.1", 9041),
                  ("tcp", "10.200.1.1", 9050), ("tcp", "198.51.100.7", 853))
    answers = got(("dns", "10.200.2.1", ONION_NAME), ("dns", "8.8.8.8", ONION_NAME))
    automap = r"rcode=0 a=127\.(19[2-9]|2[0-4]\d|25[0-5])\.\d+\.\d+"
    silent = got(("udp", "203.0.113.5", 123), ("udp", "203.0.113.5", 443), ("udp", "10.200.2.1", 5354))
    return [
        ("android-net: TCP to the Internet is accepted by Tor's TransPort", tor == ["connected", "connected"], str(tor)),
        ("android-net: TCP to the local network gets nowhere", all(r in ("timeout", "unreachable") for r in lan), str(lan)),
        ("android-net: the host's own address and services, Tor's control, SOCKS and listener ports and DNS over TLS are refused at once",
         refused == ["unreachable"] * 6, str(refused)),
        ("android-net: DNS to any server is answered by Tor (.onion mapped into 127.192.0.0/10)",
         all(isinstance(a, str) and re.fullmatch(automap, a) for a in answers), str(answers)),
        ("android-net: no answer to NTP, QUIC or the DNSPort addressed directly", silent == ["no-reply"] * 3, str(silent)),
    ]


def guest_write(sh, path, text, mode="0755"):
    """Write TEXT to PATH in the guest through the console (base64 in short
    lines, so no character of TEXT can confuse the shell or the tty)."""
    import base64
    b64 = base64.b64encode(text.encode()).decode()
    body = "\n".join(b64[i:i + 76] for i in range(0, len(b64), 76))
    rc, o = sh(f"base64 -d > {path} <<'ANTUMBRA_EOF'\n{body}\nANTUMBRA_EOF\nchmod {mode} {path} && echo written", timeout=120)
    return rc == 0 and o.strip().endswith("written")


def android_counters(sh):
    """(DNS, TCP) packet counters of the firewall's Android redirects, or None."""
    rc, o = sh("nft list chain ip antumbra-nat android")
    if rc != 0:
        return None
    dns_m = re.search(r"udp dport 53 counter packets (\d+)", o)
    tcp_m = re.search(r"meta l4proto tcp counter packets (\d+)", o)
    if not dns_m or not tcp_m:
        return None
    return int(dns_m.group(1)), int(tcp_m.group(1))


def save_text(out, name, text):
    try:
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            f.write(text)
    except OSError:
        pass


def android_preflight(vm, rep, T, sh, out):
    """Before the Welcome screen: the image carries Android apps, and they are
    off, closed and inert until the user turns them on."""
    rc, o = sh("grep -cx 'ANTUMBRA_ANDROID=1' /etc/antumbra-release; test -d /usr/share/antumbra/android && echo dir")
    rep.check("android: image built with Android apps (ANTUMBRA_ANDROID=1)", rc == 0 and o.strip().split("\n") == ["1", "dir"], o.replace("\n", " "))
    rc, o = sh("for n in /dev/binder /dev/hwbinder /dev/vndbinder; do stat -c '%n %a %U' $n; done; "
               "for u in waydroid-container antumbra-waydroid antumbra-waydroid-dhcp; do echo $u=$(systemctl is-active $u.service); done; "
               "test -e /run/antumbra/android-enabled && echo flag=yes || echo flag=no; "
               "systemctl is-enabled waydroid-container.service 2>&1 | sed 's/^/boot=/'")
    lines = o.strip().split("\n") if rc == 0 else []
    nodes = [l for l in lines if l.startswith("/dev/")]
    ok = (len(nodes) == 3 and all(l.endswith(" 600 root") for l in nodes)
          and all(f"{u}=inactive" in lines for u in ("waydroid-container", "antumbra-waydroid", "antumbra-waydroid-dhcp"))
          and "flag=no" in lines and "boot=disabled" in lines)
    rep.check("android: off before the Welcome screen (binder devices root-only, no container, no DHCP, not started at boot)", ok, o.replace("\n", " | "))
    rc, o = sh("systemctl is-enabled lxc-net.service lxc.service lxc-monitord.service 2>&1; ip link show lxcbr0 >/dev/null 2>&1 && echo lxcbr0 || echo no-lxcbr0; "
               "grep -c '^USE_LXC_BRIDGE=\"false\"' /etc/default/lxc-net")
    rep.check("android: lxc's own services masked, no lxcbr0", rc == 0 and o.strip().split("\n") == ["masked", "masked", "masked", "no-lxcbr0", "1"], o.replace("\n", " "))
    C = "/usr/lib/waydroid/data/configs"
    rc, o = sh(f"grep -c '^lxc.net.0.link = waydroid-tor$' {C}/config_3; grep -c '^lxc.network.link = waydroid-tor$' {C}/config_1; "
               f"cat {C}/config_1 {C}/config_3 | grep -c waydroid0; "
               f"grep '^lxc.cap.keep' {C}/config_base | grep -cw sys_time; "
               f"grep -c '^lxc.hook.start-host = /usr/local/lib/antumbra-waydroid-start-host$' {C}/config_3; "
               f"grep -c '^lxc.cgroup2.devices.deny = c 81:\\* rwm$' {C}/config_3; "
               f"grep -c '^lxc.mount.entry = tmpfs sys/firmware tmpfs ' {C}/config_3; "
               "cat /usr/lib/waydroid/tools/actions/container_manager.py /usr/lib/waydroid/tools/helpers/lxc.py | grep -c 'glob(\"/dev/video'")
    rep.check("android: Waydroid's templates use waydroid-tor, keep no sys_time, run the start-host hook, deny V4L2, hide /sys/firmware, pass no video device",
              rc == 0 and o.strip().split("\n") == ["1", "1", "0", "0", "1", "1", "1", "0"], o.replace("\n", " "))
    rc, o = sh("stat -c '%n %s' /usr/share/waydroid-extra/images/system.img /usr/share/waydroid-extra/images/vendor.img /usr/share/antumbra/android/F-Droid.apk; "
               "stat -c '%a' /usr/bin/pkexec; grep -c '^TransPort 10.200.2.1:9041 ' /etc/tor/torrc; grep -c '^android|' /etc/antumbra/persistence-features.conf")
    lines = o.strip().split("\n") if rc == 0 else []
    ok = (len(lines) == 6 and all(int(l.split()[1]) > 1000000 for l in lines[:3])
          and lines[3] == "755" and lines[4] == "1" and lines[5] == "1")
    rep.check("android: images and F-Droid in the read-only system, pkexec not setuid, Tor's Android listeners and the persistence feature configured", ok, o.replace("\n", " | "))
    # D-Bus activation (what any Waydroid client does) must not start the
    # container service while Android is off.
    rc, o = sh("runuser -u amnesia -- timeout 90 busctl --system call id.waydro.Container /ContainerManager id.waydro.ContainerManager GetSession "
               ">/dev/null 2>&1 && echo answered || echo refused; sleep 2; systemctl is-active waydroid-container.service", timeout=180)
    rep.check("android: D-Bus activation of the container service is refused while Android is off", rc is not None and o.strip().split("\n") == ["refused", "inactive"], o.replace("\n", " "))
    android_templates_check(rep, sh)
    android_boot_modes(rep, sh, out)


def enable_android_switch(vm, rep, T, out):
    """Turn on "Android apps" on the Welcome screen. Its title carries the
    mnemonic Alt+A, which works wherever the row is scrolled to; the page is
    then scrolled down so the screenshot shows the switch."""
    try:
        vm.qmp("send-key", keys=[{"type": "qcode", "data": "alt"}, {"type": "qcode", "data": "a"}])
        time.sleep(T(3))
        vm.qmp("input-send-event", events=vm._abs(360, 700))
        for _ in range(15):
            vm.qmp("input-send-event", events=[{"type": "btn", "data": {"down": True, "button": "wheel-down"}}])
            vm.qmp("input-send-event", events=[{"type": "btn", "data": {"down": False, "button": "wheel-down"}}])
            time.sleep(0.2)
        time.sleep(T(5))
        vm.screenshot(os.path.join(out, "welcome-android.png"))
        print(f"welcome: Alt+A sent, page scrolled -> {out}/welcome-android.png", flush=True)
    except Exception as e:  # noqa: BLE001
        rep.check("welcome: Alt+A sent to switch on Android apps", False, str(e)[:300])


def android_phase(vm, rep, T, sh, out):
    """After the Welcome screen with Android apps on: Waydroid prepared offline,
    the container boots on its Tor-only network with a generic identity,
    F-Droid arrives, all of Android's traffic ends at Tor, and the start-host
    hook refuses to start the container once the firewall is incomplete."""
    rc, o = sh("test -e /run/antumbra/android-enabled && echo flag; grep -h '^ANTUMBRA_ANDROID_ENABLED=' /var/lib/antumbra/settings/applied/antumbra.android")
    enabled = rc == 0 and o.strip().split("\n") == ["flag", "ANTUMBRA_ANDROID_ENABLED=true"]
    rep.check("android: enabled for this session by the Welcome screen", enabled, o.replace("\n", " "))
    if not enabled:
        return
    ready = False
    deadline = time.monotonic() + T(900)
    while time.monotonic() < deadline:
        rc, o = sh("systemctl is-active antumbra-waydroid.service; test -e /run/antumbra/android-ready && echo ready", timeout=60)
        if rc is not None and "failed" in o:
            break
        if rc == 0 and o.strip().split("\n") == ["active", "ready"]:
            ready = True
            break
        time.sleep(5)
    rep.check("android: Waydroid prepared from the preinstalled images (antumbra-waydroid.service)", ready, o.replace("\n", " "))
    rc, o = sh("sed -n 's/^images_path = //p' /var/lib/waydroid/waydroid.cfg; sed -n 's/^mount_overlays = //p' /var/lib/waydroid/waydroid.cfg; "
               "grep -c '^waydroid.updater.disabled=true$' /var/lib/waydroid/waydroid_base.prop; "
               "grep -ciE 'downloading|ota\\.waydro\\.id' /var/lib/waydroid/waydroid.log")
    rep.check("android: waydroid init used the images in the system and did not try the network",
              rc is not None and o.strip().split("\n") == ["/usr/share/waydroid-extra/images", "False", "1", "0"], o.replace("\n", " "))
    L = "/var/lib/waydroid/lxc/waydroid"
    rc, o = sh(f"grep -c '^lxc.net.0.link = waydroid-tor$' {L}/config; grep -c '^lxc.hook.start-host = /usr/local/lib/antumbra-waydroid-start-host$' {L}/config; "
               f"grep -cw sys_time {L}/config; grep -c video {L}/config_nodes")
    rep.check("android: the generated container configuration keeps waydroid-tor, the hook and no sys_time or video device",
              rc is not None and o.strip().split("\n") == ["1", "1", "0", "0"], o.replace("\n", " "))
    rc, o = sh("/usr/lib/waydroid/data/scripts/waydroid-net.sh start; echo rc=$?; nft list tables | grep -c ' lxc$'; ip link show waydroid0 >/dev/null 2>&1 && echo waydroid0 || echo no-waydroid0")
    rep.check("android: upstream waydroid-net.sh bails out (no NAT, no ip_forward, no DNS server of its own)",
              rc == 0 and "bailing out" in o and o.strip().split("\n")[-3:] == ["rc=0", "0", "no-waydroid0"], o.replace("\n", " "))
    running = False
    deadline = time.monotonic() + T(900)
    while time.monotonic() < deadline:
        rc, o = sh("lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH", timeout=60)
        if rc == 0 and o.strip() == "RUNNING":
            running = True
            break
        time.sleep(10)
    rep.check("android: the container runs (started by the session's waydroid session)", running, o.strip())
    booted = False
    if running:
        deadline = time.monotonic() + T(2400)
        while time.monotonic() < deadline:
            rc, o = sh(f"{ANDROID_LXC} /system/bin/getprop sys.boot_completed", timeout=120)
            if rc == 0 and o.strip() == "1":
                booted = True
                break
            time.sleep(15)
    rep.check("android: Android 13 booted (sys.boot_completed=1)", booted, o.strip()[-200:])
    if not booted:
        rc, o = sh("tail -n 80 /var/lib/waydroid/waydroid.log; journalctl -b --no-pager -u antumbra-waydroid -u waydroid-container -u antumbra-waydroid-dhcp | tail -n 80", timeout=120)
        save_text(out, "android-boot-failure.txt", o)
        rc, o = sh(f"{ANDROID_LXC} /system/bin/logcat -d -t 400", timeout=180)
        save_text(out, "android-logcat.txt", o)
        return
    try:
        vm.screenshot(os.path.join(out, "android-session.png"))
    except Exception:  # noqa: BLE001
        pass
    rc, o = sh(f"cat /usr/share/antumbra/android/product.prop; echo ---; for p in brand manufacturer model device name; do echo ro.product.waydroid.$p=$({ANDROID_LXC} /system/bin/getprop ro.product.waydroid.$p); done; "
               f"echo model=$({ANDROID_LXC} /system/bin/getprop ro.product.model)", timeout=180)
    parts = o.split("---")
    want = sorted(l for l in parts[0].strip().split("\n") if l.startswith("ro.product.waydroid.")) if len(parts) == 2 else []
    got = sorted(l for l in parts[1].strip().split("\n") if l.startswith("ro.product.waydroid.")) if len(parts) == 2 else ["?"]
    rep.check("android: Android reports the generic Waydroid identity, not the device's", rc == 0 and len(want) == 5 and want == got and "OnePlus" not in o,
              o.replace("\n", " ")[-300:])
    rc, o = sh(f"{ANDROID_LXC} /system/bin/ls -A /sys/firmware | wc -l; {ANDROID_LXC} /system/bin/cat /proc/device-tree/model >/dev/null 2>&1 && echo model-readable || echo model-hidden")
    rep.check("android: /sys/firmware and /proc/device-tree are hidden from Android", rc == 0 and o.strip().split("\n") == ["0", "model-hidden"], o.replace("\n", " "))
    android_identifier_checks(rep, sh)
    rc, o = sh(f"{ANDROID_LXC} /system/bin/ip -4 -o addr show eth0; {ANDROID_LXC} /system/bin/ip route show table all | grep -c '^default via 10.200.2.1 '; cat /var/lib/misc/dnsmasq.waydroid0.leases")
    rep.check("android: the container got 10.200.2.2 from the bridge's DHCP, default route via 10.200.2.1",
              rc == 0 and " 10.200.2.2/30 " in o and ANDROID_MAC in o and re.search(r"^[1-9]\d*$", o, re.M) is not None, o.replace("\n", " | ")[:300])
    # antumbra-waydroid-provision.service waits for the boot, applies the
    # settings and exits; its main process must have exited with status 0.
    done = False
    deadline = time.monotonic() + T(600)
    while time.monotonic() < deadline:
        rc, o = sh("systemctl show -p ExecMainExitTimestampMonotonic -p ExecMainStatus antumbra-waydroid-provision.service", timeout=60)
        f = dict(line.split("=", 1) for line in o.split("\n") if "=" in line) if rc == 0 else {}
        if f.get("ExecMainExitTimestampMonotonic", "0") not in ("", "0"):
            done = f.get("ExecMainStatus") == "0"
            break
        time.sleep(10)
    rc, o = sh("for k in captive_portal_mode private_dns_mode auto_time auto_time_zone; do "
               "echo $k=$(waydroid shell -- settings get global $k | tr -d '\\r' | tail -n 1); done", timeout=240)
    rep.check("android: provisioned: no captive-portal probes, no Private DNS, no network time",
              done and rc == 0 and o.strip().split("\n") == ["captive_portal_mode=0", "private_dns_mode=off", "auto_time=0", "auto_time_zone=0"], o.replace("\n", " "))
    sh(f"runuser -u amnesia -- env {AMNESIA_ENV} setsid -f waydroid show-full-ui >/dev/null 2>&1; echo started", timeout=60)
    time.sleep(T(90))
    try:
        vm.screenshot(os.path.join(out, "android-full-ui.png"))
        colors = vm.distinct_colors()
        rep.check("android: full UI drawn (screenshot)", colors > 24, f"{colors} distinct colours -> {out}/android-full-ui.png")
    except Exception as e:  # noqa: BLE001
        rep.check("android: full UI drawn (screenshot)", False, str(e)[:300])
    fdroid = False
    deadline = time.monotonic() + T(1200)
    while time.monotonic() < deadline:
        rc, o = sh(f"runuser -u amnesia -- env {AMNESIA_ENV} timeout 300 waydroid app list 2>/dev/null | grep -cx 'packageName: org.fdroid.fdroid'", timeout=400)
        if rc == 0 and o.strip() == "1":
            fdroid = True
            break
        time.sleep(20)
    rep.check("android: F-Droid installed on first start (antumbra-fdroid-install)", fdroid, o.strip())
    rc, o = sh("test -e /home/amnesia/.local/share/applications/waydroid.org.fdroid.fdroid.desktop && echo desktop; "
               f"runuser -u amnesia -- env {AMNESIA_ENV} gsettings get org.gnome.desktop.app-folders folder-children; "
               f"runuser -u amnesia -- env {AMNESIA_ENV} gsettings get org.gnome.desktop.app-folders.folder:/org/gnome/desktop/app-folders/folders/Android/ apps", timeout=120)
    rep.check("android: Android apps listed in the app grid's Android folder",
              rc == 0 and o.startswith("desktop") and "'Android'" in o and "'waydroid.org.fdroid.fdroid.desktop'" in o and "'antumbra-android.desktop'" in o,
              o.replace("\n", " | ")[:300])
    if fdroid:
        before = android_counters(sh)
        sh(f"runuser -u amnesia -- env {AMNESIA_ENV} setsid -f waydroid app launch org.fdroid.fdroid >/dev/null 2>&1; echo started", timeout=60)
        time.sleep(T(120))
        try:
            vm.screenshot(os.path.join(out, "android-fdroid.png"))
        except Exception:  # noqa: BLE001
            pass
        after = android_counters(sh)
        rep.check("android: F-Droid's index fetch went to Tor's TransPort for Android (firewall counter)",
                  before is not None and after is not None and after[1] > before[1], f"TCP redirects {before and before[1]} -> {after and after[1]}")
    counters = android_counters(sh)
    rep.check("android: Android's DNS and TCP were redirected to Tor's ports for Android", counters is not None and counters[0] > 0 and counters[1] > 0,
              f"DNS {counters and counters[0]} packets, TCP {counters and counters[1]} connections")
    traffic_checks(vm, rep, T, sh, "with Android", int(T(60)))
    frames = [f for f in pcap_ipv4(os.path.join(vm.run, "net.pcap")) if not f[0].startswith(SLIRP_MAC_PREFIXES)]
    leaked = [f for f in frames if f[0] == ANDROID_MAC or f[1].startswith(ANDROID_NET)]
    rep.check("with Android, packet capture: no frame from the container's MAC address or network left the guest", not leaked,
              "; ".join(f"{f[1]}->{f[2]}:{f[4]}" for f in leaked[:6]) or f"{len(frames)} guest IPv4 frames checked")
    rc, o = sh("journalctl -b --no-pager -u antumbra-waydroid -u waydroid-container -u antumbra-waydroid-dhcp -u antumbra-waydroid-provision | tail -n 200", timeout=120)
    save_text(out, "android-journal.txt", o)
    # Fail closed: with the firewall's Android rules gone, the start-host
    # hook must stop LXC from starting the container.
    sh(f"runuser -u amnesia -- env {AMNESIA_ENV} timeout 120 waydroid session stop >/dev/null 2>&1; echo stopped", timeout=180)
    stopped = False
    deadline = time.monotonic() + T(180)
    while time.monotonic() < deadline:
        rc, o = sh("lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH", timeout=60)
        if rc == 0 and o.strip() == "STOPPED":
            stopped = True
            break
        time.sleep(5)
    android_stop_checks(rep, T, sh, out, stopped)
    rc, o = sh("nft flush chain ip antumbra-nat android && echo flushed; "
               f"runuser -u amnesia -- env {AMNESIA_ENV} timeout 300 waydroid session start >/dev/null 2>&1; "
               "lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH; journalctl -b --no-pager -t antumbra-waydroid | grep -c 'Android container start refused'; "
               "nft -f /etc/nftables.conf && echo restored", timeout=420)
    lines = o.strip().split("\n") if rc is not None else []
    rep.check("android: the start-host hook refuses to start the container without the firewall's Android rules",
              stopped and len(lines) == 4 and lines[0] == "flushed" and lines[1] == "STOPPED" and lines[2].isdigit() and int(lines[2]) > 0 and lines[3] == "restored",
              o.replace("\n", " "))
    # Start Android again, so that the power-off checks run with the
    # container's loop mounts in place (once the refused start's container
    # service has stopped).
    android_wait_service_stopped(T, sh)
    sh(f"runuser -u amnesia -- env {AMNESIA_ENV} systemctl --user restart antumbra-android-session.service; echo restarted", timeout=120)
    running = False
    deadline = time.monotonic() + T(600)
    while time.monotonic() < deadline:
        rc, o = sh("lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH; findmnt -rn -o SOURCE /var/lib/waydroid/rootfs | head -n1", timeout=60)
        if rc == 0 and o.strip().split("\n")[0] == "RUNNING":
            running = True
            break
        time.sleep(10)
    rep.check("android: the container starts again once the rules are back", running, o.replace("\n", " "))


def android_net_phase(vm, rep, T, sh, out):
    """Android's network without Android: a namespace on the waydroid-tor
    bridge with Waydroid's MAC address stands in for the container, takes
    its lease from the bridge's DHCP and probes everything it should not
    reach. Then the start-host hook and Tor's dependency on the bridge."""
    rc, o = sh("ip -4 -o addr show dev waydroid-tor | awk '{print $4}'; cat /proc/sys/net/ipv4/conf/waydroid-tor/forwarding /proc/sys/net/ipv4/conf/waydroid-tor/route_localnet; "
               "cat /proc/sys/net/ipv6/conf/waydroid-tor/disable_ipv6 2>/dev/null || echo 1; ip -6 -o addr show dev waydroid-tor | wc -l")
    rep.check("android-net: waydroid-tor at 10.200.2.1/30 with forwarding, route_localnet and IPv6 off",
              rc == 0 and o.strip().split("\n") == ["10.200.2.1/30", "0", "0", "1", "0"], o.replace("\n", " "))
    rc, o = sh("ss -Hltnu | awk '{print $1, $5}' | grep -E ' 10\\.200\\.2\\.1:(9041|5354)$' | sort")
    rep.check("android-net: Tor listens for Android on 10.200.2.1:9041 (TCP) and 10.200.2.1:5354 (UDP)",
              rc == 0 and o.strip().split("\n") == ["tcp 10.200.2.1:9041", "udp 10.200.2.1:5354"], o.replace("\n", " "))
    rc, o = sh("grep -E '^(firewall-android|android-bridge|lxc-net|binder|android-off) ' /run/antumbra/selfcheck.status | sort -u")
    rep.check("android-net: self-check reports the Android firewall rules, the bridge, lxc-net, binder and the container service OK",
              rc == 0 and o.strip().split("\n") == ["android-bridge OK", "android-off OK", "binder OK", "firewall-android OK", "lxc-net OK"], o.replace("\n", " | "))
    rc, o = sh("systemctl start antumbra-waydroid-dhcp.service; systemctl is-active antumbra-waydroid-dhcp.service")
    rep.check("android-net: the bridge's DHCP server does not start while Android apps are off", rc is not None and o.strip() == "inactive", o.strip())
    rc, o = sh("ip -4 -o addr show scope global | grep -vE ': (veth|waydroid-tor|lo)' | awk '{print $4}' | cut -d/ -f1 | head -n1")
    uplink = o.strip() if rc == 0 and re.fullmatch(r"\d+\.\d+\.\d+\.\d+", o.strip()) else "10.0.2.15"
    try:
        ok = guest_write(sh, "/run/antumbra-android-probe.py", ANDROID_PROBE_PY, "0644") and guest_write(sh, "/run/antumbra-udhcpc.sh", ANDROID_UDHCPC_SH)
        rc, o = sh("ip netns add android-sim && ip link add vethandsim type veth peer name eth0 netns android-sim && "
                   "ip link set vethandsim master waydroid-tor && ip link set vethandsim up && ip -n android-sim link set lo up && "
                   f"ip -n android-sim link set eth0 address {ANDROID_MAC} && ip -n android-sim link set eth0 up && "
                   "touch /run/antumbra/android-enabled && systemctl start antumbra-waydroid-dhcp.service && systemctl is-active antumbra-waydroid-dhcp.service")
        rep.check("android-net: a stand-in container on the bridge, the bridge's DHCP running", ok and rc == 0 and o.strip() == "active", o.replace("\n", " "))
        for flag, name in (("", "android-net: DHCP lease 10.200.2.2/30, router and DNS 10.200.2.1, no NTP server"),
                           ("-B", "android-net: DHCP lease with the broadcast flag (udhcpc -B)")):
            rc, o = sh(f"ip netns exec android-sim busybox udhcpc -f -q -n -t 5 -T 2 {flag} -i eth0 -s /run/antumbra-udhcpc.sh 2>&1 | grep '^LEASE '", timeout=120)
            rep.check(name, rc == 0 and o.strip() == "LEASE ip=10.200.2.2 subnet=255.255.255.252 router=10.200.2.1 dns=10.200.2.1 ntpsrv=", o.strip())
        before = android_counters(sh)
        rc, o = sh(f"ip netns exec android-sim python3 /run/antumbra-android-probe.py run '{json.dumps(android_probe_list(uplink))}'", timeout=300)
        m = re.search(r"^PROBES (\{.*\})$", o, re.M) if rc == 0 else None
        res = json.loads(m.group(1)) if m else {}
        save_text(out, "android-net-probes.json", json.dumps(res, indent=1, sort_keys=True))
        for name, ok, detail in judge_android_probes(res, uplink):
            rep.check(name, ok, detail)
        rc, o = sh("ip netns exec android-sim busybox ping -c 1 -W 2 203.0.113.5 >/dev/null 2>&1 && echo reply || echo none; "
                   "ip netns exec android-sim busybox ping -c 1 -W 2 10.200.2.1 >/dev/null 2>&1 && echo reply || echo none")
        rep.check("android-net: no answer to ping, from the Internet or the host", rc == 0 and o.strip().split("\n") == ["none", "none"], o.replace("\n", " "))
        # A connection held open: Tor owns its other end.
        rc, o = sh("ip netns exec android-sim python3 /run/antumbra-android-probe.py hold 198.51.100.7 80 8 & sleep 4; "
                   "ss -Htnp state established '( sport = :9041 )'; wait", timeout=120)
        rep.check("android-net: the held connection ends at Tor (10.200.2.2 -> 10.200.2.1:9041, process tor)",
                  rc == 0 and re.search(r"10\.200\.2\.1:9041\s+10\.200\.2\.2:\d+\s+users:\(\(\"tor\"", o) is not None, o.strip()[:300])
        after = android_counters(sh)
        rep.check("android-net: the firewall counted the DNS and TCP it redirected to Tor",
                  before is not None and after is not None and after[0] - before[0] >= 2 and after[1] - before[1] >= 4,
                  f"DNS {before and before[0]} -> {after and after[0]}, TCP {before and before[1]} -> {after and after[1]}")
        # IPv6 from the stand-in: router solicitations, all-nodes and global pings.
        # (Its own link-local address, fe80::216:3eff:fef9:d303, answers its
        # all-nodes ping through multicast loopback; nobody else may.)
        rc, o = sh("ip netns exec android-sim sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.eth0.disable_ipv6=0 2>/dev/null; sleep 4; "
                   "ip netns exec android-sim busybox ping -6 -c 2 -W 2 -I eth0 ff02::1 2>&1 | grep 'bytes from' | grep -vc 'fe80::216:3eff:fef9:d303'; "
                   "ip netns exec android-sim busybox ping -6 -c 1 -W 2 2001:db8::1 >/dev/null 2>&1 && echo reply || echo none; "
                   "ip -6 -o addr show dev waydroid-tor | wc -l", timeout=120)
        lines = o.strip().split("\n") if rc is not None else []
        rep.check("android-net: IPv6 from the container gets no answer from the host or beyond",
                  lines == ["0", "none", "0"], o.replace("\n", " "))
    finally:
        sh("ip netns del android-sim 2>/dev/null; ip link del vethandsim 2>/dev/null; systemctl stop antumbra-waydroid-dhcp.service; "
           "rm -f /run/antumbra/android-enabled /var/lib/misc/dnsmasq.waydroid0.leases; echo cleaned")
    # The start-host hook, run as LXC runs it, with the network in place and
    # with each piece of it missing.
    hook = "LXC_NAME=waydroid LXC_CONFIG_FILE=/run/antumbra-hooktest.conf /usr/local/lib/antumbra-waydroid-start-host waydroid lxc start-host >/dev/null 2>&1; echo $?"
    rc, o = sh("printf 'lxc.net.0.type = veth\\nlxc.net.0.link = waydroid-tor\\n' > /run/antumbra-hooktest.conf; "
               "sysctl -qw net.ipv4.conf.waydroid-tor.forwarding=1; "
               f"{hook}; cat /proc/sys/net/ipv4/conf/waydroid-tor/forwarding; "
               f"nft flush chain ip antumbra-nat android; {hook}; nft -f /etc/nftables.conf; "
               f"nft delete rule inet antumbra forward handle $(nft -a list chain inet antumbra forward | sed -n 's/.*iifname \"waydroid-tor\" jump android_reject # handle //p'); {hook}; nft -f /etc/nftables.conf; "
               f"sysctl -qw net.ipv4.conf.waydroid-tor.route_localnet=1; {hook}; sysctl -qw net.ipv4.conf.waydroid-tor.route_localnet=0; "
               f"sed -i 's/waydroid-tor/waydroid0/' /run/antumbra-hooktest.conf; {hook}; "
               "printf 'lxc.net.0.type = none\\n' > /run/antumbra-hooktest.conf; "
               f"{hook}; rm -f /run/antumbra-hooktest.conf; {hook}", timeout=120)
    rep.check("android-net: start-host hook passes with the network in place (and switches forwarding off), fails closed without each part of it",
              rc == 0 and o.strip().split("\n") == ["0", "0", "1", "1", "1", "1", "1", "1"], o.replace("\n", " "))
    rc, o = sh("nft list chain ip antumbra-nat android | grep -c 'redirect to :9041'; nft list chain inet antumbra forward | grep -c 'jump android_reject'")
    rep.check("android-net: the firewall is whole again after the hook tests", rc == 0 and o.strip().split("\n") == ["1", "2"], o.replace("\n", " "))
    # Tor binds its listeners for Android when it is told to connect, and must
    # refuse to connect when the bridge's address is missing; the bridge is
    # therefore created at boot.
    rc, o = sh("antumbra-tor-connect disconnect >/dev/null 2>&1; ip link del waydroid-tor; "
               "antumbra-tor-connect direct 2>&1 | tail -n 3; echo rc=$?", timeout=180)
    rep.check("android-net: without the bridge, Tor refuses to connect (it cannot bind its Android listeners)",
              rc == 0 and re.search(r"[Ff]ailed to bind|553", o) is not None, o.replace("\n", " ")[-300:])
    rc, o = sh("ip link add waydroid-tor type bridge && ip addr add 10.200.2.1/30 dev waydroid-tor && ip link set dev waydroid-tor up && "
               "sysctl -qw net.ipv4.conf.waydroid-tor.forwarding=0 net.ipv4.conf.waydroid-tor.route_localnet=0 && "
               "antumbra-tor-connect direct >/dev/null 2>&1 && echo connected; sleep 3; ss -Hltn | grep -c ' 10\\.200\\.2\\.1:9041 '", timeout=180)
    rep.check("android-net: with the bridge back, Tor connects and listens for Android again",
              rc == 0 and o.strip().split("\n") == ["connected", "1"], o.replace("\n", " "))
    frames = [f for f in pcap_ipv4(os.path.join(vm.run, "net.pcap")) if not f[0].startswith(SLIRP_MAC_PREFIXES)]
    leaked = [f for f in frames if f[0] == ANDROID_MAC or f[1].startswith(ANDROID_NET) or f[2] in ANDROID_PROBE_DESTS]
    rep.check("android-net, packet capture: nothing of the stand-in container left the guest (its MAC, its network, the probes' destinations)",
              not leaked, "; ".join(f"{f[0]} {f[1]}->{f[2]}:{f[4]}" for f in leaked[:6]) or f"{len(frames)} guest IPv4 frames checked")
    traffic_checks(vm, rep, T, sh, "android-net", int(T(20)))


# ---------------------------------------------------------------------------
# Android: identifiers, devices, stopping (images built with ANTUMBRA_ANDROID=1)
# ---------------------------------------------------------------------------
# --android boots the VM with a serial number on the kernel command line, as
# the phone's boot loader adds its own, and gives the disk one, as the
# phone's UFS has; neither may reach Android.
TEST_SERIAL = "ANTUMBRATEST"
TEST_DISK_SERIAL = "ANTUMBRATESTDISK"
SERIAL_FIND = ("find /sys/devices \\( -name serial_number -o -name serial -o -name vpd_pg80 -o -name vpd_pg83 "
               "-o -name wwid \\) -type f")
DEVICE_MODES = ("for n in /dev/binder /dev/hwbinder /dev/vndbinder /dev/dri/renderD* /dev/fb* /dev/dma_heap/*; do "
                "if [ -e \"$n\" ]; then stat -c '%n %a %U %G' \"$n\"; fi; done; echo end")


def with_vm_args(args, append, disk_serial):
    """vm.sh ARGS plus a kernel command-line argument and a disk serial number
    (merged into a --append given already)."""
    args = list(args)
    if "--append" in args and args.index("--append") + 1 < len(args):
        i = args.index("--append") + 1
        args[i] = f"{args[i]} {append}"
    else:
        args += ["--append", append]
    if "--disk-serial" not in args:
        args += ["--disk-serial", disk_serial]
    return args


def android_templates_check(rep, sh):
    """Before the Welcome screen: Waydroid's templates as hook 56 left them."""
    C = "/usr/lib/waydroid/data/configs"
    rc, o = sh(f"cat {C}/config_base {C}/config_3 {C}/config_4 | "
               "grep -E '^lxc\\.(cgroup2\\.devices\\.|hook\\.post-stop|mount\\.entry = /run/antumbra/android-cmdline )'; echo end")
    want = ["lxc.hook.post-stop = /usr/local/lib/antumbra-waydroid-post-stop", "lxc.hook.post-stop = /dev/null",
            "lxc.cgroup2.devices.allow = a", "lxc.cgroup2.devices.deny = c 81:* rwm",
            "lxc.mount.entry = /run/antumbra/android-cmdline proc/cmdline none bind,create=file 0 0", "end"]
    rep.check("android: the templates allow every device but cameras (allow a, then deny V4L2), bind a generic kernel "
              "command line and run Antumbra's post-stop hook before Waydroid's", rc == 0 and o.strip().split("\n") == want,
              o.replace("\n", " | "))


def android_boot_modes(rep, sh, out):
    """Before the Welcome screen: the modes of the devices Waydroid opens, to
    compare with once Android has stopped."""
    rc, o = sh(DEVICE_MODES)
    lines = o.strip().split("\n") if rc == 0 else []
    save_text(out, "android-device-modes-boot.txt", "\n".join(lines[:-1]) + "\n")
    rep.check("android: modes of binder, the render node, framebuffers and DMA-BUF heaps recorded before Android",
              rc == 0 and lines[-1:] == ["end"] and any(l.startswith("/dev/binder ") for l in lines), o.replace("\n", " | "))


def android_identifier_checks(rep, sh):
    """With Android booted: no hardware identifier reaches it, and it has
    every device but cameras."""
    inside = ("printf 'cmdline=[%s]\\nserialno=[%s]\\nbootserial=[%s]\\n' \"$(cat /proc/cmdline)\" "
              "\"$(getprop ro.serialno)\" \"$(getprop ro.boot.serialno)\"")
    rc, o = sh(f"tr ' ' '\\n' < /proc/cmdline | grep -cx 'androidboot.serialno={TEST_SERIAL}'; "
               "printf 'generic=[%s]\\n' \"$(cat /run/antumbra/android-cmdline)\"; "
               f"{ANDROID_LXC} /system/bin/sh -c {sh_quote(inside)}", timeout=180)
    f = dict(re.findall(r"^(\w+)=\[(.*)\]$", o, re.M)) if rc == 0 else {}
    rep.check("android: Android sees the generic kernel command line, not the host's with its serial number, and no serial property",
              rc == 0 and o.startswith("1\n") and "cmdline" in f and f.get("cmdline") == f.get("generic")
              and "serialno" in f and "bootserial" in f and TEST_SERIAL not in o,
              o.replace("\n", " | ")[:400])
    rc, o = sh(f"for f in $({SERIAL_FIND}); do printf '%s host=[%s] android=[%s]\\n' \"$f\" "
               "\"$(head -c 64 \"$f\" | tr -cd '[:alnum:]')\" "
               f"\"$({ANDROID_LXC} /system/bin/cat \"$f\" 2>&1 | head -c 64 | tr -cd '[:alnum:]')\"; done; echo end", timeout=300)
    lines = o.strip().split("\n") if rc == 0 else []
    files = [l for l in lines if " host=[" in l]
    rep.check("android: every hardware serial number file in sysfs reads empty in Android (the disk's serial included)",
              lines[-1:] == ["end"] and any(f"host=[{TEST_DISK_SERIAL}]" in l for l in files)
              and all(l.endswith(" android=[]") for l in files),
              f"{len(files)} files: " + " | ".join(files)[:400])
    inside = ("if cat /dev/null; then echo null=ok; fi; mknod /dev/antumbra-v4l-test c 81 0 2>&1; "
              "cat /dev/antumbra-v4l-test 2>&1; rm -f /dev/antumbra-v4l-test; echo end")
    rc, o = sh(f"{ANDROID_LXC} /system/bin/sh -c {sh_quote(inside)}", timeout=120)
    rep.check("android: the container opens /dev/null but no V4L2 device (the device cgroup's deny list)",
              rc == 0 and "null=ok" in o.split("\n") and "Operation not permitted" in o and o.strip().endswith("end"),
              o.replace("\n", " | ")[:300])


def android_stop_checks(rep, T, sh, out, stopped):
    """Android stopped in the session: it stays stopped, Waydroid's container
    service stops, and every device it opened is back to its boot mode."""
    inactive, o = False, "the container did not stop"
    deadline = time.monotonic() + T(180)
    while stopped and time.monotonic() < deadline:
        rc, o = sh("systemctl is-active waydroid-container.service", timeout=60)
        if rc is not None and o.strip() == "inactive":
            inactive = True
            break
        time.sleep(5)
    rep.check("android: once Android is stopped, Waydroid's container service stops (antumbra-waydroid-stopped)", inactive, o.strip())
    try:
        with open(os.path.join(out, "android-device-modes-boot.txt"), encoding="utf-8") as f:
            boot = sorted(l for l in f.read().split("\n") if l)
    except OSError:
        boot = []
    rc, o = sh(DEVICE_MODES)
    now = sorted(l for l in o.strip().split("\n")[:-1] if l) if rc == 0 and o.strip().endswith("end") else ["?"]
    rep.check("android: once stopped, binder, the render node, framebuffers and DMA-BUF heaps have their boot modes again",
              bool(boot) and now == boot, ("now: " + " | ".join(now) + " / boot: " + " | ".join(boot))[:500])
    time.sleep(T(30))
    rc, o = sh("lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH; "
               f"runuser -u amnesia -- env {AMNESIA_ENV} systemctl --user show -p ActiveState -p SubState antumbra-android-session.service", timeout=60)
    lines = o.strip().split("\n") if rc == 0 else []
    rep.check("android: a stopped Android stays stopped (the session unit does not start it again)",
              lines[:1] == ["STOPPED"] and sorted(lines[1:]) == ["ActiveState=active", "SubState=exited"], o.replace("\n", " "))


def android_wait_service_stopped(T, sh):
    """Wait for antumbra-waydroid-stopped to stop the container service after a
    refused start, so that a new session finds it gone, not stopping."""
    deadline = time.monotonic() + T(180)
    while time.monotonic() < deadline:
        rc, o = sh("systemctl is-active waydroid-container.service", timeout=60)
        if rc is not None and o.strip() == "inactive":
            return
        time.sleep(5)


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# ---------------------------------------------------------------------------
# Persistent Storage (--persistence; docs/vm-testing.md)
# ---------------------------------------------------------------------------
PERSISTENCE_PASSPHRASE = "antumbra vm persistence"   # at least 12 characters, as the Welcome screen asks
LOCK_PASSPHRASE = "vm-lock-passphrase"
PERSISTENT_MARK = "/home/amnesia/Persistent/antumbra-vm-run1"
# The Welcome screen's own module writes the settings, as the greeter user.
WRITE_SETTINGS_PY = r'''
import json, sys
from antumbra import settings as S
m = S.WelcomeSettings()
for k, v in json.loads(sys.argv[1]).items():
    setattr(m, k, v)
m.write()
print("settings written")
'''


def persistence_phase(vm, rep, T, sh, out, run):
    """Persistent Storage through the Welcome settings: RUN "create" (fresh
    disk) creates it with a screen-lock passphrase and administration on;
    RUN "unlock" (--keep-disk, after a "create" run) first reads what the
    volume stored, then unlocks it with both off. The settings are written
    by the Welcome screen's own module as the greeter user (the files the
    Welcome screen writes, byte for byte); "Start Antumbra" then starts the
    session as after a logout, and the usual network checks follow."""
    create = run == "create"
    rc, o = sh("cat /run/antumbra/persistence-state; blkid -o value -s TYPE /dev/disk/by-partlabel/ANTUMBRA_DATA; echo end")
    lines = o.strip().split("\n") if rc == 0 else []
    rep.check(f"persistence: the volume is {'absent (create)' if create else 'present (unlock)'} at the Welcome screen",
              lines == (["none", "end"] if create else ["luks", "crypto_LUKS", "end"]), o.replace("\n", " "))
    if not create:
        # What the first run stored, read-only, before the applier unlocks it.
        rc, o = sh(f"printf %s {sh_quote(PERSISTENCE_PASSPHRASE)} > /run/antumbra-vm-key && chmod 0600 /run/antumbra-vm-key && "
                   "cryptsetup open --readonly --key-file /run/antumbra-vm-key /dev/disk/by-partlabel/ANTUMBRA_DATA antumbra_vmcheck && "
                   "mkdir -p /run/antumbra-vmcheck && mount -o ro,noload /dev/mapper/antumbra_vmcheck /run/antumbra-vmcheck && "
                   "{ ls -A /run/antumbra-vmcheck/welcome-settings | tr '\\n' ' '; echo; "
                   "grep -h '^ANTUMBRA_ADMIN_ENABLED=' /run/antumbra-vmcheck/welcome-settings/antumbra.admin; "
                   f"cat /run/antumbra-vmcheck/{PERSISTENT_MARK.split('/home/amnesia/', 1)[1]}; }}; "
                   "umount /run/antumbra-vmcheck; cryptsetup close antumbra_vmcheck; rm -f /run/antumbra-vm-key; echo end", timeout=int(T(900)))
        lines = o.strip().split("\n") if rc == 0 else []
        stored = lines[0].split() if lines else []
        rep.check("persistence: the volume kept the first run's Welcome settings (administration on), not the screen-lock passphrase, "
                  "and the file written to ~/Persistent",
                  len(lines) == 4 and sorted(stored) == ["antumbra.admin", "antumbra.android", "tails.bridges", "tails.macspoof", "tails.network"]
                  and lines[1:] == ["ANTUMBRA_ADMIN_ENABLED=true", "antumbra-vm-run1", "end"], o.replace("\n", " | ")[:400])
    choices = {"persistence": run, "persistence_passphrase": PERSISTENCE_PASSPHRASE, "network": "direct",
               "user_password": LOCK_PASSPHRASE if create else "", "admin": create}
    ok = guest_write(sh, "/run/antumbra-vm-settings.py", WRITE_SETTINGS_PY, "0644")
    rc, o = sh("runuser -u antumbra-greeter -- python3 /run/antumbra-vm-settings.py "
               f"{sh_quote(json.dumps(choices))}", timeout=120)
    rep.check(f"persistence: Welcome settings for '{run}' written as the greeter user", ok and rc == 0 and o.strip().endswith("settings written"), o.strip()[-200:])
    applied = None
    deadline = time.monotonic() + T(1500)
    while time.monotonic() < deadline:
        rc, o = sh("if [ -e /run/antumbra/welcome-applied ]; then echo applied; elif [ -e /run/antumbra/welcome-failed ]; then "
                   "echo failed: $(cat /run/antumbra/welcome-failed); else echo waiting; fi", timeout=60)
        if rc == 0 and o.strip() != "waiting":
            applied = o.strip()
            break
        time.sleep(10)
    rep.check(f"persistence: the applier {'created' if create else 'unlocked'} Persistent Storage and applied the settings", applied == "applied", str(applied))
    if applied != "applied":
        rc, o = sh("journalctl -b --no-pager -u antumbra-apply-welcome-settings -t antumbra-welcome | tail -n 60", timeout=60)
        save_text(out, "persistence-applier.txt", o)
        return
    rc, o = sh("/usr/local/sbin/antumbra-persistence status; echo rc=$?; findmnt -no SOURCE /var/lib/antumbra/persistence; "
               "cryptsetup luksDump /dev/disk/by-partlabel/ANTUMBRA_DATA | sed -nE 's/^[[:space:]]*(Version|PBKDF):[[:space:]]+(.*)$/\\1: \\2/p' | sort -u; "
               "for d in /home/amnesia/Persistent /var/lib/antumbra/settings/persistent /etc/NetworkManager/system-connections /var/lib/tca; do "
               "findmnt -no TARGET \"$d\"; done", timeout=120)
    lines = o.strip().split("\n") if rc == 0 else []
    rep.check("persistence: LUKS2 with argon2id, unlocked, mounted, its features bound in place",
              lines[:3] == ["luks", "rc=0", "/dev/mapper/antumbra_data"] and "PBKDF: argon2id" in lines and "Version: 2" in lines
              and lines[-4:] == ["/home/amnesia/Persistent", "/var/lib/antumbra/settings/persistent",
                                 "/etc/NetworkManager/system-connections", "/var/lib/tca"], o.replace("\n", " | "))
    W = "/var/lib/antumbra/persistence/welcome-settings"
    rc, o = sh(f"stat -c '%n %U %a' {W}/*; grep -h '^ANTUMBRA_ADMIN_ENABLED=' {W}/antumbra.admin /var/lib/antumbra/settings/applied/antumbra.admin; "
               "ls -A /var/lib/antumbra/settings/transient | tr '\\n' ' '; echo; "
               "test -e /var/lib/antumbra/settings/staged && echo staged-left; test -e /etc/sudoers.d/antumbra-admin && echo sudoers; "
               "passwd -S amnesia | cut -d' ' -f2; echo end", timeout=60)
    lines = o.strip().split("\n") if rc == 0 else []
    files = [l for l in lines if l.startswith(W)]
    admin = "true" if create else "false"
    rep.check("persistence: this boot's Welcome settings applied and saved on the volume (greeter-owned, no passphrase hash), "
              "no passphrase left behind",
              sorted(l.split()[0].rsplit("/", 1)[1] for l in files) == ["antumbra.admin", "antumbra.android", "tails.bridges", "tails.macspoof", "tails.network"]
              and all(l.endswith(" antumbra-greeter 640") for l in files)
              and lines[len(files):len(files) + 2] == [f"ANTUMBRA_ADMIN_ENABLED={admin}"] * 2
              and "passphrase" not in o and "staged-left" not in lines
              and ("sudoers" in lines) == create and lines[-2:] == (["P", "end"] if create else ["NP", "end"]),
              o.replace("\n", " | ")[:500])
    welcome_phase(vm, rep, T, sh, out, False)
    if create:
        rc, o = sh(f"runuser -u amnesia -- sh -c 'echo antumbra-vm-run1 > {PERSISTENT_MARK}' && sync && "
                   f"cat /var/lib/antumbra/persistence/Persistent/{os.path.basename(PERSISTENT_MARK)}", timeout=60)
        rep.check("persistence: a file written to ~/Persistent lands on the volume", rc == 0 and o.strip() == "antumbra-vm-run1", o.strip())
    else:
        rc, o = sh(f"cat {PERSISTENT_MARK}", timeout=60)
        rep.check("persistence: ~/Persistent still holds the first run's file", rc == 0 and o.strip() == "antumbra-vm-run1", o.strip())


def smoke(vm, scale, stop_after, debug, through_welcome=False, tour=False, fresh_disk=True, camera=False, android=False, android_net=False,
          persistence=False):
    rep = Report()
    T = lambda s: s * scale  # noqa: E731
    out = os.path.join(vm.run, "smoke")
    os.makedirs(out, exist_ok=True)

    def sh(cmd, timeout=120):
        """(exit code, output); on a console failure (None, "") and a FAIL of its own,
        so that no check can mistake an error message for output."""
        try:
            return vm.console.run(cmd, timeout=timeout)
        except Exception as e:  # noqa: BLE001
            rep.check(f"console: {cmd[:60]}", False, str(e)[:300])
            return None, ""

    # 1. Initramfs: the medium is found by bus and UUID, verity and the overlay come up.
    try:
        vm.serial.wait(r"antumbra: locating the system partition", T(240))
        rep.check("initramfs: Antumbra medium search ran", True)
        m = vm.serial.wait(r"(no userdata partition|no live partition|losetup failed|Begin: Running /scripts/live-bottom|live-boot: .*done|systemd\[1\]: )", T(300))
        rep.check("initramfs: live medium accepted", not m.group(1).startswith(("no ", "losetup")), m.group(1))
        vm.serial.wait(r"systemd\[1\]: Reached target .*[Bb]asic [Ss]ystem", T(900))
        rep.check("systemd: basic.target reached", True)
        m = vm.serial.wait(r"systemd\[1\]: Reached target .*[Mm]ulti-[Uu]ser [Ss]ystem", T(900))
        rep.check("systemd: multi-user.target reached", True)
    except Timeout as e:
        rep.check("boot reached multi-user.target", False, str(e)[:600])
        if not vm.alive():
            rep.check("QEMU still running", False, "the VM exited (panic?)")
            return rep
    if not debug:
        print("no debug console: skipping guest-side checks", flush=True)
    else:
        try:
            vm.console.wait_ready(T(300))
            rep.check("debug console: shell on hvc0", True)
        except Timeout as e:
            rep.check("debug console: shell on hvc0", False, str(e))
        if vm.console.sock is None:
            try:
                vm.console.connect()
            except OSError as e:
                rep.check("debug console: connect", False, str(e))
        rc, o = sh("cat /etc/antumbra-release")
        rep.check("guest: /etc/antumbra-release", rc == 0 and f"ANTUMBRA_VERSION={VERSION}" in o, o.replace("\n", " ")[:160])
        rc, o = sh("findmnt -no FSTYPE,SOURCE / ; findmnt -no SOURCE,FSTYPE /run/live/medium; cat /run/antumbra/loop-device")
        rep.check("guest: overlay root on the loop-mounted live partition", "overlay" in o and "/run/live/medium" not in o and "loop" in o, o.replace("\n", " | "))
        rc, o = sh("blkid -o value -s UUID $(cat /run/antumbra/loop-device)p1; cat /etc/antumbra/live-fs-uuid")
        lines = o.split("\n")
        rep.check("guest: live partition UUID equals the recorded one", len(lines) >= 2 and lines[0] == lines[1], o.replace("\n", " = "))
        rc, o = sh("dmsetup table 2>/dev/null | grep -c verity; cat /proc/cmdline | tr ' ' '\\n' | grep -c dm-verity-root-hash")
        try:
            active, requested = ints(o, 2)
            verity_ok = requested == 0 or active >= 1
        except ValueError:
            verity_ok = False
        rep.check("guest: dm-verity active when requested", verity_ok, o.replace("\n", " "))
        rc, o = sh("findmnt -no OPTIONS /run/live/medium")
        rep.check("guest: the live medium is mounted read-only", rc == 0 and "ro" in o.strip().split(","), o.strip())
        rc, o = sh("nft list ruleset 2>/dev/null | grep -c 'table inet antumbra'; nft list chain inet antumbra output 2>/dev/null | grep -c 'policy drop'")
        try:
            tables, drops = ints(o, 2)
            nft_ok = tables >= 1 and drops >= 1
        except ValueError:
            nft_ok = False
        rep.check("guest: nftables firewall loaded with a dropping output chain", nft_ok, o.replace("\n", " "))
        rc, o = sh("cat /run/antumbra/selfcheck.status 2>/dev/null")
        rep.check("guest: selfcheck reports the firewall OK", "firewall OK" in o, o.replace("\n", " | ")[:300])
        rc, o = sh("systemctl is-active tor@default.service")
        rep.check("guest: Tor running (tor@default.service)", rc == 0 and o.strip() == "active", o.strip())
        rc, o = sh("echo profiles=$(wc -l < /sys/kernel/security/apparmor/profiles 2>/dev/null); "
                   "echo tor=$(cat /proc/$(pgrep -xo tor)/attr/apparmor/current 2>/dev/null || cat /proc/$(pgrep -xo tor)/attr/current)")
        f = dict(line.split("=", 1) for line in o.split("\n") if "=" in line)
        rep.check("guest: AppArmor profiles loaded and Tor confined (enforce)",
                  f.get("profiles", "0").strip() not in ("", "0") and f.get("tor", "").startswith("system_tor") and "enforce" in f.get("tor", ""),
                  o.replace("\n", " "))
        # The veth pairs of the confined-application namespaces (and, with
        # Android apps, the empty waydroid-tor bridge) are expected; nothing else may exist.
        rc, o = sh("ip -o link | grep -vcE ': (lo|veth-[a-z]+|waydroid-tor)[:@]' ; lsmod | grep -c '^virtio_net'; systemctl is-active NetworkManager 2>/dev/null")
        parts = o.strip().split("\n")
        rep.check("guest: no network interface or driver before the Welcome decision",
                  len(parts) == 3 and parts[0] == "0" and parts[1] == "0" and parts[2] == "inactive", o.replace("\n", " "))
        rc, o = sh("grep -c virtio_net /etc/modprobe.d/all-net-blocklist.conf")
        rep.check("guest: virtio_net is in the driver blocklist", rc == 0 and o.strip().isdigit() and int(o.strip()) > 0, o.strip())
        rc, o = sh("grep -E '^[[:space:]]*nameserver' /etc/resolv.conf")
        servers = [l.split()[1] for l in o.strip().split("\n") if len(l.split()) >= 2]
        rep.check("guest: resolver is loopback only", rc == 0 and servers == ["127.0.0.1"], " ".join(servers) or o)
        rc, o = sh("echo swap=$(swapon --show=NAME --noheadings | tr '\\n' ' '); echo dmesg=$(sysctl -n kernel.dmesg_restrict); "
                   "echo journal=$(grep -rhs '^Storage=' /usr/lib/systemd/journald.conf.d/ /etc/systemd/journald.conf.d/ | tail -n1); "
                   "test -d /var/log/journal && echo journal-dir=yes || echo journal-dir=no")
        f = dict(line.split("=", 1) for line in o.split("\n") if "=" in line)
        swaps = f.get("swap", "").split()
        rep.check("guest: zram-only swap, dmesg restricted, volatile journal",
                  all(x.startswith("/dev/zram") for x in swaps) and f.get("dmesg") == "1"
                  and f.get("journal") == "Storage=volatile" and f.get("journal-dir") == "no", o.replace("\n", " "))
        rc, o = sh("blkid -o value -s TYPE $(cat /run/antumbra/loop-device)p2; echo end")
        if persistence and not fresh_disk:
            rep.check("guest: Persistent Storage partition holds the previous run's LUKS volume", rc == 0 and o.strip() == "crypto_LUKS\nend", o)
        else:
            rep.check("guest: Persistent Storage partition has no filesystem signature", rc == 0 and o.strip() == "end", o)
        rc, o = sh("grep -c '^ANTUMBRA_MINIMAL=1' /etc/antumbra-release; systemctl is-active greetd; pgrep -xc phoc", timeout=60)
        parts = o.strip().split("\n")
        minimal = len(parts) >= 1 and parts[0] == "1"
        if not minimal:
            rep.check("guest: greeter session (greetd + phoc) running",
                      len(parts) == 3 and parts[1] == "active" and parts[2].isdigit() and int(parts[2]) > 0, o.replace("\n", " "))
            # Give the Welcome screen time to draw under emulation, then capture it.
            welcome = False
            for _ in range(int(T(60))):
                rc, o = sh("pgrep -fc /usr/bin/antumbra-welcome", timeout=30)
                if rc == 0 and o.strip().isdigit() and int(o.strip()) > 0:
                    welcome = True
                    break
                time.sleep(1)
            rep.check("guest: Welcome screen process running", welcome, o.strip())
            if android or android_net:
                android_preflight(vm, rep, T, sh, out)
            time.sleep(T(20))
        else:
            print("minimal build: skipping the session checks", flush=True)
    try:
        w, h = vm.screenshot(os.path.join(out, "display.png"))
        colors = vm.distinct_colors()
        rep.check("display: the Welcome screen is drawn (not a text console)", colors > 24, f"{w}x{h}, {colors} distinct colours -> {out}/display.png")
    except Exception as e:  # noqa: BLE001
        rep.check("display: the Welcome screen is drawn (not a text console)", False, str(e))
    counts = pcap_summary(os.path.join(vm.run, "net.pcap"))
    # Before the decision the guest has no network interface: every frame QEMU's
    # user network did not generate is a leak, whatever its ethertype (ARP too).
    from_guest = {k: v for k, v in counts.items() if not k[3].startswith(SLIRP_MAC_PREFIXES)}
    rep.check("network: no frame of any kind left the guest before the Welcome decision", not from_guest,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} from {k[3]} x{v}" for k, v in sorted(from_guest.items()))
              or (f"no guest frames ({sum(counts.values())} from QEMU's user network)" if counts else "no frames"))
    if through_welcome and debug and persistence:
        persistence_phase(vm, rep, T, sh, out, "create" if fresh_disk else "unlock")
    elif through_welcome and debug:
        welcome_phase(vm, rep, T, sh, out, tour, android, android_net)
    if camera and debug:
        camera_phase(vm, rep, T, sh, out)
    if stop_after:
        # 2. A short power-key press must be ignored (logind HandlePowerKey=ignore,
        #    only a long press powers off): QEMU's system_powerdown is a short press.
        try:
            vm.qmp("system_powerdown")
            time.sleep(T(20))
            rep.check("power key: a short press does not shut the system down", vm.alive())
        except Exception as e:  # noqa: BLE001
            rep.check("power key: a short press does not shut the system down", False, str(e))
        # 3. Shutdown: a short power-key press is ignored by design (logind
        #    HandlePowerKey=ignore, long press powers off), so ask from inside;
        #    without a console, send the key anyway and expect nothing.
        try:
            if debug:
                sh("systemctl --no-block poweroff", timeout=30)
            else:
                vm.qmp("system_powerdown")
            deadline = time.monotonic() + T(300)
            while vm.alive() and time.monotonic() < deadline:
                time.sleep(1)
            rep.check("shutdown: VM powered off after the power button", not vm.alive())
            tail = open(vm.serial.path, "rb").read().decode("utf-8", "replace")[-8000:]
            # The initramfs' shutdown hook states the end result of each step.
            markers = ["antumbra-shutdown: oldroot unmounted", "antumbra-shutdown: medium unmounted",
                       "antumbra-shutdown: verity removed", "antumbra-shutdown: loops detached",
                       "antumbra-shutdown: caches dropped"]
            missing = [x for x in markers if x not in tail]
            still = re.findall(r"antumbra-shutdown: [a-z]+ STILL [A-Z]+", tail)
            rep.check("shutdown: returned to the initramfs, unmounted everything, dropped caches", not missing and not still,
                      ("; ".join(still + ["missing: " + x for x in missing])) or "; ".join(m.split(": ", 1)[1] for m in markers))
        except Exception as e:  # noqa: BLE001
            rep.check("shutdown", False, str(e))
        vm.stop()
        # 4. Amnesia on disk: the copy-on-write overlay holds every block the
        #    guest wrote; on a run that started from a fresh overlay it must
        #    hold none (no Persistent Storage was created in this test).
        if persistence:
            print("storage: check skipped: Persistent Storage writes the disk by design (--persistence)", flush=True)
        elif fresh_disk:
            try:
                mp = json.loads(subprocess.run(["qemu-img", "map", "--output=json", os.path.join(vm.run, "overlay.qcow2")],
                                               capture_output=True, text=True, check=True).stdout)
                written = [e for e in mp if e.get("depth") == 0 and (e.get("data") or e.get("zero"))]
                rep.check("storage: the guest wrote nothing to the disk", not written,
                          "; ".join(f"{e['start']}+{e['length']}" for e in written[:10]) or "no block written to the overlay")
            except Exception as e:  # noqa: BLE001
                rep.check("storage: the guest wrote nothing to the disk", False, str(e)[:300])
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("smoke"); s.add_argument("--timeout-scale", type=float, default=1.0); s.add_argument("--no-stop", action="store_true"); s.add_argument("--no-debug", action="store_true")
    s.add_argument("--through-welcome", action="store_true", help="press Start on the Welcome screen and check the network afterwards")
    s.add_argument("--tour", action="store_true", help="with --through-welcome: extra screenshots of the session (best effort)")
    s.add_argument("--camera", action="store_true", help="camera checks on the VM's virtual camera (vimc); the session ones need --through-welcome")
    android_mode = s.add_mutually_exclusive_group()
    android_mode.add_argument("--android", action="store_true",
                              help="implies --through-welcome: switch Android apps on, boot Android, check it stays on Tor (ANTUMBRA_ANDROID=1 images)")
    android_mode.add_argument("--persistence", action="store_true",
                              help="implies --through-welcome: create Persistent Storage through the Welcome settings; with -- --keep-disk, unlock it")
    android_mode.add_argument("--android-net", action="store_true",
                              help="implies --through-welcome: test Android's Tor-only network with a stand-in namespace, without Android")
    s.add_argument("vm_args", nargs="*")
    w = sub.add_parser("wait"); w.add_argument("regex"); w.add_argument("--timeout", type=float, default=300)
    sh = sub.add_parser("shell"); sh.add_argument("command", nargs="+"); sh.add_argument("--timeout", type=float, default=120)
    sc = sub.add_parser("screenshot"); sc.add_argument("file")
    q = sub.add_parser("qmp"); q.add_argument("command"); q.add_argument("args", nargs="*")
    sub.add_parser("pcap-summary")
    sub.add_parser("console")
    a = ap.parse_args()
    run_dir = a.run_dir or subprocess.run(["bash", "-c", f'ANTUMBRA_DEVICE=${{ANTUMBRA_DEVICE:-qemu-virt}} source "{ROOT}/build/lib/common.sh"; printf %s "$WORK/vm-run"'], capture_output=True, text=True, check=True).stdout
    vm = VM(run_dir)
    if a.cmd == "smoke":
        args = list(a.vm_args)
        debug = not a.no_debug
        if debug and "--debug" not in args:
            args.append("--debug")
        # Android needs about 1.5 GB of its own next to the session.
        if a.android and "--memory" not in args:
            args += ["--memory", "6144"]
        # A serial number on the kernel command line and on the disk, as the
        # phone has; Android must see neither.
        if a.android:
            args = with_vm_args(args, f"androidboot.serialno={TEST_SERIAL}", TEST_DISK_SERIAL)
        vm.start(args)
        try:
            rep = smoke(vm, a.timeout_scale, not a.no_stop, debug, a.through_welcome or a.android or a.android_net or a.persistence, a.tour,
                        fresh_disk="--keep-disk" not in args, camera=a.camera, android=a.android, android_net=a.android_net,
                        persistence=a.persistence)
        except KeyboardInterrupt:
            vm.stop(); raise
        failed = rep.failed()
        print(f"\n{len(rep.results) - len(failed)}/{len(rep.results)} checks passed; run directory {run_dir}", flush=True)
        os.makedirs(os.path.join(run_dir, "smoke"), exist_ok=True)
        with open(os.path.join(run_dir, "smoke", "report.json"), "w") as f:
            json.dump({"version": VERSION, "debug": debug, "timeout_scale": a.timeout_scale,
                       "cmdline": open(os.path.join(run_dir, "cmdline")).read().strip() if os.path.exists(os.path.join(run_dir, "cmdline")) else "",
                       "checks": [{"name": n, "ok": ok, "detail": d, "t": t} for n, ok, d, t in rep.results]}, f, indent=1)
        sys.exit(1 if failed else 0)
    if a.cmd == "wait":
        m = vm.serial.wait(a.regex, a.timeout); print(m.group(0)); return
    if a.cmd == "shell":
        vm.console.wait_ready(a.timeout)
        rc, out = vm.console.run(" ".join(a.command), timeout=a.timeout)
        print(out); sys.exit(rc)
    if a.cmd == "screenshot":
        w, h = vm.screenshot(a.file); print(f"{a.file}: {w}x{h}"); return
    if a.cmd == "qmp":
        kv = dict(x.split("=", 1) for x in a.args)
        print(json.dumps(vm.qmp(a.command, **kv))); return
    if a.cmd == "pcap-summary":
        for k, v in sorted(pcap_summary(os.path.join(run_dir, "net.pcap")).items()):
            print(f"{v:6d}  {k[0]:14s} {k[1]:18s} {k[2]:6d}  from {k[3]}")
        return
    if a.cmd == "console":
        import termios, tty, select  # noqa: E401
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); sock.connect(os.path.join(run_dir, "serial.sock"))
        fd = sys.stdin.fileno(); old = termios.tcgetattr(fd); tty.setraw(fd)
        try:
            while True:
                r, _, _ = select.select([sock, fd], [], [])
                if sock in r:
                    d = sock.recv(4096)
                    if not d:
                        break
                    os.write(1, d)
                if fd in r:
                    d = os.read(fd, 1024)
                    if d == b"\x1d":
                        break
                    sock.sendall(d)
        finally:
            termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
