# SPDX-License-Identifier: GPL-3.0-or-later
"""antumbra-tor-connect against a fake Tor controller: settings are applied
with SETCONF and never saved with SAVECONF, which Tor cannot do here (it
cannot write /etc/tor) and which made every 'direct' and 'bridges' exit
with an error after the settings had taken effect."""
import importlib.machinery
import importlib.util
import io
import os
import sys
import types
import unittest
from unittest import mock

SCRIPT = os.path.join(os.path.dirname(__file__), "..", "..", "config", "rootfs", "usr", "local", "sbin", "antumbra-tor-connect")


class FakeController:
    def __init__(self, calls):
        self.calls = calls

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def authenticate(self):
        self.calls.append(("authenticate",))

    def set_options(self, opts):
        self.calls.append(("set_options", opts))

    def save_conf(self):
        self.calls.append(("save_conf",))
        raise RuntimeError("Unable to write configuration to disk.")


def load(calls):
    stem = types.ModuleType("stem")
    connection = types.ModuleType("stem.connection")
    connection.connect = lambda control_port: FakeController(calls)
    control = types.ModuleType("stem.control")
    stem.connection, stem.control = connection, control
    with mock.patch.dict(sys.modules, {"stem": stem, "stem.connection": connection, "stem.control": control}):
        loader = importlib.machinery.SourceFileLoader("antumbra_tor_connect", SCRIPT)
        spec = importlib.util.spec_from_loader("antumbra_tor_connect", loader)
        mod = importlib.util.module_from_spec(spec)
        loader.exec_module(mod)
    return mod


class TorConnectTest(unittest.TestCase):
    def run_main(self, argv, stdin=""):
        calls = []
        mod = load(calls)
        with mock.patch.object(mod.subprocess, "run") as run, mock.patch.object(sys, "stdin", io.StringIO(stdin)), \
                mock.patch.object(sys, "stdout", io.StringIO()):
            mod.main(argv)
        return calls, run

    def test_direct_sets_options_without_saving(self):
        calls, run = self.run_main(["antumbra-tor-connect", "direct"])
        self.assertIn(("set_options", {"UseBridges": "0", "Bridge": [], "DisableNetwork": "0"}), calls)
        self.assertNotIn(("save_conf",), calls)
        self.assertEqual(run.call_args.args[0][1:], ["1"])  # the sandbox stays on without transports

    def test_bridges_sets_options_without_saving(self):
        calls, run = self.run_main(["antumbra-tor-connect", "bridges", "-"],
                                   "Bridge obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0\n")
        sets = [c for c in calls if c[0] == "set_options"]
        self.assertEqual(len(sets), 1)
        self.assertEqual(sets[0][1]["UseBridges"], "1")
        self.assertEqual(sets[0][1]["Bridge"], ["obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0"])
        self.assertNotIn(("save_conf",), calls)
        self.assertEqual(run.call_args.args[0][1:], ["0"])  # obfs4 needs the sandbox off

    def test_a_refused_setting_still_fails(self):
        calls = []
        mod = load(calls)

        class Refusing(FakeController):
            def set_options(self, opts):
                raise RuntimeError("Failed to bind one of the listener ports.")

        mod.stem.connection.connect = lambda control_port: Refusing(calls)
        with mock.patch.object(mod.subprocess, "run"), self.assertRaises(RuntimeError):
            mod.main(["antumbra-tor-connect", "direct"])


if __name__ == "__main__":
    unittest.main()
