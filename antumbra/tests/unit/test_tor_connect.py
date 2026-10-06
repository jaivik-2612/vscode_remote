# SPDX-License-Identifier: GPL-3.0-or-later
"""antumbra-tor-connect against a fake Tor controller: settings are applied
with SETCONF and never saved with SAVECONF, which Tor cannot do here (it
cannot write /etc/tor) and which made every 'direct' and 'bridges' exit
with an error after the settings had taken effect. Every bridge transport
it accepts has a pluggable transport in Tor's configuration
(tor-pt-configuration-helper), and snowflake, which the firewall cannot
carry, is refused saying why."""
import importlib.machinery
import importlib.util
import io
import os
import re
import sys
import types
import unittest
from unittest import mock

HERE = os.path.dirname(__file__)
ROOTFS = os.path.join(HERE, "..", "..", "config", "rootfs")
SCRIPT = os.path.join(ROOTFS, "usr", "local", "sbin", "antumbra-tor-connect")
HELPER = os.path.join(ROOTFS, "usr", "local", "lib", "tor-pt-configuration-helper")
NFTABLES = os.path.join(ROOTFS, "etc", "nftables.conf")
TOR_BROWSER_HOOK = os.path.join(HERE, "..", "..", "config", "hooks", "54-session-tor-browser.sh")
sys.path.insert(0, os.path.join(ROOTFS, "usr", "lib", "python3", "dist-packages"))
from antumbra import settings as S  # noqa: E402

OBFS4 = "obfs4 192.0.2.1:443 0123456789ABCDEF0123456789ABCDEF01234567 cert=x iat-mode=0"
EXAMPLES = {
    "obfs2": "obfs2 192.0.2.4:443 0123456789ABCDEF0123456789ABCDEF01234567",
    "obfs3": "obfs3 192.0.2.5:443 0123456789ABCDEF0123456789ABCDEF01234567",
    "obfs4": OBFS4,
    "webtunnel": "webtunnel [2001:db8::1]:443 0123456789ABCDEF0123456789ABCDEF01234567 url=https://example.org/p ver=0.0.1",
    "meek_lite": "meek_lite 192.0.2.18:80 BE776A53492E1E044A26F17306E1BC46A55A1625 url=https://meek.example.net/ front=ajax.example.com",
}
SNOWFLAKE = ("snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 "
             "url=https://snowflake-broker.torproject.net/ ice=stun:stun.l.google.com:19302")


def helper_plugin():
    """The ClientTransportPlugin line tor-pt-configuration-helper gives Tor:
    its transports and the program that runs them."""
    with open(HELPER, encoding="utf-8") as f:
        found = re.findall(r"ClientTransportPlugin\s*\\\s*'(\S+) exec (\S+)", f.read())
    assert len(found) == 1, found
    return found[0][0].split(","), found[0][1]


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
        calls, run = self.run_main(["antumbra-tor-connect", "bridges", "-"], f"Bridge {OBFS4}\n")
        sets = [c for c in calls if c[0] == "set_options"]
        self.assertEqual(len(sets), 1)
        self.assertEqual(sets[0][1]["UseBridges"], "1")
        self.assertEqual(sets[0][1]["Bridge"], [OBFS4])
        self.assertNotIn(("save_conf",), calls)
        self.assertEqual(run.call_args.args[0][1:], ["0"])  # obfs4 needs the sandbox off

    def bridges(self, stdin):
        calls, run = self.run_main(["antumbra-tor-connect", "bridges", "-"], stdin)
        sets = [c[1] for c in calls if c[0] == "set_options"]
        self.assertEqual(len(sets), 1)
        return sets[0]["Bridge"], run.call_args.args[0][1:]

    def test_transports_are_those_tor_has_a_plugin_for(self):
        # Every transport accepted has a pluggable transport in Tor's
        # configuration, and every one there is accepted.
        transports, program = helper_plugin()
        mod = load([])
        self.assertEqual(sorted(mod.TRANSPORTS), sorted(transports))
        self.assertEqual(sorted(EXAMPLES), sorted(transports))
        # ... run by lyrebird from Tor Browser, which has them all
        self.assertEqual(program, "/usr/bin/obfs4proxy")
        with open(TOR_BROWSER_HOOK, encoding="utf-8") as f:
            self.assertIn('install -m 0755 "${PT}/lyrebird" /usr/bin/obfs4proxy', f.read())
        for kind, line in EXAMPLES.items():
            with self.subTest(kind):
                self.assertEqual(self.bridges(line + "\n"), ([line], ["0"]))  # the transport needs the sandbox off

    def test_plain_bridges_keep_the_sandbox(self):
        line = "192.0.2.7:9001 0123456789ABCDEF0123456789ABCDEF01234567"
        self.assertEqual(self.bridges(f"Bridge {line}\n"), ([line], ["1"]))

    def test_the_dispatchers_lines(self):
        # What the NetworkManager dispatcher pipes in: the Welcome screen's
        # setting split at ';', a "Bridge" prefix and comments allowed.
        lines, sandbox = self.bridges(f"# from bridges.torproject.org\nBridge {OBFS4}\n\n {EXAMPLES['webtunnel']} \n")
        self.assertEqual(lines, [OBFS4, EXAMPLES["webtunnel"]])
        self.assertEqual(sandbox, ["0"])

    def refused(self, stdin):
        calls = []
        mod = load(calls)
        with mock.patch.object(mod.subprocess, "run") as run, mock.patch.object(sys, "stdin", io.StringIO(stdin)), \
                mock.patch.object(sys, "stdout", io.StringIO()), self.assertRaises(SystemExit) as cm:
            mod.main(["antumbra-tor-connect", "bridges", "-"])
        self.assertEqual(calls, [])     # Tor is left as it was
        run.assert_not_called()         # and so is its sandbox
        return cm.exception.code

    def test_snowflake_is_refused_saying_why(self):
        self.assertEqual(self.refused(f"{OBFS4}\nBridge {SNOWFLAKE}\n"), S.SNOWFLAKE_REFUSED)
        self.assertIn("UDP", S.SNOWFLAKE_REFUSED)

    def test_snowflake_refusal_matches_the_firewall(self):
        # The reason given holds while Tor's user may make only TCP
        # connections and DNS queries: snowflake's WebRTC is UDP.
        with open(NFTABLES, encoding="utf-8") as f:
            rules = [l.strip() for l in f if 'skuid "debian-tor"' in l]
        self.assertEqual(rules, [
            'meta skuid "debian-tor" meta nfproto ipv4 tcp flags & (fin|syn|rst|ack) == syn ct state new accept',
            'meta skuid "debian-tor" meta nfproto ipv4 udp dport 53 accept'])

    def test_unknown_transports_are_refused(self):
        msg = self.refused("conjure 192.0.2.9:80 0123456789ABCDEF0123456789ABCDEF01234567\n")
        self.assertTrue(msg.startswith("Unsupported bridge type: conjure."), msg)

    def test_no_bridge_lines(self):
        self.assertEqual(self.refused("# nothing\n\n"), "no bridge lines given")

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
