# SPDX-License-Identifier: GPL-3.0-or-later
"""The Android container's network and the VM harness's Android checks
(runs on the build host).

The firewall must treat the host's own addresses like any other address
(tests/android-net-lab.py replays it in namespaces), the start-host hook
must reject .onion virtual addresses inside the container, and the
harness's Android checks must be able to pass on a good image: commands
inside the container reach the console without lxc-attach's terminal
proxy, a zero count is not a failed command, and Tor's guards from an
earlier phase are not taken for strangers.
"""
import ast
import fcntl
import importlib.util
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import types
import unittest
import unittest.mock

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
HARNESS = os.path.join(ROOT, "tests", "vm", "antumbra_vm.py")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def load_harness():
    spec = importlib.util.spec_from_file_location("antumbra_vm", HARNESS)
    vm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vm)
    return vm


def chain(text, table, name):
    m = re.search(rf"^table {table} \{{\n(.*?)^\}}", text, re.S | re.M)
    m = re.search(rf"chain {name} \{{(.*?)\n    \}}", m.group(1), re.S)
    return [l.strip() for l in m.group(1).splitlines() if l.strip() and not l.strip().startswith("#")]


class FirewallTest(unittest.TestCase):
    """What the namespace lab shows, pinned in the text."""

    def setUp(self):
        self.nft = read("config", "rootfs", "etc", "nftables.conf")

    def test_only_the_bridge_address_is_left_untranslated(self):
        android = chain(self.nft, "ip antumbra-nat", "android")
        self.assertNotIn("fib daddr type local return", android)
        self.assertLess(android.index("ip daddr $android_host return"), android.index("meta l4proto tcp counter redirect to :$android_transport"))

    def test_other_host_addresses_are_dropped_silently(self):
        rules = [r for r in chain(self.nft, "inet antumbra", "input") if r.startswith("iifname $android_if")]
        self.assertEqual(rules[0], "iifname $android_if udp sport 68 udp dport 67 ip daddr { 255.255.255.255, $android_host } accept")
        self.assertEqual(rules[1], "iifname $android_if ip daddr != $android_host drop")
        self.assertEqual(rules[-1], "iifname $android_if jump android_reject")


class OnionTest(unittest.TestCase):
    def test_start_host_hook_rejects_the_automap_range_in_the_container(self):
        hook = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host")
        nft = read("config", "rootfs", "etc", "nftables.conf")
        torrc = read("config", "rootfs", "etc", "tor", "torrc")
        self.assertRegex(torrc, r"(?m)^AutomapHostsOnResolve 1$")
        self.assertRegex(nft, r"(?m)^define onion_automap = 127\.192\.0\.0/10$")
        self.assertIn("ip daddr 127.192.0.0/10 reject;", hook)
        self.assertIn('| nsenter --target "${LXC_PID}" --net nft -f - || fail ', hook)
        # before "exit 0", and a missing PID fails closed
        self.assertLess(hook.index("nsenter --target"), hook.index("\nexit 0"))
        self.assertIn("'' | *[!0-9]*) fail ", hook)


class JudgeTest(unittest.TestCase):
    """judge_android_probes on what the namespace lab measured with the
    fixed firewall and hook, and with the old ones."""

    def setUp(self):
        self.vm = load_harness()
        o = self.vm.ONION_NAME
        self.good = {
            f"dns 10.200.2.1 {o}": "rcode=0 a=127.198.154.224", f"dns 8.8.8.8 {o}": "rcode=0 a=127.198.154.224",
            f"onion 10.200.2.1 {o} {self.vm.ONION_PORT}": "refused loopback=connected",
            "tcp 10.0.2.2 80": "timeout", "tcp 192.168.1.1 80": "timeout", "tcp 192.168.1.37 22": "timeout",
            "tcp 10.200.1.1 9050": "timeout", "tcp 10.200.2.1 9041": "unreachable", "tcp 10.200.2.1 9052": "unreachable",
            "tcp 10.200.2.1 951": "unreachable", "tcp 198.51.100.7 853": "unreachable",
            "tcp 198.51.100.7 80": "connected", "tcp 198.51.100.7 443": "connected", f"tcp {self.vm.HOST_PUBLIC} 443": "connected",
            "udp 10.200.2.1 5354": "no-reply", "udp 203.0.113.5 123": "no-reply", "udp 203.0.113.5 443": "no-reply"}

    def judge(self, res):
        return {name: ok for name, ok, _ in self.vm.judge_android_probes(res, "192.168.1.37")}

    def test_every_probe_is_judged(self):
        keys = {" ".join(str(a) for a in p) for p in self.vm.android_probe_list("192.168.1.37") if p[0] != "raw"}
        self.assertEqual(keys, set(self.good))
        self.assertTrue(all(self.judge(self.good).values()), self.judge(self.good))

    def test_host_addresses_refused_at_once_fail(self):
        for key in ("tcp 192.168.1.37 22", "tcp 10.200.1.1 9050", f"tcp {self.vm.HOST_PUBLIC} 443"):
            failed = [n for n, ok in self.judge(dict(self.good, **{key: "unreachable"})).items() if not ok]
            self.assertEqual(len(failed), 1, (key, failed))

    def test_onion_delivered_to_a_listener_fails(self):
        o = self.vm.ONION_NAME
        verdict = self.judge(dict(self.good, **{f"onion 10.200.2.1 {o} {self.vm.ONION_PORT}": "connected loopback=connected"}))
        self.assertEqual([n for n, ok in verdict.items() if not ok],
                         ["android-net: a .onion name's address is refused inside the container, not delivered to another app listening on its port"])


