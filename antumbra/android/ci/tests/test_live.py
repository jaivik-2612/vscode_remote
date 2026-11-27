# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for live.py, Antumbra Live's helper: the password check, the
tokens (and that the landing page computes the same ones, with node when it
is there), websockify's token file, the probe's verdicts, the End listener,
the page's state and the report, which must hold counts and leaks only.
With websockify installed (apt: websockify), the probe also runs against a
real websockify with the TokenFile plugin in front of a fake VNC server.
Nothing here touches the network.

Run: python3 -B -m unittest discover -s antumbra/android/ci/tests -p 'test_live.py' -v
"""

import hashlib
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.dont_write_bytecode = True
CI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, CI)

import live  # noqa: E402

PAGE = os.path.join(CI, "live", "index.html")
PHONE = os.path.join(CI, "live", "phone.html")
PW = "correct horse battery staple, test only"


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class TestPassword(unittest.TestCase):
    def test_secret_problem(self):
        self.assertIn("missing", live.secret_problem(""))
        self.assertIn("missing", live.secret_problem(" \n\t "))
        self.assertIn("shorter than 20", live.secret_problem("x" * 19))
        self.assertIn("shorter than 20", live.secret_problem("  " + "x" * 19 + "\n"))
        self.assertIsNone(live.secret_problem("x" * 20))
        # The message never holds the value.
        self.assertNotIn("abcdefghij", live.secret_problem("abcdefghij"))

    def test_secret_check_command(self):
        env = dict(os.environ, ANTUMBRA_LIVE_PASSWORD="short")
        r = subprocess.run([sys.executable, "-B", "-I", os.path.join(CI, "live.py"), "secret-check"],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertNotIn("short\n", r.stdout.replace("shorter", ""))
        env.pop("ANTUMBRA_LIVE_PASSWORD")
        r = subprocess.run([sys.executable, "-B", "-I", os.path.join(CI, "live.py"), "secret-check"],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing", r.stdout)
        env["ANTUMBRA_LIVE_PASSWORD"] = PW
        r = subprocess.run([sys.executable, "-B", "-I", os.path.join(CI, "live.py"), "secret-check"],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertNotIn(PW, r.stdout)

    def test_minutes(self):
        for given, want in (("", 60), ("abc", 60), ("5", 10), ("500", 180), ("45", 45), ("60.7", 60),
                            ("180", 180), (None, 60)):
            self.assertEqual(live.clamp_minutes(given), want, given)


class TestTokens(unittest.TestCase):
    def test_formula(self):
        # PBKDF2-HMAC-SHA-256, 600,000 rounds: a leaked token is slow to
        # guess the password from.
        self.assertEqual(live.TOKEN_ROUNDS, 600000)
        want = hashlib.pbkdf2_hmac("sha256", PW.encode(), b"antumbra-live\nabc-def.trycloudflare.com", 600000,
                                   32).hex()
        self.assertEqual(live.token("abc-def.trycloudflare.com", PW), want)
        end = hashlib.pbkdf2_hmac("sha256", PW.encode(), b"antumbra-live-end\nabc-def.trycloudflare.com", 600000,
                                  32).hex()
        self.assertEqual(live.token("abc-def.trycloudflare.com", PW, "end"), end)
        self.assertNotEqual(want, end)
        self.assertRegex(want, r"^[0-9a-f]{64}$")

    def test_normalisation(self):
        t = live.token("abc.trycloudflare.com", PW)
        self.assertEqual(live.token("ABC.trycloudflare.com", PW), t)
        self.assertEqual(live.token("abc.trycloudflare.com", "  " + PW + "\n"), t)
        # Another host (another session) gives another token.
        self.assertNotEqual(live.token("abd.trycloudflare.com", PW), t)
        # NFC: a decomposed é is the composed one.
        self.assertEqual(live.token("h", "café " + "x" * 20), live.token("h", "café " + "x" * 20))
        # Spaces inside count.
        self.assertNotEqual(live.token("h", "a b" + "x" * 20), live.token("h", "ab" + "x" * 20))

    def test_token_file_parses_as_websockify_does(self):
        text = live.token_file_text("h.example", PW, "127.0.0.1:5900", "127.0.0.1:5998")
        targets = {}
        for line in text.splitlines():
            tok, target = re.split(r":\s", line)  # websockify's ReadOnlyTokenFile
            targets[tok] = target.strip().rsplit(":", 1)
        self.assertEqual(targets[live.token("h.example", PW)], ["127.0.0.1", "5900"])
        self.assertEqual(targets[live.token("h.example", PW, "end")], ["127.0.0.1", "5998"])
        self.assertNotIn(PW, text)

    def test_token_command_writes_a_private_file_and_masks(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        path = os.path.join(d, "tokens")
        env = dict(os.environ, ANTUMBRA_LIVE_PASSWORD=PW)
        r = subprocess.run([sys.executable, "-B", "-I", os.path.join(CI, "live.py"), "token", "--host", "h.example",
                            "--tokens", path, "--mask"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(r.stdout.splitlines(), ["::add-mask::" + live.token("h.example", PW),
                                                 "::add-mask::" + live.token("h.example", PW, "end")])
        self.assertEqual([t for t, _ in live.read_tokens(path)],
                         [live.token("h.example", PW), live.token("h.example", PW, "end")])
        env["ANTUMBRA_LIVE_PASSWORD"] = "too short"
        r = subprocess.run([sys.executable, "-B", "-I", os.path.join(CI, "live.py"), "token", "--host", "h.example",
                            "--tokens", path], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1)

    @unittest.skipUnless(shutil.which("node"), "node is not installed")
    def test_the_page_computes_the_same_tokens(self):
        with open(PAGE, encoding="utf-8") as f:
            page = f.read()
        norm = re.search(r"function normalize\(pw\) \{.*?\}\n", page, re.S).group(0)
        tok = re.search(r"async function tokenFor\(label, pw\) \{.*?\n  \}\n", page, re.S).group(0)
        rounds = re.search(r"const ROUNDS = (\d+);", page).group(1)
        self.assertEqual(int(rounds), live.TOKEN_ROUNDS)
        pw = "  café über pass phrase, test\n"
        js = ("const host = 'abc-DEF.trycloudflare.com'.toLowerCase();\nconst ROUNDS = " + rounds + ";\n" +
              norm + tok +
              "Promise.all([tokenFor('antumbra-live', process.argv[1]), tokenFor('antumbra-live-end', "
              "process.argv[1])]).then((t) => console.log(t.join(' ')));")
        r = subprocess.run(["node", "-e", js, pw], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.split(), [live.token("abc-def.trycloudflare.com", pw),
                                            live.token("abc-def.trycloudflare.com", pw, "end")])

    def test_the_page_never_puts_the_token_in_an_address(self):
        with open(PAGE, encoding="utf-8") as f:
            page = f.read()
        # The phone's page is opened with no query: it takes the token from
        # this tab's sessionStorage. noVNC's own page (vnc.html) is never
        # used: it takes the server's host, port and path from its address.
        opener = re.search(r'location\.href = "([^"]*)"', page).group(1)
        self.assertEqual(opener, "phone.html")
        self.assertNotIn("vnc.html", page)
        self.assertNotIn('put("local", "path"', page)
        self.assertIn('put("session", KEY_TOKEN, screen)', page)
        self.assertIn('del("local", "path")', page)  # an older page's token is cleared
        for words in ("virtual phone on GitHub's computer", "ends by itself", "Never sign in to real accounts",
                      "personal details", "No sound and no camera"):
            self.assertIn(words, page)
        # End the session is always there, not only after unlocking.
        self.assertRegex(page, r'<button id="end" class="danger" type="button">')
        self.assertNotRegex(page, r'class="card hidden">\s*<button id="again"')

    def test_the_phone_page_connects_to_its_own_host_only(self):
        with open(PHONE, encoding="utf-8") as f:
            phone = f.read()
        script = phone[phone.index('<script type="module">'):]
        self.assertIn('location.host + "/websockify?token=" + tok', script)
        self.assertIn('stored("session", KEY_TOKEN)', script)
        # Nothing in its address steers it.
        for steer in ("location.search", "location.hash", "URLSearchParams", "getConfigVar", "localStorage.getItem"):
            self.assertNotIn(steer, script)
        # Only noVNC's core, not its app (ui.js reads settings from the address).
        self.assertEqual(sorted(set(re.findall(r'from "([^"]+)"', script))),
                         ["./core/input/keyboard.js", "./core/input/keysym.js", "./core/input/keysymdef.js",
                          "./core/rfb.js"])

    def test_the_web_root_has_no_novnc_page(self):
        with open(os.path.join(CI, "live-stream.sh"), encoding="utf-8") as f:
            sh = f.read()
        self.assertIn('cp -RL "$NOVNC/core" "$NOVNC/vendor" "$WEB/"', sh)
        self.assertNotIn('cp -RL "$NOVNC/."', sh)


class TestProbe(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        self.web = os.path.join(self.d, "web")
        os.mkdir(self.web)
        self.tokens = os.path.join(self.d, "tokens")
        live.write_private(self.tokens, live.token_file_text("h", PW, "127.0.0.1:5900", "127.0.0.1:5998"))
        self.right = live.token("h", PW)

    def get_ok(self, url, path):
        # The link reaches this web root: the file the probe put there.
        with open(os.path.join(self.web, path.lstrip("/")), encoding="utf-8") as f:
            return "ok", f.read()

    def fake(self, stranger="refused", owner="answered"):
        calls = []

        def probe_fn(url, tok):
            calls.append(tok)
            if tok == self.right:
                return owner, "RFB 003.008" if owner == "answered" else "x"
            return (stranger.pop(0) if isinstance(stranger, list) else stranger), "closed"
        return probe_fn, calls

    def run_probe(self, fn, get=None, **kw):
        return live.probe("https://h", self.tokens, web=self.web, probe_fn=fn, get_fn=get or self.get_ok,
                          sleep=lambda s: None, **kw)

    def test_all_good(self):
        fn, calls = self.fake()
        code, lines = self.run_probe(fn)
        self.assertEqual(code, live.PROBE_OK, lines)
        self.assertIsNone(calls[0])  # no token first
        self.assertNotIn(self.right, calls[1])  # a wrong one
        self.assertEqual(calls[2], self.right)
        self.assertNotIn(live.token("h", PW, "end"), calls)  # never the End token
        self.assertFalse(any(self.right in line for line in lines))
        self.assertEqual(os.listdir(self.web), [])  # the check's file is gone again

    def test_a_stranger_got_through(self):
        fn, _ = self.fake(stranger="answered")
        code, lines = self.run_probe(fn)
        self.assertEqual(code, live.PROBE_STRANGER_IN)
        self.assertTrue(any(line.startswith("FAIL") for line in lines))

    def test_the_owner_gets_nothing(self):
        fn, calls = self.fake(owner="refused")
        code, _ = self.run_probe(fn, tries=3)
        self.assertEqual(code, live.PROBE_NO_SCREEN)
        self.assertEqual(calls.count(self.right), 3)

    def test_strangers_without_an_answer_are_not_checked(self):
        # A link that never answers: the strangers were not refused, they
        # were never heard. The link must not be published.
        fn, calls = self.fake(stranger="error", owner="error")
        code, lines = self.run_probe(fn, tries=3)
        self.assertEqual(code, live.PROBE_UNCHECKED, lines)
        self.assertEqual(calls.count(None), 3)  # retried while the link is reached
        self.assertFalse(any(line.startswith("ok: with no password") for line in lines))

    def test_a_late_answer_counts(self):
        fn, _ = self.fake(stranger=["error", "refused", "error", "refused"])
        code, lines = self.run_probe(fn, tries=3)
        self.assertEqual(code, live.PROBE_OK, lines)

    def test_a_refusal_from_a_link_that_does_not_reach_us_proves_nothing(self):
        # A tunnel that is not up refuses everything (HTTP 530, 502): unless
        # the link brought back the file in this web root, a refusal is
        # not the screen's.
        fn, _ = self.fake(stranger="refused", owner="refused")
        code, lines = self.run_probe(fn, get=lambda url, path: ("refused", "HTTP 530"), tries=2)
        self.assertEqual(code, live.PROBE_UNCHECKED, lines)
        code, lines = self.run_probe(fn, get=lambda url, path: ("ok", "another page\n"), tries=2)
        self.assertEqual(code, live.PROBE_UNCHECKED, lines)
        code, lines = live.probe("https://h", self.tokens, probe_fn=fn, sleep=lambda s: None)
        self.assertEqual(code, live.PROBE_UNCHECKED, lines)

    def test_x11vnc_saw_a_stranger(self):
        log = os.path.join(self.d, "x11vnc.log")
        with open(log, "w") as f:
            f.write("14/10/2026 10:00:00 Got connection from client 127.0.0.1\n")

        def fn(url, tok):
            if tok != self.right:
                with open(log, "a") as f:
                    f.write("14/10/2026 10:00:01 Got connection from client 127.0.0.1\n")
                return "refused", "closed"
            return "answered", "RFB 003.008"
        code, lines = self.run_probe(fn, vnc_log=log)
        self.assertEqual(code, live.PROBE_STRANGER_IN, lines)


@unittest.skipUnless(shutil.which("websockify"), "websockify is not installed")
class TestProbeAgainstWebsockify(unittest.TestCase):
    """The production chain without X: websockify with the TokenFile plugin
    in front of a fake VNC server that greets and counts its clients."""

    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        self.vnc_port, self.ws_port, self.end_port = free_port(), free_port(), free_port()
        self.clients = 0
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", self.vnc_port))
        self.srv.listen(8)
        threading.Thread(target=self.serve, daemon=True).start()
        self.flag = os.path.join(self.d, "end-requested")
        threading.Thread(target=live.end_listener, args=(self.end_port, self.flag, True), daemon=True).start()
        self.host = "127.0.0.1:%d" % self.ws_port
        self.tokens = os.path.join(self.d, "tokens")
        live.write_private(self.tokens, live.token_file_text(
            self.host, PW, "127.0.0.1:%d" % self.vnc_port, "127.0.0.1:%d" % self.end_port))
        web = self.web = os.path.join(self.d, "web")
        os.mkdir(web)
        self.log = open(os.path.join(self.d, "websockify.log"), "w")
        self.p = subprocess.Popen(["websockify", "--web", web, "--token-plugin", "TokenFile", "--token-source",
                                   self.tokens, "127.0.0.1:%d" % self.ws_port],
                                  stdout=self.log, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop)
        end = time.time() + 15
        while time.time() < end:
            try:
                socket.create_connection(("127.0.0.1", self.ws_port), 1).close()
                break
            except OSError:
                time.sleep(0.2)

    def stop(self):
        self.p.terminate()
        self.p.wait(10)
        self.log.close()
        self.srv.close()

    def serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            self.clients += 1
            c.sendall(b"RFB 003.008\n")
            time.sleep(0.5)
            c.close()

    def test_strangers_get_nothing_and_the_owner_the_screen(self):
        url = "http://" + self.host
        self.assertEqual(live.ws_probe(url, None)[0], "refused")
        self.assertEqual(live.ws_probe(url, "0" * 64)[0], "refused")
        self.assertEqual(live.ws_probe(url, live.token("another-host", PW))[0], "refused")
        self.assertEqual(self.clients, 0)
        res, detail = live.ws_probe(url, live.token(self.host, PW))
        self.assertEqual((res, detail), ("answered", "RFB 003.008"))
        self.assertEqual(self.clients, 1)
        code, lines = live.probe(url, self.tokens, web=self.web, tries=1)
        self.assertEqual(code, live.PROBE_OK, lines)
        self.assertFalse(os.path.exists(self.flag))
        self.assertEqual(os.listdir(self.web), [])

    def test_nothing_listens_behind_the_link(self):
        # Strangers refused by a server that is not this one prove nothing.
        port = free_port()
        code, lines = live.probe("http://127.0.0.1:%d" % port, self.tokens, web=self.web, tries=2, wait=0.1)
        self.assertEqual(code, live.PROBE_UNCHECKED, lines)

    def test_the_end_token_ends_the_session(self):
        live.ws_probe("http://" + self.host, live.token(self.host, PW, "end"), timeout=3)
        end = time.time() + 5
        while time.time() < end and not os.path.exists(self.flag):
            time.sleep(0.1)
        self.assertTrue(os.path.exists(self.flag))
        self.assertEqual(self.clients, 0)


class TestState(unittest.TestCase):
    def test_state(self):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        st = live.write_state(d, start=1760000000, end=1760004800, minutes=60, sets=["state=starting"])
        self.assertEqual(st["start"], "2025-10-09T08:53:20Z")
        self.assertEqual(st["end"], "2025-10-09T10:13:20Z")
        st = live.write_state(d, sets=["state=ready"])
        self.assertEqual((st["state"], st["minutes"]), ("ready", 60))
        with open(os.path.join(d, "session.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["state"], "ready")
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(d, "session.json")).st_mode), 0o644)
        with self.assertRaises(ValueError):
            live.write_state(d, sets=["state=hacked"])
        with self.assertRaises(ValueError):
            live.write_state(d, sets=["password=x"])


ANALYSIS = {
    "verdict": "fail", "verdict_reasons": ["1 LEAK flow after the arm cutoff"],
    "phases": {"pre-arm": {"dns": 40}, "post-arm": {"tor-relay": 5000, "tor-directory": 20, "link-arp": 4, "dns": 2}},
    "post_arm_tor_packets": 5020,
    "leaks": [{"kind": "dns", "dst": "10.0.2.3", "dport": 53, "proto": "udp", "names": ["leaked.example"],
               "reason": "DNS outside Tor", "phases": {"post-arm": 2}}],
    "destinations": {"names": [{"name": "private-browsing.example"}, {"name": "f-droid.org"}],
                     "targets": [{"target": "203.0.113.9:443"}]},
}


class TestReport(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        s = os.path.join(self.root, "live")
        os.makedirs(s)
        with open(os.path.join(s, "analysis.json"), "w") as f:
            json.dump(ANALYSIS, f)
        with open(os.path.join(s, "checks.tsv"), "w") as f:
            f.write("adb_root\tok\t\nstore_fdroid\tok\tF-Droid installed before Start\n"
                    "wifi_default\tfail\tWi-Fi did not become the default network\n")
        with open(os.path.join(s, "events.tsv"), "w") as f:
            f.write("live_ready\t1760000600.5\t\nlive_started\t1760000700.1\ttor_mode=direct admin=1\n"
                    "live_end\t1760004000.0\tpage\n")
        with open(os.path.join(s, "result"), "w") as f:
            f.write("1\n")
        with open(os.path.join(s, "bridges.txt"), "w") as f:
            f.write("obfs4 192.0.2.1:443 SECRETBRIDGE cert=x iat-mode=0\n")

    def test_report(self):
        out = os.path.join(self.root, "out")
        md = live.report(self.root, out, run="7", build="15")
        self.assertIn("**Fail.**", md)
        self.assertIn("| Packets the phone sent after the firewall went on | 5,026 |", md)
        self.assertIn("| … to the Tor network | 5,020 |", md)
        self.assertIn("| Leaks (flows outside Tor) | 1 |", md)
        self.assertIn("2 names, 1 destinations", md)
        self.assertIn("10.0.2.3:53", md)
        self.assertIn("End session was pressed on the page", md)
        self.assertIn("tor_mode=direct admin=1", md)
        self.assertIn("1 failed", md)
        self.assertEqual(sorted(os.listdir(out)), ["checks.tsv", "report.json", "report.md"])
        # What the owner did is not in the public report.
        for f in os.listdir(out):
            with open(os.path.join(out, f), encoding="utf-8") as g:
                text = g.read()
            self.assertNotIn("private-browsing.example", text, f)
            self.assertNotIn("203.0.113.9", text, f)
            self.assertNotIn("SECRETBRIDGE", text, f)
            self.assertNotIn("leaked.example", text, f)
        with open(os.path.join(out, "report.json"), encoding="utf-8") as f:
            res = json.load(f)
        self.assertEqual(res["leak"]["packets_after_arm"], 5026)
        self.assertEqual(res["session"]["end_reason"], "page")

    def test_no_bridge_or_relay_address_in_public(self):
        # The owner's bridges: tor's connections at the end, named by the
        # leak analyser when the capture misses one, or a "leak" when the
        # bridge list could not be read.
        s = os.path.join(self.root, "live")
        with open(os.path.join(s, "tor-connections.txt"), "w") as f:
            f.write("85.10.20.30:9001\n[2a01:4f8:c010:1::1]:443\n")
        a = dict(ANALYSIS, verdict="blind", verdict_reasons=[
            "1 flow(s) after arm are LEAKs (2 packets)",
            "the capture misses 2 of tor's 2 connections (85.10.20.30:9001, 2a01:4f8:c010:1::1:443): it does not "
            "see every path out of the phone",
            "the device had address(es) the capture never saw sending on their interface (wlan0 10.0.2.16): x"])
        a["leaks"] = list(ANALYSIS["leaks"]) + [{
            "kind": "other", "dst": "85.10.20.30", "dport": 9001, "proto": "tcp", "names": [],
            "reason": "TCP to 85.10.20.30:9001, not a Tor relay", "phases": {"post-arm": 40}}]
        with open(os.path.join(s, "analysis.json"), "w") as f:
            json.dump(a, f)
        with open(os.path.join(s, "checks.tsv"), "a") as f:
            f.write("tor_note\twarn\tconnected to 85.10.20.30:9001 and 10.0.2.2\n")
        out = os.path.join(self.root, "out")
        md = live.report(self.root, out)
        for f in os.listdir(out):
            with open(os.path.join(out, f), encoding="utf-8") as g:
                text = g.read()
            self.assertNotIn("85.10.20.30", text, f)
            self.assertNotIn("2a01:4f8", text, f)
        self.assertIn("(addresses not shown)", md)
        self.assertIn("wlan0 10.0.2.16", md)  # the phone's own address stays
        self.assertIn("10.0.2.3:53", md)  # a real leak keeps its destination
        self.assertIn("one of tor's own connections or bridges (address not shown)", md)
        self.assertIn("10.0.2.2", md)
        self.assertEqual(live.redact("8.8.8.8:53 and 192.168.232.2 and fe80::1"),
                         "<address not shown> and 192.168.232.2 and fe80::1")

    def test_without_an_analysis(self):
        os.remove(os.path.join(self.root, "live", "analysis.json"))
        md = live.report(self.root, os.path.join(self.root, "out"))
        self.assertIn("**Not judged.**", md)
        self.assertIn("| Leaks (flows outside Tor) | – |", md)

    def test_pass(self):
        a = dict(ANALYSIS, verdict="pass", verdict_reasons=[], leaks=[])
        with open(os.path.join(self.root, "live", "analysis.json"), "w") as f:
            json.dump(a, f)
        md = live.report(self.root, os.path.join(self.root, "out"))
        self.assertIn("**Pass.**", md)
        self.assertIn("| Leaks (flows outside Tor) | 0 |", md)
        self.assertNotIn("Leaks:", md)


class TestAnalyse(unittest.TestCase):
    """analyse.sh judges the live scenario by the app lab's rules, next to
    the app lab's own (synthetic captures from test_ci)."""

    def test_live_and_apps(self):
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import test_ci as t  # noqa: E402  the leak analyser's frame builders
        root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, root)
        out, cap = os.path.join(root, "report"), os.path.join(root, "capture")
        os.makedirs(cap)
        for s, leak in (("apps", False), ("live", True)):
            os.makedirs(os.path.join(out, s))
            with open(os.path.join(out, s, "events.tsv"), "w") as f:
                f.write(t.events_text())
            with open(os.path.join(out, s, "consensus"), "w") as f:
                f.write(t.CONSENSUS)
            frames = t.base_frames()
            if leak:  # a lookup to the network's resolver after arm
                frames.append((1040.0, t.out4("10.0.2.3", t.udp(40020, 53, t.dns_query("leaked.example")), 17)))
            t.write_pcap(os.path.join(cap, s + ".pcap"), frames)
        env = dict(os.environ, ANTUMBRA_CI_OUT=out, ANTUMBRA_CAPTURE_DIR=cap)
        env.pop("ANTUMBRA_MODULE_TREE", None)
        r = subprocess.run(["bash", os.path.join(CI, "analyse.sh")], env=env, capture_output=True, text=True,
                           timeout=300)
        self.assertEqual(r.returncode, 0, r.stderr)
        verdicts = {}
        for s in ("apps", "live"):
            with open(os.path.join(out, s, "analysis.json"), encoding="utf-8") as f:
                a = json.load(f)
            self.assertEqual(a["scenario"], s)
            verdicts[s] = (a["verdict"], len(a.get("leaks") or []))
            self.assertTrue(os.path.exists(os.path.join(out, s, "consensus.gz")))
        self.assertEqual(verdicts["live"][1], verdicts["apps"][1] + 1, verdicts)
        self.assertEqual(verdicts["live"][0], "fail")
        md = live.report(out, os.path.join(root, "live-report"))
        self.assertIn("**Fail.**", md)
        self.assertIn("10.0.2.3:53", md)


if __name__ == "__main__":
    unittest.main()
