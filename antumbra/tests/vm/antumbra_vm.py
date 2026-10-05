#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Drive an Antumbra qemu-virt VM started by build/vm.sh: serial-log waits,
commands over the debug console (hvc0), QMP (screenshots, power button),
packet-capture summaries, and the smoke test. Standard library only.

usage: antumbra_vm.py [--run-dir DIR] COMMAND ...
  smoke [--timeout-scale F] [--no-stop]   boot, check, power down; exit 1 on any failure
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
        self.run = run_dir
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


# ---------------------------------------------------------------------------
# Smoke test
# ---------------------------------------------------------------------------
class Report:
    def __init__(self):
        self.results = []

    def check(self, name, ok, detail=""):
        self.results.append((name, bool(ok), detail))
        print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""), flush=True)
        return ok

    def failed(self):
        return [r for r in self.results if not r[1]]


def smoke(vm, scale, stop_after, debug):
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
        # The veth pairs of the confined-application namespaces are expected; nothing else may exist.
        rc, o = sh("ip -o link | grep -vcE ': (lo|veth-[a-z]+)[:@]' ; lsmod | grep -c '^virtio_net'; systemctl is-active NetworkManager 2>/dev/null")
        parts = o.split("\n")
        rep.check("guest: no network interface or driver before the Welcome decision", parts[0] == "0" and parts[1] == "0" and "inactive" in o, o.replace("\n", " "))
        rc, o = sh("grep -c virtio_net /etc/modprobe.d/all-net-blocklist.conf")
        rep.check("guest: virtio_net is in the driver blocklist", o.strip() != "0", o)
        rc, o = sh("cat /etc/resolv.conf | grep -v '^#' | tr '\\n' ' '")
        rep.check("guest: resolver is loopback only", "127.0.0.1" in o and "10.0.2" not in o, o)
        rc, o = sh("swapon --show --noheadings | awk '{print $1}' | tr '\\n' ' '; sysctl -n kernel.dmesg_restrict; grep -rhs '^Storage=' /usr/lib/systemd/journald.conf.d/ /etc/systemd/journald.conf.d/; test -d /var/log/journal && echo persistent-journal || echo no-journal-dir")
        rep.check("guest: zram-only swap, dmesg restricted, volatile journal", "/dev/" not in o.replace("/dev/zram", "") and "\n1\n" in "\n" + o + "\n" and "Storage=volatile" in o and "no-journal-dir" in o, o.replace("\n", " "))
        rc, o = sh("blkid -o value -s TYPE $(cat /run/antumbra/loop-device)p2; echo end")
        rep.check("guest: Persistent Storage partition is untouched (no filesystem)", o.strip() == "end", o)
        rc, o = sh("systemctl is-active greetd 2>/dev/null; pgrep -c phoc; pgrep -c antumbra-welcome", timeout=60)
        parts = o.split("\n")
        if "active" in parts[0]:
            rep.check("guest: greeter session (greetd + phoc) running", parts[0] == "active" and parts[1] != "0", o.replace("\n", " "))
            # Give the Welcome screen time to draw under emulation, then capture it.
            for _ in range(int(T(60))):
                rc, o = sh("pgrep -c antumbra-welcome", timeout=30)
                if o.strip() not in ("0", ""):
                    break
                time.sleep(1)
            time.sleep(T(20))
        else:
            print("no greetd (minimal build): skipping the session checks", flush=True)
    try:
        w, h = vm.screenshot(os.path.join(out, "display.png"))
        rep.check("display: screenshot captured", True, f"{w}x{h} -> {out}/display.png")
    except Exception as e:  # noqa: BLE001
        rep.check("display: screenshot captured", False, str(e))
    counts = pcap_summary(os.path.join(vm.run, "net.pcap"))
    leaks = {k: v for k, v in counts.items() if k[0] in ("tcp", "udp", "ipv6") or k[0].startswith("ip-proto")}
    rep.check("network: no packet left the guest before the Welcome decision", not leaks,
              "; ".join(f"{k[0]} {k[1]}:{k[2]} x{v}" for k, v in sorted(counts.items())) or "no frames")
    if stop_after:
        # 2. Shutdown: a short power-key press is ignored by design (logind
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
            tail = open(vm.serial.path, "rb").read().decode("utf-8", "replace")[-3000:]
            rep.check("shutdown: returned to the initramfs", "initramfs" in tail.lower() and ("unmount" in tail.lower() or "shutdown" in tail.lower()), tail.strip().split("\n")[-1][:160])
        except Exception as e:  # noqa: BLE001
            rep.check("shutdown", False, str(e))
        vm.stop()
    return rep


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", default=None)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("smoke"); s.add_argument("--timeout-scale", type=float, default=1.0); s.add_argument("--no-stop", action="store_true"); s.add_argument("--no-debug", action="store_true"); s.add_argument("vm_args", nargs="*")
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
            rep = smoke(vm, a.timeout_scale, not a.no_stop, debug)
        except KeyboardInterrupt:
            vm.stop(); raise
        failed = rep.failed()
        print(f"\n{len(rep.results) - len(failed)}/{len(rep.results)} checks passed; run directory {run_dir}", flush=True)
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
