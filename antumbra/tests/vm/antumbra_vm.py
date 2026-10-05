#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive an Antumbra qemu-virt VM started by build/vm.sh: serial-log waits,
commands over the debug console (hvc0), QMP (screenshots, power button),
packet-capture summaries, and the smoke test. Standard library only.

usage: antumbra_vm.py [--run-dir DIR] COMMAND ...
  smoke [--timeout-scale F] [--no-stop] [--through-welcome [--tour]]
                                          boot, check, power down; exit 1 on any failure
  wait REGEX [--timeout S]                wait for REGEX in the serial log
  shell CMD...                            run a command on the debug console, print its output
  screenshot FILE.png                     dump the display
  qmp COMMAND [key=value ...]             send a QMP command (e.g. system_powerdown, quit)
  pcap-summary                            summarise net.pcap by destination
  console                                 attach to the serial console (raw, Ctrl-] detaches)
"""
import argparse
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
        pid = self.pid()
        if pid is None:
            return False
        try:
            os.kill(pid, 0)
            return True
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
ADWAITA_BLUE = (0x35, 0x84, 0xe4)  # libadwaita's default accent (suggested-action buttons)


def welcome_phase(vm, rep, T, sh, out, tour):
    """Press "Start Antumbra" with the defaults (amnesic, MAC anonymization on,
    connect to Tor automatically) and check what happens to the network."""
    pcap_frames_before = sum(pcap_summary(os.path.join(vm.run, "net.pcap")).values())
    target = vm.find_color(ADWAITA_BLUE, tol=45, region=(0, 1100, 720, 1440))
    rep.check("welcome: Start button found on the display", target is not None, str(target))
    if target is None:
        return
    vm.tap(*target)
    # The session starts once the root-side applier has consumed the settings.
    session = False
    deadline = time.monotonic() + T(420)
    while time.monotonic() < deadline:
        rc, o = sh("pgrep -xc phosh; test -e /var/lib/antumbra/settings/applied/tails.network && echo applied", timeout=60)
        if o.split("\n")[0] not in ("0", "") and "applied" in o:
            session = True
            break
        time.sleep(5)
    rep.check("welcome: settings applied and the Phosh session started", session, o.replace("\n", " "))
    # Network: the driver loads only now, behind the spoofed address.
    up = False
    deadline = time.monotonic() + T(300)
    while time.monotonic() < deadline:
        rc, o = sh("ip -o -4 addr show scope global | grep -vE ': veth-' | awk '{print $2, $4}'", timeout=60)
        if o.strip():
            up = True
            break
        time.sleep(5)
    rc, links = sh("ip -o link | grep -vE ': (lo|veth-[a-z]+)[:@]' | sed -E 's/^[0-9]+: ([^:@]+).* link\\/ether ([0-9a-f:]+).*/\\1 \\2/'; lsmod | grep -c '^virtio_net'", timeout=60)
    rep.check("after Welcome: the network driver loaded and the interface got an address", up, (o.strip() + " | " + links.replace("\n", " ")).strip(" |"))
    macs = re.findall(r"([0-9a-f]{2}(?::[0-9a-f]{2}){5})", links)
    rep.check("after Welcome: the interface's MAC address is not the hardware one", bool(macs) and QEMU_MAC not in macs,
              f"hardware {QEMU_MAC}, interface {', '.join(macs) or 'none'}")
    # Give Tor time to try (it cannot bootstrap from the build host's network).
    time.sleep(T(90))
    rc, o = sh("ss -tunapH | grep -vE '127\\.0\\.0\\.1|\\[::1\\]|10\\.200\\.1\\.' | grep -vE 'LISTEN|UNCONN' ; echo end", timeout=60)
    socks = [l for l in o.split("\n") if l.strip() and l.strip() != "end"]
    # NetworkManager's DHCP client (udp :68 -> :67) is the one non-Tor flow
    # the firewall allows, as in Tails.
    dhcp = [l for l in socks if l.startswith("udp") and '(("NetworkManager"' in l and re.search(r":68\s+\S+:67\s", l)]
    non_tor = [l for l in socks if '(("tor"' not in l and l not in dhcp]
    tor_n = sum(1 for l in socks if '(("tor"' in l)
    rep.check("after Welcome: every connection to the network belongs to Tor (DHCP aside)", not non_tor,
              f"{tor_n} Tor sockets, {len(dhcp)} DHCP client" + ((": " + " | ".join(x[:120] for x in non_tor[:4])) if non_tor else ""))
    counts = pcap_summary(os.path.join(vm.run, "net.pcap"))
    # The capture holds both directions; judge what the guest sent (its
    # hardware MAC or the address it shows now), not QEMU's replies.
    guest_macs = set(macs) | {QEMU_MAC}
    sent = {k: v for k, v in counts.items() if k[3] in guest_macs}
    bad = {k: v for k, v in sent.items()
           if k[0] == "ipv6" or (k[0] == "udp" and k[2] != 67) or k[0].startswith("ip-proto") or k[0].startswith("ethertype")}
    from_hw = {k: v for k, v in sent.items() if k[3] == QEMU_MAC}
    tcp = sorted({f"{k[1]}:{k[2]}" for k in sent if k[0] == "tcp"})
    udp67 = sum(v for k, v in sent.items() if k[0] == "udp" and k[2] == 67)
    rep.check("packet capture: the guest sent no DNS, NTP, IPv6 or other UDP (DHCP aside)", not bad,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(bad.items()))
              or f"{sum(sent.values())} frames sent: {udp67} DHCP, TCP to {len(tcp)} Tor relays ({', '.join(tcp[:6])}{', ...' if len(tcp) > 6 else ''})")
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


def smoke(vm, scale, stop_after, debug, through_welcome=False, tour=False):
    rep = Report()
    T = lambda s: s * scale  # noqa: E731
    out = os.path.join(vm.run, "smoke")
    os.makedirs(out, exist_ok=True)

    def sh(cmd, timeout=120):
        try:
            return vm.console.run(cmd, timeout=timeout)
        except Exception as e:  # noqa: BLE001
            return 255, f"<console error: {e}>"

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
        rep.check("guest: dm-verity active when requested", o.split("\n")[0] == o.split("\n")[-1] or o.startswith("1"), o.replace("\n", " "))
        rc, o = sh("nft list ruleset 2>/dev/null | grep -c 'table inet antumbra'; nft list chain inet antumbra output 2>/dev/null | grep -c 'policy drop'")
        rep.check("guest: nftables firewall loaded with a dropping output chain", o.split("\n")[0] != "0" and o.split("\n")[-1] != "0", o.replace("\n", " "))
        rc, o = sh("cat /run/antumbra/selfcheck.status 2>/dev/null")
        rep.check("guest: selfcheck reports the firewall OK", "firewall OK" in o, o.replace("\n", " | ")[:300])
        rc, o = sh("systemctl is-active tor.service tor@default.service 2>/dev/null | tr '\\n' ' '")
        rep.check("guest: Tor running", "active" in o.split(), o)
        rc, o = sh("echo profiles=$(wc -l < /sys/kernel/security/apparmor/profiles 2>/dev/null); "
                   "echo tor=$(cat /proc/$(pgrep -xo tor)/attr/apparmor/current 2>/dev/null || cat /proc/$(pgrep -xo tor)/attr/current)")
        f = dict(line.split("=", 1) for line in o.split("\n") if "=" in line)
        rep.check("guest: AppArmor profiles loaded and Tor confined (enforce)",
                  f.get("profiles", "0").strip() not in ("", "0") and f.get("tor", "").startswith("system_tor") and "enforce" in f.get("tor", ""),
                  o.replace("\n", " "))
        # The veth pairs of the confined-application namespaces are expected; nothing else may exist.
        rc, o = sh("ip -o link | grep -vcE ': (lo|veth-[a-z]+)[:@]' ; lsmod | grep -c '^virtio_net'; systemctl is-active NetworkManager 2>/dev/null")
        parts = o.split("\n")
        rep.check("guest: no network interface or driver before the Welcome decision", parts[0] == "0" and parts[1] == "0" and "inactive" in o, o.replace("\n", " "))
        rc, o = sh("grep -c virtio_net /etc/modprobe.d/all-net-blocklist.conf")
        rep.check("guest: virtio_net is in the driver blocklist", o.strip() != "0", o)
        rc, o = sh("cat /etc/resolv.conf | grep -v '^#' | tr '\\n' ' '")
        rep.check("guest: resolver is loopback only", "127.0.0.1" in o and "10.0.2" not in o, o)
        rc, o = sh("echo swap=$(swapon --show=NAME --noheadings | tr '\\n' ' '); echo dmesg=$(sysctl -n kernel.dmesg_restrict); "
                   "echo journal=$(grep -rhs '^Storage=' /usr/lib/systemd/journald.conf.d/ /etc/systemd/journald.conf.d/ | tail -n1); "
                   "test -d /var/log/journal && echo journal-dir=yes || echo journal-dir=no")
        f = dict(line.split("=", 1) for line in o.split("\n") if "=" in line)
        swaps = f.get("swap", "").split()
        rep.check("guest: zram-only swap, dmesg restricted, volatile journal",
                  all(x.startswith("/dev/zram") for x in swaps) and f.get("dmesg") == "1"
                  and f.get("journal") == "Storage=volatile" and f.get("journal-dir") == "no", o.replace("\n", " "))
        rc, o = sh("blkid -o value -s TYPE $(cat /run/antumbra/loop-device)p2; echo end")
        rep.check("guest: Persistent Storage partition is untouched (no filesystem)", o.strip() == "end", o)
        rc, o = sh("systemctl is-active greetd 2>/dev/null; pgrep -xc phoc; pgrep -fc /usr/bin/antumbra-welcome", timeout=60)
        parts = o.split("\n")
        if "active" in parts[0]:
            rep.check("guest: greeter session (greetd + phoc) running", parts[0] == "active" and parts[1] not in ("0", ""), o.replace("\n", " "))
            # Give the Welcome screen time to draw under emulation, then capture it.
            welcome = False
            for _ in range(int(T(60))):
                rc, o = sh("pgrep -fc /usr/bin/antumbra-welcome", timeout=30)
                if o.strip() not in ("0", ""):
                    welcome = True
                    break
                time.sleep(1)
            rep.check("guest: Welcome screen process running", welcome, o.strip())
            time.sleep(T(20))
        else:
            print("no greetd (minimal build): skipping the session checks", flush=True)
    try:
        w, h = vm.screenshot(os.path.join(out, "display.png"))
        colors = vm.distinct_colors()
        rep.check("display: the Welcome screen is drawn (not a text console)", colors > 24, f"{w}x{h}, {colors} distinct colours -> {out}/display.png")
    except Exception as e:  # noqa: BLE001
        rep.check("display: the Welcome screen is drawn (not a text console)", False, str(e))
    counts = pcap_summary(os.path.join(vm.run, "net.pcap"))
    leaks = {k: v for k, v in counts.items() if k[0] in ("tcp", "udp", "ipv6") or k[0].startswith("ip-proto")}
    rep.check("network: no packet left the guest before the Welcome decision", not leaks,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(counts.items())) or "no frames")
    if through_welcome and debug:
        welcome_phase(vm, rep, T, sh, out, tour)
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
            tail = open(vm.serial.path, "rb").read().decode("utf-8", "replace")[-6000:]
            # The initramfs' shutdown hook (traced with set -x) moves the medium out of the
            # old root, unmounts it, removes the verity device, detaches the loop device and
            # drops the page cache before systemd-shutdown powers off.
            steps = ["umount --recursive /mnt/live/medium", "dmsetup remove_all", "losetup -D", "drop_caches"]
            missing = [x for x in steps if x not in tail]
            rep.check("shutdown: returned to the initramfs, unmounted the medium, dropped caches", not missing,
                      ("missing: " + ", ".join(missing)) if missing else "; ".join(steps))
        except Exception as e:  # noqa: BLE001
            rep.check("shutdown", False, str(e))
        vm.stop()
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("smoke"); s.add_argument("--timeout-scale", type=float, default=1.0); s.add_argument("--no-stop", action="store_true"); s.add_argument("--no-debug", action="store_true")
    s.add_argument("--through-welcome", action="store_true", help="press Start on the Welcome screen and check the network afterwards")
    s.add_argument("--tour", action="store_true", help="with --through-welcome: extra screenshots of the session (best effort)")
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
            rep = smoke(vm, a.timeout_scale, not a.no_stop, debug, a.through_welcome, a.tour)
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
