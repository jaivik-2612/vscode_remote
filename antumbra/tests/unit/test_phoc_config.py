# SPDX-License-Identifier: GPL-3.0-or-later
"""The compositor settings (runs on the build host).

The greeter's phoc and the user session's phoc must read one file,
/etc/phosh/phoc.ini: phosh-session (Phosh 0.46) gives it to the session's
phoc when it exists, else Debian's /usr/share/phosh/phoc.ini, and
antumbra-greeter-session must choose by the same rule. Up to
0.1.0-alpha.2 only the greeter read Antumbra's settings, so the session
would have taken the panel's preferred 90 Hz mode at a scale of phoc's
choosing and tried to start Xwayland. The VM harness checks the session's
phoc command line and journal (phoc_session_check); that check must pass
on a good session, fail on the old one, and never crash on odd output.
"""
import base64
import configparser
import importlib.util
import os
import re
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OVERLAY = os.path.join(ROOT, "config", "rootfs")
GREETER = os.path.join(OVERLAY, "usr", "libexec", "antumbra-greeter-session")
HARNESS = os.path.join(ROOT, "tests", "vm", "antumbra_vm.py")
PHOC_INI = "/etc/phosh/phoc.ini"
DEBIAN_INI = "/usr/share/phosh/phoc.ini"
# The session's phoc as phosh-session 0.46 starts it (its last line).
SESSION_ARGV = ["/usr/bin/phoc", "-v", "-S", "-C", PHOC_INI, "-E",
                "bash -lc 'exec gnome-session --disable-acceleration-check --session=phosh'"]


def load_harness():
    spec = importlib.util.spec_from_file_location("antumbra_vm", HARNESS)
    vm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vm)
    return vm


def write(path, text, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, mode)


def phosh_session_choice(root):
    """The file phosh-session gives the session's phoc in the tree ROOT
    (Phosh 0.46's /usr/bin/phosh-session: Debian's file, replaced by
    /etc/phosh/phoc.ini when that is a file)."""
    return PHOC_INI if os.path.isfile(root + PHOC_INI) else DEBIAN_INI