# lxc-attach as LXC 6.0 runs it from the debug console (tools/lxc_attach.c,
# terminal.c): if any standard descriptor is a tty, the attached program's
# output goes through a terminal proxy to /dev/tty, set up and torn down
# with tcsetattr(TCSAFLUSH), which discards the tty's unread input. Here
# the "attached" program is the host's, with /system/bin/ stripped.
FAKE_LXC_ATTACH = r'''#!/usr/bin/env python3
import os, subprocess, sys, termios
argv = sys.argv[sys.argv.index("--") + 1:]
argv[0] = os.path.basename(argv[0])
if any(os.isatty(fd) for fd in (0, 1, 2)):
    tty = os.open("/dev/tty", os.O_RDWR)
    saved = termios.tcgetattr(tty)
    raw = list(saved)
    raw[3] &= ~(termios.ICANON | termios.ECHO)
    termios.tcsetattr(tty, termios.TCSAFLUSH, raw)
    p = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True)
    os.write(tty, (p.stdout + p.stderr).replace(b"\n", b"\r\n"))
    termios.tcsetattr(tty, termios.TCSAFLUSH, saved)
    sys.exit(p.returncode)
os.execvp(argv[0], argv)
'''
FAKES = {
    "lxc-attach": FAKE_LXC_ATTACH,
    "getprop": '#!/bin/sh\ncase "$1" in sys.boot_completed) echo 1 ;; *) echo "value-of-$1" ;; esac\n',
    "settings": "#!/bin/sh\nprintf '0\\r\\n'\n",
    # Waydroid 1.6.3's "shell" runs lxc-attach with its own descriptors.
    "waydroid": '#!/bin/sh\n[ "$1" = shell ] || exit 2\nshift; [ "$1" = -- ] && shift\n'
                'exec lxc-attach -P /var/lib/waydroid/lxc -n waydroid --clear-env -- "$@"\n',
}


