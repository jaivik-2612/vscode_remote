# SPDX-License-Identifier: GPL-3.0-or-later
"""The file indexer stays off (runs on the build host).

config/hooks/52-session-enable.sh masks localsearch's user units and
tinysparql's portal in the user scope, and the VM harness checks the result
in the session (indexer_check). The two lists must agree, and the hook's
systemctl commands must do what they say on a tree that has those units.
"""
import importlib.util
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
HOOK = os.path.join(ROOT, "config", "hooks", "52-session-enable.sh")
HARNESS = os.path.join(ROOT, "tests", "vm", "antumbra_vm.py")


def load_harness():
    spec = importlib.util.spec_from_file_location("antumbra_vm", HARNESS)
    vm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vm)
    return vm


def hook_commands():
    """The hook's `systemctl --global VERB UNIT...` commands, as argument lists."""
    with open(HOOK, encoding="utf-8") as f:
        text = f.read().replace("\\\n", " ")
    return [line.split()[2:] for line in text.splitlines() if line.startswith("systemctl --global ")]


class HookTest(unittest.TestCase):
    def setUp(self):
        self.units = load_harness().INDEXER_UNITS

    def test_masks_what_the_harness_checks(self):
        masked = {u for cmd in hook_commands() if cmd[0] == "mask" for u in cmd[1:]}
        self.assertEqual(masked, set(self.units))

    def test_takes_the_indexer_out_of_gnome_session(self):
        self.assertIn(["disable", "localsearch-3.service"], hook_commands())

    @unittest.skipUnless(shutil.which("systemctl"), "needs systemctl")
    def test_commands_on_a_tree_with_the_units(self):
        with tempfile.TemporaryDirectory() as root:
            user = os.path.join(root, "usr", "lib", "systemd", "user")
            os.makedirs(user)
            for unit in self.units:
                with open(os.path.join(user, unit), "w", encoding="utf-8") as f:
                    f.write("[Unit]\nDescription=stand-in\n\n[Service]\nExecStart=/bin/true\n")
            # As tracker-extract installs it: wanted by gnome-session.target.
            with open(os.path.join(user, "localsearch-3.service"), "a", encoding="utf-8") as f:
                f.write("\n[Install]\nWantedBy=gnome-session.target\n")
            wants = os.path.join(root, "etc", "systemd", "user", "gnome-session.target.wants")
            os.makedirs(wants)
            os.symlink("/usr/lib/systemd/user/localsearch-3.service", os.path.join(wants, "localsearch-3.service"))
            for cmd in hook_commands():
                subprocess.run(["systemctl", "--root", root, "--global"] + cmd, check=True, capture_output=True)
            for unit in self.units:
                self.assertEqual(os.readlink(os.path.join(root, "etc", "systemd", "user", unit)), "/dev/null", unit)
            self.assertFalse(os.path.lexists(os.path.join(wants, "localsearch-3.service")))


class HarnessCheckTest(unittest.TestCase):
    def verdict(self, output):
        vm = load_harness()
        rep = vm.Report()
        vm.indexer_check(rep, lambda cmd, timeout=120: (0, output))
        (_, ok, _, _), = rep.results
        return ok

    def test_off(self):
        self.assertTrue(self.verdict("masked\nmasked\nmasked\nmasked\nrefused\ninactive\n0\n"))

    def test_not_masked_activated_or_running(self):
        self.assertFalse(self.verdict("enabled\nstatic\nstatic\nstatic\nrefused\ninactive\n0"))
        self.assertFalse(self.verdict("masked\nmasked\nmasked\nmasked\nanswered\nactive\n1"))
        self.assertFalse(self.verdict("masked\nmasked\nmasked\nmasked\nrefused\ninactive\n1"))

    def test_no_console(self):
        vm = load_harness()
        rep = vm.Report()
        vm.indexer_check(rep, lambda cmd, timeout=120: (None, ""))
        self.assertFalse(rep.results[0][1])


if __name__ == "__main__":
    unittest.main()