def greeter_choice(root):
    """Run antumbra-greeter-session with its absolute paths moved under ROOT
    and a stand-in phoc that records its arguments; the file it passes with
    -C, as a path in the image."""
    with open(GREETER, encoding="utf-8") as f:
        script = re.sub(r"(?<![\w./-])/(usr|etc)/", lambda m: root + m.group(0), f.read())
    write(os.path.join(root, "usr", "bin", "phoc"), "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$0.args\"\n", 0o755)
    write(os.path.join(root, "usr", "libexec", "antumbra-session-env"), "")
    write(root + DEBIAN_INI, "")
    write(os.path.join(root, "greeter-session"), script, 0o755)
    subprocess.run(["sh", os.path.join(root, "greeter-session")], check=True, timeout=30,
                   env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    with open(os.path.join(root, "usr", "bin", "phoc.args"), encoding="utf-8") as f:
        argv = f.read().split("\0")[:-1]
    path = load_harness().phoc_config(["phoc"] + argv)
    assert path is not None and path.startswith(root + "/"), argv
    return path[len(root):]


class SettingsTest(unittest.TestCase):
    def test_panel_and_vm_settings(self):
        ini = configparser.ConfigParser(interpolation=None, strict=True)
        with open(OVERLAY + PHOC_INI, encoding="utf-8") as f:
            ini.read_file(f)
        # Xwayland is not installed; 90 Hz has DSI transport errors on the port.
        self.assertEqual(ini.get("core", "xwayland"), "false")
        self.assertEqual(ini.get("output:DSI-1", "mode"), "1440x3120@60Hz")
        self.assertEqual(ini.get("output:DSI-1", "scale"), "3")
        self.assertEqual(ini.get("output:Virtual-1", "scale"), "2")


class OneFileTest(unittest.TestCase):
    def test_greeter_reads_the_sessions_file(self):
        with tempfile.TemporaryDirectory() as root:
            if os.path.isfile(OVERLAY + PHOC_INI):
                os.makedirs(os.path.dirname(root + PHOC_INI))
                shutil.copy(OVERLAY + PHOC_INI, root + PHOC_INI)
            self.assertEqual(phosh_session_choice(root), PHOC_INI, "the overlay does not ship /etc/phosh/phoc.ini")
            self.assertEqual(greeter_choice(root), PHOC_INI)

    def test_same_fallback_without_it(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(greeter_choice(root), phosh_session_choice(root))


def output(procs, xwayland=0):
    """PHOC_SESSION's output for [(pid, argv, journal lines)]."""
    lines = []
    for pid, argv, log in procs:
        lines.append(f"pid {pid} " + base64.b64encode("".join(a + "\0" for a in argv).encode()).decode())
        lines.append(f"log {log}")
    return "\n".join(lines + [f"xwayland {xwayland}", "end"])


class HarnessCheckTest(unittest.TestCase):
    def setUp(self):
        self.vm = load_harness()

    def judge(self, o, rc=0):
        return self.vm.judge_phoc_session(rc, o)

    def test_config_path(self):
        cfg = self.vm.phoc_config
        self.assertEqual(cfg(SESSION_ARGV), PHOC_INI)
        self.assertEqual(cfg(["phoc", "--config=/x.ini"]), "/x.ini")
        self.assertEqual(cfg(["phoc", "--config", "/x.ini", "-C", "/y.ini"]), "/y.ini")
        # The session command is no -C, even when it looks like one.
        self.assertIsNone(cfg(["phoc", "-E", "-C", "/x.ini"]))
        self.assertIsNone(cfg(["phoc", "-S"]))
        self.assertIsNone(cfg(["phoc", "-C"]))
        self.assertIsNone(cfg([]))

    def test_good_session(self):
        ok, detail = self.judge(output([(1574, SESSION_ARGV, 412)]))
        self.assertTrue(ok, detail)
        self.assertIn("1574", detail)

    def test_alpha2_session(self):
        # Up to 0.1.0-alpha.2: Debian's settings, and phoc tried Xwayland.
        argv = [a if a != PHOC_INI else DEBIAN_INI for a in SESSION_ARGV]
        ok, detail = self.judge(output([(1574, argv, 412)], xwayland=2))
        self.assertFalse(ok)
        self.assertIn(DEBIAN_INI, detail)
        self.assertIn("Xwayland", detail)
        ok, detail = self.judge(output([(1574, SESSION_ARGV, 412)], xwayland=1))
        self.assertFalse(ok, detail)

    def test_no_log_proves_nothing(self):
        ok, detail = self.judge(output([(1574, SESSION_ARGV, 0)]))
        self.assertFalse(ok)
        self.assertIn("journal", detail)

    def test_every_session_phoc(self):
        ok, _ = self.judge(output([(1574, SESSION_ARGV, 412), (1600, ["/usr/bin/phoc", "-S"], 3)]))
        self.assertFalse(ok)

    def test_odd_output_fails_clearly(self):
        for o in ("xwayland 0\nend",                          # no session phoc
                  "pid 1574 \nlog 0\nxwayland 0\nend",        # it exited meanwhile
                  "pid 1574 !!notbase64\nlog 5\nxwayland 0\nend",
                  output([(1574, SESSION_ARGV, 412)]).rsplit("\n", 2)[0],  # cut short
                  "", "garbage"):
            ok, detail = self.judge(o)
            self.assertFalse(ok, o)
            self.assertTrue(detail, o)
        self.assertFalse(self.judge("", rc=None)[0])

    def test_reported_once(self):
        rep = self.vm.Report()
        seen = []
        self.vm.phoc_session_check(rep, lambda cmd, timeout=120: (seen.append(cmd), (0, output([(9, SESSION_ARGV, 1)])))[1])
        (name, ok, _, _), = rep.results
        self.assertTrue(ok)
        self.assertIn(PHOC_INI, name)
        # The session's phoc, not the greeter's (which runs as antumbra-greeter).
        self.assertIn("pgrep -u amnesia -x phoc", seen[0])

    @unittest.skipUnless(os.path.isdir("/proc/self") and shutil.which("base64"), "needs /proc and base64")
    def test_guest_command(self):
        """PHOC_SESSION itself, with stand-ins for pgrep and journalctl and a
        process whose command line holds the session's phoc arguments."""
        with tempfile.TemporaryDirectory() as d:
            journal = os.path.join(d, "journal")
            write(os.path.join(d, "bin", "pgrep"), "#!/bin/sh\necho \"$*\" > \"$STANDIN.pgrep\"\necho \"$STANDIN_PID\"\n", 0o755)
            write(os.path.join(d, "bin", "journalctl"),
                  "#!/bin/sh\ncase \"$*\" in *_PID=*) printf 'one\\ntwo\\n' ;; *) cat \"$JOURNAL\" ;; esac\n", 0o755)
            # sh -c 'sleep; :' stays the process (no exec), its arguments after the script.
            standin = subprocess.Popen(["sh", "-c", "sleep 60; :"] + SESSION_ARGV, start_new_session=True)
            try:
                env = {"PATH": os.path.join(d, "bin") + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
                       "STANDIN": os.path.join(d, "standin"), "STANDIN_PID": str(standin.pid), "JOURNAL": journal}
                for text, good in (("phoc[1574]: Output 'Virtual-1' added\n", True),
                                   ("phoc[1574]: \x1b[0;1;38:5:185mFailed to initialize Xwayland\x1b[0m\n", False)):
                    write(journal, text)
                    r = subprocess.run(["sh", "-c", self.vm.PHOC_SESSION], env=env, capture_output=True, text=True, timeout=30)
                    ok, detail = self.vm.judge_phoc_session(r.returncode, r.stdout)
                    self.assertEqual(ok, good, detail + r.stderr)
                    self.assertIn("2 journal lines" if good else "1 journal line", detail)
                with open(os.path.join(d, "standin.pgrep"), encoding="utf-8") as f:
                    self.assertEqual(f.read().split(), ["-u", "amnesia", "-x", "phoc"])
            finally:
                os.killpg(standin.pid, signal.SIGKILL)  # the sleep too
                standin.wait()


if __name__ == "__main__":
    unittest.main()