@unittest.skipUnless(shutil.which("bash") and os.path.exists("/dev/ptmx"), "needs bash and ptys")
class ConsoleAttachTest(unittest.TestCase):
    """The harness's Console protocol against a root shell on a pty, as
    agetty gives it on hvc0, with lxc-attach's terminal behaviour."""

    @classmethod
    def setUpClass(cls):
        cls.vm = load_harness()
        cls.tmp = tempfile.mkdtemp(prefix="antumbra-console-")
        bindir = os.path.join(cls.tmp, "bin")
        os.mkdir(bindir)
        for name, text in FAKES.items():
            with open(os.path.join(bindir, name), "w") as f:
                f.write(text)
            os.chmod(os.path.join(bindir, name), 0o755)
        cls.master, slave = os.openpty()
        env = {"PATH": bindir + ":/usr/bin:/bin", "HOME": cls.tmp, "TERM": "dumb"}
        cls.shell = subprocess.Popen(["bash", "--norc", "--noprofile", "-i"], stdin=slave, stdout=slave, stderr=slave, env=env,
                                     cwd=cls.tmp, start_new_session=True,
                                     preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        sock_path = os.path.join(cls.tmp, "hvc0.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(sock_path)
        srv.listen(1)

        def relay():
            conn = srv.accept()[0]

            def to_shell():
                while True:
                    try:
                        data = conn.recv(4096)
                        if not data:
                            return
                        os.write(cls.master, data)
                    except OSError:
                        return
            threading.Thread(target=to_shell, daemon=True).start()
            while True:
                try:
                    data = os.read(cls.master, 4096)
                    if not data:
                        return
                    conn.sendall(data)
                except OSError:
                    return
        threading.Thread(target=relay, daemon=True).start()
        # in_android's output file: /run in the VM (root's console), the
        # test's own directory here (the unit tests also run unprivileged).
        cls.vm.ANDROID_OUT = os.path.join(cls.tmp, "in-android.out")
        cls.console = cls.vm.Console(sock_path, os.path.join(cls.tmp, "hvc0.log"))
        cls.console.connect()

    @classmethod
    def tearDownClass(cls):
        cls.console.close()
        cls.shell.kill()
        cls.shell.wait()
        os.close(cls.master)
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_a_bare_attach_loses_the_marker(self):
        # The emulation reproduces the failure the harness had...
        with self.assertRaises(self.vm.Timeout):
            self.console.run(f"{self.vm.ANDROID_LXC} /system/bin/getprop sys.boot_completed", timeout=3)
        with self.assertRaises(self.vm.Timeout):
            self.console.run("echo k=$(waydroid shell -- settings get global k | tr -d '\\r' | tail -n 1)", timeout=3)
        # ... and the console works again afterwards.
        self.assertEqual(self.console.run("echo back"), (0, "back"))

    def test_in_android_returns_output_and_status(self):
        run, in_android = self.console.run, self.vm.in_android
        self.assertEqual(run(in_android("/system/bin/getprop sys.boot_completed")), (0, "1"))
        self.assertEqual(run(f"echo v=$({in_android('/system/bin/getprop ro.product.model')})"), (0, "v=value-of-ro.product.model"))
        self.assertEqual(run(in_android("/system/bin/false")), (1, ""))
        self.assertEqual(run(f"{in_android('/system/bin/ls -A /nonexistent')} | wc -l"), (0, "0"))
        rc, o = run(in_android("/system/bin/ls /nonexistent", errors=True))
        self.assertNotEqual(rc, 0)
        self.assertIn("nonexistent", o)
        self.assertEqual(run(f"{in_android('/system/bin/cat /nonexistent')} >/dev/null && echo readable || echo hidden"), (0, "hidden"))

    def test_a_timed_out_command_is_interrupted(self):
        # A command that outlives its limit keeps the shell busy: the next
        # command times out behind it ...
        with self.assertRaises(self.vm.Timeout):
            self.console.run("sleep 60; echo late", timeout=2)
        with self.assertRaises(self.vm.Timeout):
            self.console.run("echo queued", timeout=3)
        # ... until recover() interrupts it; then the console answers again.
        self.assertTrue(self.console.recover(timeout=20))
        self.assertEqual(self.console.run("echo after", timeout=20), (0, "after"))

    def test_waydroid_shell_with_redirections(self):
        self.assertEqual(self.console.run("for k in a b; do echo $k=$(waydroid shell -- settings get global $k </dev/null 2>/dev/null "
                                          "| tr -d '\\r' | tail -n 1); done"), (0, "a=0\nb=0"))

    def test_a_scan_killed_by_sigkill_is_read(self):
        # The camera checks' image scan through this shell, with a scanner
        # that ignores SIGTERM in its place and timeout's -k 1 instead of
        # -k 30, the limit made 2 s by the timeout scale: timeout's SIGKILL
        # kills timeout too, and bash prints "Killed" before the status line.
        seen = []

        def sh(cmd, timeout=120):
            if "--xdev /" not in cmd:
                return (1, "") if cmd.startswith("df ") else (None, "")
            cmd = re.sub(r"timeout -k 30 (\d+) python3 /tmp/antumbra-no-oneplus-camera\.py --xdev /",
                         r"""timeout -k 1 \1 sh -c 'trap "" TERM; sleep 20'""", cmd)
            cmd = cmd.replace("/run/antumbra-nopc.out", os.path.join(self.tmp, "nopc.out"))
            seen.append(self.console.run(cmd, timeout=timeout))
            return seen[-1]
        rep = self.vm.Report()
        with unittest.mock.patch.object(self.vm, "put_file", lambda sh, path, data: True):
            self.vm.oneplus_scan_checks(rep, lambda s: s / 1000, sh)
        self.assertEqual(len(seen), 1)
        self.assertRegex(seen[0][1], r"^Killed\nscan: exit 137 after \d+ s$")
        results = {name: (ok, detail) for name, ok, detail, _ in rep.results}
        ok, detail = results[self.vm.ONEPLUS_SCAN]
        self.assertFalse(ok)
        self.assertRegex(detail, r"^the scan was stopped at its limit \(2 s\) after \d+ s$")


class HarnessAttachUseTest(unittest.TestCase):
    """Every command the harness runs inside the container goes through
    in_android, and every "waydroid shell" has no tty on any descriptor."""

    def test_no_bare_attach(self):
        tree = ast.parse(read("tests", "vm", "antumbra_vm.py"))
        users, attach, shells = set(), [], []

        class Visit(ast.NodeVisitor):
            def __init__(self):
                self.stack = []

            def visit_FunctionDef(self, node):
                self.stack.append(node.name)
                self.generic_visit(node)
                self.stack.pop()

            def visit_Expr(self, node):
                if not isinstance(node.value, ast.Constant):   # docstrings aside
                    self.generic_visit(node)

            def visit_Name(self, node):
                if node.id == "ANDROID_LXC" and isinstance(node.ctx, ast.Load):
                    users.add(self.stack[-1] if self.stack else "<module>")

            def visit_Constant(self, node):
                if isinstance(node.value, str):
                    if "lxc-attach" in node.value:
                        attach.append(node.value)
                    shells.extend(m.group(1) for m in re.finditer(r"waydroid shell(.*?)(?:\||;|\)|$)", node.value))
        Visit().visit(tree)
        self.assertEqual(users, {"in_android"})
        self.assertEqual(attach, ["lxc-attach -P /var/lib/waydroid/lxc -n waydroid --clear-env --"])
        self.assertTrue(shells)
        for rest in shells:
            self.assertIn("</dev/null", rest)
            self.assertIn("2>", rest)


class PreflightTest(unittest.TestCase):
    """android_preflight's check of Waydroid's templates, its command run by
    a shell on a tree laid out as hook 56 leaves it."""

    CONFIG_3 = ("lxc.net.0.link = waydroid-tor\nlxc.net.0.hwaddr = 00:16:3e:f9:d3:03\n"
                "lxc.hook.start-host = /usr/local/lib/antumbra-waydroid-start-host\nlxc.cgroup2.devices.deny = c 81:* rwm\n"
                "lxc.mount.entry = tmpfs sys/firmware tmpfs ro,nosuid,nodev,noexec,mode=0555,size=4k 0 0\n")
    NAME = ("android: Waydroid's templates use waydroid-tor, keep no sys_time, run the start-host hook, deny V4L2, "
            "hide /sys/firmware, pass no video device")

    def verdict(self, **override):
        files = {"data/configs/config_1": "lxc.network.link = waydroid-tor\n", "data/configs/config_3": self.CONFIG_3,
                 "data/configs/config_base": "lxc.cap.keep = audit_control sys_nice setgid setuid sys_admin net_admin\n",
                 "tools/actions/container_manager.py": "import glob\n", "tools/helpers/lxc.py": "import glob\n"}
        files.update(override)
        vm = load_harness()
        with tempfile.TemporaryDirectory() as tmp:
            for rel, text in files.items():
                path = os.path.join(tmp, "usr", "lib", "waydroid", rel)
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(text)

            def sh(cmd, timeout=120):
                if "/usr/lib/waydroid/data/configs" not in cmd:
                    return None, ""
                p = subprocess.run(["bash", "-c", cmd.replace("/usr/lib/waydroid/", tmp + "/usr/lib/waydroid/")], capture_output=True, text=True)
                return p.returncode, p.stdout.strip("\n")
            rep = vm.Report()
            vm.android_preflight(None, rep, lambda s: s, sh, tmp)
        found = [ok for name, ok, _, _ in rep.results if name == self.NAME]
        self.assertEqual(len(found), 1)
        return found[0]

    def test_good_image_passes(self):
        self.assertTrue(self.verdict())

    def test_bad_images_fail(self):
        self.assertFalse(self.verdict(**{"tools/helpers/lxc.py": 'x = glob.glob("/dev/video*")\n'}))
        self.assertFalse(self.verdict(**{"data/configs/config_3": self.CONFIG_3.replace("waydroid-tor", "waydroid0")}))
        self.assertFalse(self.verdict(**{"data/configs/config_base": "lxc.cap.keep = sys_admin sys_time\n"}))


def pcap(syns):
    """A capture holding a TCP SYN from 52:54:00:12:34:56 to each (IP, port)."""
    out = struct.pack("<IHHiIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
    for dst, port in syns:
        eth = bytes(6) + bytes.fromhex("525400123456") + b"\x08\x00"
        ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 40, 0, 0, 64, 6, 0, socket.inet_aton("10.0.2.15"), socket.inet_aton(dst))
        tcp = struct.pack("!HHIIBBHHH", 40000, port, 1, 0, 5 << 4, 0x02, 65535, 0, 0)
        frame = eth + ip + tcp
        out += struct.pack("<IIII", 0, 0, len(frame), len(frame)) + frame
    return out


class TrafficChecksTest(unittest.TestCase):
    """traffic_checks across the phases of one run: one capture, Tor's
    sockets seen only in each call's window."""

    BUILTIN = ("1.2.3.4", 443)
    GUARDS = [("198.51.100.10", 9001), ("198.51.100.11", 443), ("198.51.100.12", 9001)]

    def phase(self, vm, fake, label, capture, peers, record=None, timewait=()):
        """The SYN check of one call, (ok, detail); its socket check goes to
        self.sockets. CAPTURE is the whole run's capture so far, PEERS Tor's
        sockets in this window, TIMEWAIT ownerless closed sockets in it,
        RECORD the guest's record of Tor's SYNs (None: it cannot be read)."""
        with open(os.path.join(fake.run, "net.pcap"), "wb") as f:
            f.write(pcap(capture))
        ss = "\n".join([f'tcp   ESTAB 0 0 10.0.2.15:4{i:04d} {ip}:{port} users:(("tor",pid=812,fd={i + 10})) uid:107 ino:{i + 4000}'
                        for i, (ip, port) in enumerate(peers)]
                       + [f"tcp   TIME-WAIT 0 0 10.0.2.15:5{i:04d} {ip}:{port} timer:(timewait,40sec,0) ino:0 sk:{i + 90}"
                          for i, (ip, port) in enumerate(timewait)])
        listing = ("table ip antumbra_vm_tor_syns {\n\tset syns {\n\t\ttype ipv4_addr . inet_service\n\t\tsize 65536\n"
                   "\t\tflags dynamic\n" + (("\t\telements = { " + ",\n\t\t\t     ".join(f"{ip} . {port}" for ip, port in record) + " }\n")
                                            if record else "") + "\t}\n}")

        def sh(cmd, timeout=120):
            if "ss -tuna" in cmd:
                return 0, ss + "\nend"
            if "orport" in cmd:
                return 0, "1.2.3.4 orport=443"
            if cmd == "id -u debian-tor":
                return 0, "107"
            if cmd == "nft -nn list set ip antumbra_vm_tor_syns syns" and record is not None:
                return 0, listing
            return None, ""
        rep = vm.Report()
        vm.traffic_checks(fake, rep, lambda s: s, sh, label, 1)
        cap = "packet capture" if label == "after Welcome" else f"{label}, packet capture"
        found = {n: (ok, detail) for n, ok, detail, _ in rep.results}
        self.sockets = found[f"{label}: every connection to the network belongs to Tor (DHCP aside)"]
        return found[f"{cap}: every TCP connection the guest opened went to a Tor directory or relay"]

    def test_guards_of_an_earlier_phase_are_tor_s(self):
        vm = load_harness()
        with tempfile.TemporaryDirectory() as tmp:
            fake = types.SimpleNamespace(run=tmp)
            capture = [self.BUILTIN] + self.GUARDS
            self.assertTrue(self.phase(vm, fake, "after Welcome", capture, self.GUARDS)[0])
            # Later only the guard in use is connected; the bootstrap SYNs
            # to the others are still in the capture.
            ok, detail = self.phase(vm, fake, "with Android", capture, self.GUARDS[:1])
            self.assertTrue(ok, detail)
            # A new guard seen on Tor's sockets is Tor's, a new destination
            # nobody saw is not.
            new_guard, stranger = ("198.51.100.13", 9001), ("203.0.113.9", 80)
            ok, detail = self.phase(vm, fake, "android-net", capture + [new_guard, stranger], [self.GUARDS[0], new_guard])
            self.assertFalse(ok)
            self.assertEqual(detail, "not Tor's: 203.0.113.9:80; the record of Tor's SYNs could not be read")

    def test_relay_closed_between_windows_is_tor_s_by_the_record(self):
        # A directory fetch from a relay Tor first contacts between two
        # windows and closes before the next: the SYN is new, no socket of
        # Tor's shows it (at most an ownerless TIME-WAIT socket), and only
        # the kernel's record of Tor's SYNs has it.
        vm = load_harness()
        relay, stranger = ("198.51.100.20", 443), ("203.0.113.9", 80)
        with tempfile.TemporaryDirectory() as tmp:
            fake = types.SimpleNamespace(run=tmp)
            capture = [self.BUILTIN] + self.GUARDS
            record = [self.BUILTIN] + self.GUARDS
            self.assertTrue(self.phase(vm, fake, "after Welcome", capture, self.GUARDS, record)[0])
            capture, record = capture + [relay], record + [relay]
            ok, detail = self.phase(vm, fake, "with Android", capture, self.GUARDS[:1], record, timewait=[relay])
            self.assertTrue(ok, detail)
            self.assertEqual(detail, "1 new destinations: 0 built into Tor, 0 seen on Tor's sockets, 1 only in the record of Tor's SYNs")
            self.assertTrue(self.sockets[0], self.sockets[1])
            self.assertIn("1 closed Tor sockets in TIME-WAIT", self.sockets[1])
            # What no socket of Tor's sent stays a stranger, by the SYN and
            # by its closed socket.
            capture = capture + [stranger]
            ok, detail = self.phase(vm, fake, "android-net", capture, self.GUARDS[:1], record, timewait=[stranger])
            self.assertEqual((ok, detail), (False, "not Tor's: 203.0.113.9:80"))
            self.assertFalse(self.sockets[0])
            self.assertIn("203.0.113.9:80", self.sockets[1])

    def test_without_the_record_a_relay_closed_between_windows_is_flagged(self):
        # The record unreadable: as strict as before it existed.
        vm = load_harness()
        relay = ("198.51.100.20", 443)
        with tempfile.TemporaryDirectory() as tmp:
            fake = types.SimpleNamespace(run=tmp)
            capture = [self.BUILTIN] + self.GUARDS
            self.assertTrue(self.phase(vm, fake, "after Welcome", capture, self.GUARDS)[0])
            ok, detail = self.phase(vm, fake, "with Android", capture + [relay], self.GUARDS[:1])
            self.assertEqual((ok, detail), (False, "not Tor's: 198.51.100.20:443; the record of Tor's SYNs could not be read"))

    def test_the_record_is_loaded_before_the_network(self):
        vm = load_harness()
        for nft_ok in (True, False):
            sent = []

            def sh(cmd, timeout=120):
                sent.append(cmd)
                if cmd == "id -u debian-tor":
                    return 0, "107"
                if "base64 -d > /run/antumbra-vm-tor-syns.nft" in cmd:
                    return 0, "written"
                if cmd.startswith("nft -f /run/antumbra-vm-tor-syns.nft"):
                    return (0, "1") if nft_ok else (1, "Error: Could not process rule")
                return None, ""
            rep = vm.Report()
            vm.tor_syn_record_start(rep, sh)
            self.assertEqual([ok for _, ok, _, _ in rep.results], [nft_ok])
            self.assertTrue(sent[-1].startswith("nft -f /run/antumbra-vm-tor-syns.nft"), sent)
        # the table written is the one for Tor's UID
        self.assertIn("meta skuid 107 tcp flags & (syn | ack) == syn add @syns", vm.tor_syn_table("107"))
        # welcome_phase loads it before the tap that brings the network up
        src = read("tests", "vm", "antumbra_vm.py")
        body = src[src.index("def welcome_phase("):src.index("\ndef ", src.index("def welcome_phase(") + 1)]
        self.assertLess(body.index("tor_syn_record_start(rep, sh)"), body.index("vm.tap(*target)"))
        self.assertLess(body.index("android_net_phase(vm, rep, T, sh, out)"), body.index("tor_syn_record_stop(sh)"))

    @unittest.skipUnless(os.geteuid() == 0 and shutil.which("nft") and shutil.which("unshare"), "needs root, nft and unshare")
    def test_the_record_holds_only_tor_s_syns(self):
        # The record's table in a network namespace of its own: a SYN from
        # a socket of "Tor's" user (65534 here) is recorded, root's is not,
        # and the harness reads the set back.
        vm = load_harness()
        script = r'''
import os, socket, subprocess, sys
def run(*cmd, **kw):
    subprocess.run(cmd, check=True, **kw)
run("nft", "-f", "-", input=sys.argv[1], text=True)
run("ip", "link", "add", "rec0", "type", "veth", "peer", "name", "rec1")
run("ip", "addr", "add", "192.0.2.1/24", "dev", "rec0")
for link in ("lo", "rec0", "rec1"):
    run("ip", "link", "set", link, "up")
run("ip", "route", "add", "default", "via", "192.0.2.2", "dev", "rec0")
def connect(host, port, uid):
    if os.fork() == 0:
        os.setgid(uid); os.setuid(uid)
        s = socket.socket(); s.settimeout(0.3)
        try:
            s.connect((host, port))
        except OSError:
            pass
        os._exit(0)
    os.wait()
connect("198.51.100.1", 443, 0)
connect("198.51.100.2", 9001, 65534)
connect("203.0.113.3", 443, 65534)
sys.stdout.write(subprocess.run(["nft", "-nn", "list", "set", "ip", "antumbra_vm_tor_syns", "syns"], check=True,
                                capture_output=True, text=True).stdout)
'''
        r = subprocess.run(["unshare", "-n", sys.executable, "-c", script, vm.tor_syn_table(65534)], capture_output=True, text=True)
        if r.returncode != 0 and ("Unknown device type" in r.stderr or "Operation not supported" in r.stderr):
            self.skipTest(r.stderr.strip()[-200:])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(vm.tor_syn_record(lambda cmd, timeout=120: (0, r.stdout)),
                         {("198.51.100.2", 9001), ("203.0.113.3", 443)})
        self.assertIsNone(vm.tor_syn_record(lambda cmd, timeout=120: (None, "")))


class OnionPingTest(unittest.TestCase):
    """The --android run's ping of a .onion name with Android's own ping, as
    android_onion_ping runs it. The image's /system/bin/ping is iputils
    (header "PING name (address) 56(84) bytes of data.", "unknown host" when
    the resolver gives nothing); toybox and busybox word it a little
    differently."""

    def run_ping(self, output):
        vm = load_harness()
        rep = vm.Report()
        with tempfile.TemporaryDirectory() as out:
            vm.android_onion_ping(rep, lambda cmd, timeout=120: (0, output.replace("NAME", vm.ONION_NAME)), out)
            with open(os.path.join(out, "android-onion-ping.txt")) as f:
                self.assertEqual(f.read(), output.replace("NAME", vm.ONION_NAME))
        return [(ok, detail) for name, ok, detail, _ in rep.results if name == vm.ONION_PING]

    def test_refused_address_passes(self):
        for output in (
                # iputils, the reject in the container's output chain
                "PING NAME (127.198.154.224) 56(84) bytes of data.\nFrom 127.0.0.1 icmp_seq=1 Destination Port Unreachable\n\n"
                "--- NAME ping statistics ---\n1 packets transmitted, 0 received, +1 errors, 100% packet loss, time 0ms\n\n\nrc=1",
                # iputils, no answer at all
                "PING NAME (127.255.0.1) 56(84) bytes of data.\n\n--- NAME ping statistics ---\n"
                "1 packets transmitted, 0 received, 100% packet loss, time 0ms\n\n\nrc=1",
                # toybox, busybox
                "Ping NAME (127.198.154.224): 56(+28) data bytes\n\nrc=1",
                "PING NAME (127.198.154.224): 56 data bytes\n\n--- NAME ping statistics ---\n"
                "1 packets transmitted, 0 packets received, 100% packet loss\n\nrc=1"):
            with self.subTest(output[:40]):
                found = self.run_ping(output)
                self.assertEqual(len(found), 1)
                self.assertTrue(found[0][0], found[0][1])

    def test_answer_or_wrong_address_fails(self):
        for output in (
                # the old hook: the container's loopback answers
                "PING NAME (127.198.154.224) 56(84) bytes of data.\n64 bytes from 127.198.154.224: icmp_seq=1 ttl=64 time=0.051 ms\n\n"
                "--- NAME ping statistics ---\n1 packets transmitted, 1 received, 0% packet loss, time 0ms\n\n\nrc=0",
                "PING NAME (127.198.154.224): 56 data bytes\n64 bytes from 127.198.154.224: seq=0 ttl=64 time=0.1 ms\n\nrc=0",
                # not Tor's automap answer
                "PING NAME (10.11.12.13) 56(84) bytes of data.\n\nrc=1",
                # an exit status 0 without a reply line
                "PING NAME (127.198.154.224) 56(84) bytes of data.\n\nrc=0"):
            with self.subTest(output[:40]):
                found = self.run_ping(output)
                self.assertEqual(len(found), 1)
                self.assertFalse(found[0][0], found[0][1])

    def test_no_address_is_reported_not_failed(self):
        # Android's resolver gave ping nothing under lxc-attach: neither a
        # pass nor a failure; the probe in Android's namespace decides.
        for output in ("ping: unknown host NAME\n\nrc=2", "ping: icmp open socket: Operation not permitted\n\nrc=2", "\nrc=1"):
            with self.subTest(output):
                self.assertEqual(self.run_ping(output), [])


LAB = os.path.join(ROOT, "tests", "android-net-lab.py")
LAB_PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Shims for the lab's tools, each standing for a build host without one
# kernel feature; KEEP is the real program.
LAB_SHIMS = {
    # no bridge module (a user namespace cannot load one)
    "bridge": ("ip", 'case " $* " in *" type bridge "*) echo "Error: Unknown device type." >&2; exit 2 ;; esac\n'
                     'exec KEEP "$@"\n'),
    # no tmpfs mount allowed
    "tmpfs": ("mount", 'case " $* " in *" tmpfs "*) echo "mount: /run: permission denied." >&2; exit 32 ;; esac\n'
                       'exec KEEP "$@"\n'),
    # no mount namespaces
    "mount namespace": ("unshare", 'case " $* " in *" --mount "*) echo "unshare: unshare failed: Operation not permitted" >&2; exit 1 ;; esac\n'
                                   'exec KEEP "$@"\n'),
    # nf_tables without nft_reject_ipv4 (the ruleset's inet rejects load)
    "reject": ("nft", 'if [ "$1 $2" = "-f -" ]; then\n'
                      '    input="$(cat)"\n'
                      '    case "$input" in *"127.192.0.0/10 reject"*) echo "Error: Could not process rule: No such file or directory" >&2; exit 1 ;; esac\n'
                      '    printf "%s\\n" "$input" | exec KEEP "$@"\n'
                      'fi\n'
                      'exec KEEP "$@"\n'),
}


class LabSkipTest(unittest.TestCase):
    """tests/android-net-lab.py on build hosts that lack a kernel feature it
    needs: it says so and exits 0 (lint goes on), while a hook that really
    fails is still a failure. Each run binds a shim over one of the lab's
    tools in a mount namespace of its own.

    These tests need a host where the lab itself runs. Where it cannot (no
    user or network namespaces, a tool or a driver missing), they skip with
    the reason instead of failing for the very host gaps they are about."""

    @classmethod
    def setUpClass(cls):
        for tool in ("ip", "nft", "nsenter", "mount", "unshare"):
            if not shutil.which(tool, path=LAB_PATH):
                raise unittest.SkipTest(f"{tool} not installed")
        cls.ns = ["unshare", "--mount", "--propagation", "private"] if os.geteuid() == 0 else \
            ["unshare", "-Ur", "--mount", "--propagation", "private"]
        net = ["unshare", "-n", "true"] if os.geteuid() == 0 else ["unshare", "-Urn", "true"]
        for probe in (cls.ns + ["true"], net):
            r = subprocess.run(probe, capture_output=True, text=True, env=dict(os.environ, PATH=LAB_PATH))
            if r.returncode != 0:
                raise unittest.SkipTest(f"cannot run {' '.join(probe)} here: {r.stderr.strip()[:200]}")
        # The lab as it is, on this host. Where it skips (a driver or a
        # kernel feature missing), a shim shows nothing and a failing hook is
        # never reached: these tests skip too, with its reason.
        cls.plain = cls.lab()
        if cls.plain[1].startswith("skipped: "):
            raise unittest.SkipTest("the lab cannot run on this host: " + cls.plain[1].splitlines()[0][len("skipped: "):])

    @classmethod
    def shimmed(cls, argv, shim=None, cwd=None, hide=()):
        """(exit status, output) of ARGV run with SHIM bound over its tool,
        and an empty directory over each directory in HIDE."""
        with tempfile.TemporaryDirectory() as d:
            script = "set -e\n" + "".join(f"mount -t tmpfs antumbra-lab-test {h}\n" for h in hide)
            if shim:
                tool, body = LAB_SHIMS[shim]
                real = os.path.realpath(shutil.which(tool, path=LAB_PATH))
                keep, fake = os.path.join(d, tool + ".real"), os.path.join(d, tool)
                with open(fake, "w") as f:
                    f.write("#!/bin/sh\n" + body.replace("KEEP", keep))
                os.chmod(fake, 0o755)
                open(keep, "w").close()
                script += f"mount --bind {real} {keep}\nmount --bind {fake} {real}\n"
            script += 'exec "$@"\n'
            r = subprocess.run(cls.ns + ["sh", "-c", script, "sh"] + argv, capture_output=True, text=True, timeout=600,
                               cwd=cwd, env=dict(os.environ, PATH=LAB_PATH, PYTHONDONTWRITEBYTECODE="1"))
        return r.returncode, r.stdout + r.stderr

    @classmethod
    def lab(cls, shim=None, hook=None, hide=()):
        return cls.shimmed([sys.executable, LAB] + (["--hook", hook] if hook else []), shim, hide=hide)

    def test_these_tests_skip_where_the_lab_cannot_run(self):
        # This class itself on a build host without the bridge driver, where
        # the lab says "skipped: ..." and exits 0: its tests must skip with
        # the lab's reason, not fail for the host gap they are about.
        tests = [f"test_android_net.LabSkipTest.{t}" for t in
                 ("test_missing_kernel_features_skip", "test_a_failing_hook_still_fails", "test_passes_with_every_feature")]
        rc, out = self.shimmed([sys.executable, "-m", "unittest", "-v"] + tests, "bridge",
                               cwd=os.path.dirname(os.path.abspath(__file__)))
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r"\nOK \(skipped=\d+\)\n", out)
        self.assertIn("the lab cannot run on this host: ", out)
        self.assertIn("Unknown device type", out)
        self.assertNotIn("FAIL", out)

    def test_missing_kernel_features_skip(self):
        for shim, says in (("bridge", "Unknown device type"), ("tmpfs", "permission denied"),
                           ("mount namespace", "unshare failed"), ("reject", "Could not process rule")):
            with self.subTest(shim):
                rc, out = self.lab(shim)
                self.assertEqual(rc, 0, out)
                self.assertTrue(out.startswith("skipped: "), out)
                self.assertIn(says, out)
                self.assertNotIn("[FAIL]", out)

    def test_a_failing_hook_still_fails(self):
        with open(os.path.join(ROOT, "config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host")) as f:
            hook = f.read()
        with tempfile.TemporaryDirectory() as d:
            for name, text in (("refuses", hook.replace("\nexit 0\n", "\nfail 'lab test'\n")),
                               ("bad nft", hook.replace("127.192.0.0/10 reject;", "127.192.0.0/10 rejekt;"))):
                with self.subTest(name):
                    self.assertNotEqual(text, hook)
                    path = os.path.join(d, "hook")
                    with open(path, "w") as f:
                        f.write(text)
                    rc, out = self.lab(hook=path)
                    self.assertEqual(rc, 1, out)
                    self.assertIn("[FAIL] lab: the start-host hook passes", out)
                    self.assertNotIn("skipped", out)

    def test_a_missing_repository_file_fails(self):
        # The image's generic kernel command line, which the hook's run
        # copies into its /run, gone from the repository: a finding about
        # the code, not a gap of this host.
        cmdline = os.path.join(os.path.abspath(ROOT), "config", "rootfs-android", "usr", "share", "antumbra", "android", "cmdline")
        self.assertTrue(os.path.isfile(cmdline))
        rc, out = self.lab(hide=[os.path.dirname(cmdline)])
        self.assertEqual(rc, 1, out)
        self.assertIn(f"[FAIL] lab: the image's generic kernel command line can be read ({cmdline}): No such file or directory", out)
        self.assertNotIn("skipped", out)

    def test_passes_with_every_feature(self):
        rc, out = self.plain   # the run setUpClass made
        self.assertEqual(rc, 0, out)
        self.assertNotIn("skipped", out)
        self.assertNotIn("[FAIL]", out)
        self.assertGreaterEqual(out.count("[PASS]"), 8, out)


class LabSkipSetupTest(unittest.TestCase):
    """LabSkipTest's setup on build hosts where the lab cannot run,
    simulated (so this runs on any host): it skips with the reason, it never
    errors, and it does not skip where the lab runs or fails."""

    def setup_on(self, missing=(), refused=False, lab=(0, "[PASS] lab\n")):
        real_which = shutil.which

        # Every tool the case does not leave out is there, whatever this
        # host has: the simulated host is the case's, not the build host.
        def which(tool, mode=os.F_OK | os.X_OK, path=None):
            return None if tool in missing else (real_which(tool, mode, path) or f"/usr/bin/{tool}")

        def run(argv, **kw):
            if argv[0] in missing:
                raise FileNotFoundError(2, "No such file or directory", argv[0])
            return subprocess.CompletedProcess(argv, 1 if refused else 0, "",
                                               "unshare: unshare failed: Operation not permitted\n" if refused else "")

        class Host(LabSkipTest):
            @classmethod
            def lab(cls, shim=None, hook=None):
                return lab
        with unittest.mock.patch("shutil.which", which), unittest.mock.patch("subprocess.run", run):
            try:
                Host.setUpClass()
            except unittest.SkipTest as e:
                return str(e), None
        return None, getattr(Host, "plain", None)

    def test_host_gaps_skip(self):
        for case, kw, reason in (
                ("no unshare", {"missing": ("unshare",)}, "unshare not installed"),
                ("no nft", {"missing": ("nft",)}, "nft not installed"),
                ("no namespaces", {"refused": True}, "here: unshare: unshare failed: Operation not permitted"),
                ("no bridge driver", {"lab": (0, "skipped: cannot build the lab's network (ip link add waydroid-tor type bridge): "
                                                "Error: Unknown device type.\n")},
                 "the lab cannot run on this host: cannot build the lab's network (ip link add waydroid-tor type bridge): "
                 "Error: Unknown device type.")):
            with self.subTest(case):
                skipped, _ = self.setup_on(**kw)
                self.assertIsNotNone(skipped)
                self.assertTrue(skipped.endswith(reason), skipped)

    def test_a_lab_that_runs_or_fails_is_not_skipped(self):
        for lab in ((0, "[PASS] lab: x\n"), (1, "[FAIL] lab: the start-host hook passes\n")):
            with self.subTest(lab[1]):
                self.assertEqual(self.setup_on(lab=lab), (None, lab))


if __name__ == "__main__":
    unittest.main()
