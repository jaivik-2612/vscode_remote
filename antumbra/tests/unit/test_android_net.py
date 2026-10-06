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
import tempfile
import termios
import threading
import types
import unittest

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

    def test_waydroid_shell_with_redirections(self):
        self.assertEqual(self.console.run("for k in a b; do echo $k=$(waydroid shell -- settings get global $k </dev/null 2>/dev/null "
                                          "| tr -d '\\r' | tail -n 1); done"), (0, "a=0\nb=0"))


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

    def phase(self, vm, fake, label, capture, peers):
        with open(os.path.join(fake.run, "net.pcap"), "wb") as f:
            f.write(pcap(capture))
        ss = "\n".join(f'tcp   ESTAB 0 0 10.0.2.15:4{i:04d} {ip}:{port} users:(("tor",pid=812,fd={i + 10})) uid:107 ino:{i + 4000}'
                       for i, (ip, port) in enumerate(peers))

        def sh(cmd, timeout=120):
            if "ss -tunap" in cmd:
                return 0, ss + "\nend"
            if "orport" in cmd:
                return 0, "1.2.3.4 orport=443"
            if cmd == "id -u debian-tor":
                return 0, "107"
            return None, ""
        rep = vm.Report()
        vm.traffic_checks(fake, rep, lambda s: s, sh, label, 1)
        cap = "packet capture" if label == "after Welcome" else f"{label}, packet capture"
        return [(ok, detail) for name, ok, detail, _ in rep.results
                if name == f"{cap}: every TCP connection the guest opened went to a Tor directory or relay"][0]

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
            self.assertEqual(detail, "not Tor's: 203.0.113.9:80")


if __name__ == "__main__":
    unittest.main()
