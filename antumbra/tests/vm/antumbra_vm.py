#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive an Antumbra qemu-virt VM started by build/vm.sh: serial-log waits,
commands over the debug console (hvc0), QMP (screenshots, power button),
packet-capture summaries, and the smoke test. Standard library only.

usage: antumbra_vm.py [--run-dir DIR] COMMAND ...
  smoke [--timeout-scale F] [--no-stop] [--through-welcome [--tour]] [--camera]
                                          boot, check, power down; exit 1 on any failure
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


def welcome_phase(vm, rep, T, sh, out, tour):
    """Press "Start Antumbra" with the defaults (amnesic, MAC anonymization on,
    connect to Tor automatically) and check what happens to the network."""
    pcap_frames_before = sum(pcap_summary(os.path.join(vm.run, "net.pcap")).values())
    # The button is drawn in exactly the accent colour; at a tolerance of 45
    # this light accent would also match the edges of near-white text.
    target = vm.find_color(WELCOME_ACCENT, tol=30, region=(0, 1100, 720, 1440))
    rep.check("welcome: Start button found on the display", target is not None, str(target))
    if target is None:
        return
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
    # Network: the driver loads only now, behind the spoofed address.
    up = False
    deadline = time.monotonic() + T(300)
    while time.monotonic() < deadline:
        rc, o = sh("ip -o -4 addr show scope global | grep -vE ': veth-' | awk '{print $2, $4}'", timeout=60)
        if rc == 0 and re.search(r"^\S+ \d+\.\d+\.\d+\.\d+/\d+$", o, re.M):
            up = True
            break
        time.sleep(5)
    rc, links = sh("ip -o link | grep -vE ': (lo|veth-[a-z]+)[:@]' | sed -E 's/^[0-9]+: ([^:@]+).* link\\/ether ([0-9a-f:]+).*/\\1 \\2/'; lsmod | grep -c '^virtio_net'", timeout=60)
    rep.check("after Welcome: the network driver loaded and the interface got an address", up, (o.strip() + " | " + links.replace("\n", " ")).strip(" |"))
    macs = re.findall(r"([0-9a-f]{2}(?::[0-9a-f]{2}){5})", links)
    rep.check("after Welcome: the interface's MAC address is not the hardware one", bool(macs) and QEMU_MAC not in macs,
              f"hardware {QEMU_MAC}, interface {', '.join(macs) or 'none'}")
    # Give Tor time to try (it cannot bootstrap from the build host's network),
    # recording every socket in the system once a second: Tor's peers, and
    # anything else that talks to the network.
    polls = int(T(90))
    rc, o = sh(f"for i in $(seq {polls}); do ss -tunapH state all; sleep 1; done | "
               "grep -vE '127\\.0\\.0\\.1|\\[::1\\]|10\\.200\\.1\\.|LISTEN|UNCONN' | sort -u; echo end", timeout=polls * 3 + 120)
    socks = [l for l in o.split("\n") if l.strip() and l.strip() != "end"] if rc is not None else []
    # NetworkManager's DHCP client (udp :68 -> :67) is the one non-Tor flow
    # the firewall allows, as in Tails.
    dhcp = [l for l in socks if l.startswith("udp") and '(("NetworkManager"' in l and re.search(r":68\s+\S+:67\s", l)]
    non_tor = [l for l in socks if '(("tor"' not in l and l not in dhcp]
    tor_peers = set()
    for l in socks:
        if '(("tor"' in l:
            m = re.search(r"\s(\d+\.\d+\.\d+\.\d+):(\d+)\s+users:", l)
            if m:
                tor_peers.add((m.group(1), int(m.group(2))))
    rep.check("after Welcome: every connection to the network belongs to Tor (DHCP aside)", rc is not None and not non_tor,
              f"{len(tor_peers)} Tor peers, {len(dhcp)} DHCP client sockets" + ((": " + " | ".join(x[:120] for x in non_tor[:4])) if non_tor else ""))
    # Before it has a consensus Tor only knows the addresses built into it; read
    # them from the guest's own binary.
    rc, o = sh("grep -aoE '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+ orport=[0-9]+|orport=[0-9]+[[:print:]]{0,200} "
               "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:[0-9]+ ' \"$(readlink -f /usr/bin/tor)\" | sort -u", timeout=120)
    builtin = tor_builtin_addresses(o) if rc == 0 else set()
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
    rep.check("packet capture: the guest sent no DNS, NTP, IPv6 or other UDP (DHCP aside)", not bad,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(bad.items())) or f"{sum(sent.values())} frames sent, {udp67} of them DHCP")
    syns = {(dst, port) for src, dst, port in pcap_tcp_syns(capture) if not src.startswith(SLIRP_MAC_PREFIXES)}
    stray = sorted(syns - tor_peers - builtin)
    rep.check("packet capture: every TCP connection the guest opened went to a Tor directory or relay", bool(syns) and not stray,
              (("not Tor's: " + ", ".join(f"{d}:{p}" for d, p in stray[:8])) if stray else
               f"{len(syns)} destinations: {len(syns & builtin)} built into Tor, {len(syns - builtin)} seen on Tor's sockets"))
    rep.check("packet capture: no frame carried the hardware MAC address", not from_hw,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(from_hw.items())) or f"guest frames came from {', '.join(sorted({k[3] for k in sent}))} only")
    try:
        vm.screenshot(os.path.join(out, "session.png"))
    except Exception:  # noqa: BLE001
        pass
    if tour:
        take_tour(vm, rep, sh, out, T)


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


def smoke(vm, scale, stop_after, debug, through_welcome=False, tour=False, fresh_disk=True, camera=False):
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
        # The veth pairs of the confined-application namespaces are expected; nothing else may exist.
        rc, o = sh("ip -o link | grep -vcE ': (lo|veth-[a-z]+)[:@]' ; lsmod | grep -c '^virtio_net'; systemctl is-active NetworkManager 2>/dev/null")
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
    if through_welcome and debug:
        welcome_phase(vm, rep, T, sh, out, tour)
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
        if fresh_disk:
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
        vm.start(args)
        try:
            rep = smoke(vm, a.timeout_scale, not a.no_stop, debug, a.through_welcome, a.tour,
                        fresh_disk="--keep-disk" not in args, camera=a.camera)
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
