# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for daily.py, the Antumbra Daily page built from an emulator
run's artifact. Every artifact here is synthetic: a few JSON and TSV files
and tiny PNGs written by a minimal PNG writer. The tests that compare or
embed screenshots need ImageMagick's convert and are skipped without it.

Run: python3 -B -m unittest discover -s antumbra/android/ci/tests -v
"""

import contextlib
import io
import json
import os
import re
import shutil
import struct
import sys
import tempfile
import unittest
import zlib

sys.dont_write_bytecode = True
CI = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, CI)

import daily  # noqa: E402

HAVE_CONVERT = all(shutil.which(t) for t in ("convert", "compare", "identify"))
SCREEN_IDS = ["welcome-1", "welcome-2-choices", "status-1-started", "status-2-bootstrapped",
              "status-3-after-tracker-test", "baseline-home"]
SHA = "500c3697e8f4d88d3abbfe28bb390f9ae879497b"


def png(path, w=90, h=200, rgb=(30, 28, 40), box=None, box_rgb=(240, 240, 240)):
    """A w x h RGB PNG of one colour, with an optional rectangle (x0, y0, x1, y1)."""
    rows = []
    for y in range(h):
        row = bytearray(b"\x00")
        for x in range(w):
            inside = box and box[0] <= x < box[2] and box[1] <= y < box[3]
            row += bytes(box_rgb if inside else rgb)
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text if isinstance(text, str) else json.dumps(text))


CHECKS_OK = [("adb_root", "ok", ""), ("module_install", "ok", "state=live"),
             ("wifi_mac_new", "warn", "wlan0 02:15:b2:00:00:00 before the module, 02:15:b2:00:00:00 now"),
             ("tracker_blocked:doubleclick.net", "ok", "the filter answered NXDOMAIN"),
             ("control_resolves:check.torproject.org", "warn",
              'no answer through Tor: {"answers": [], "rcode": "SERVFAIL", "type": "A"}')]


ARMED_OK = {"status": "ok", "seconds": 30.2, "packets": 0, "allowed": 0, "leaks": 0}


def make_run(root, state="pass", run=8, after_arm=(6811, 10, 2, 1), leaks=0, tor_start=100.0, tor_done=129.5,
             queries=14, blocked=5, list_size=196268, list_version="20261011", module_zip=14102690,
             screens=True, shot_box=None, checks=None, problems=None, armed=None, analysis_verdict=None,
             post_arm=True):
    """A synthetic antumbra-android-<run> artifact in root."""
    relay, directory, dhcp, arp = after_arm
    post = {"tor-relay": relay, "tor-directory": directory, "lan-dhcp": dhcp, "link-arp": arp}
    leak_flows = []
    if leaks:
        post["LEAK"] = leaks
        leak_flows = [{"class": "LEAK", "kind": "dns", "dst": "10.0.2.3", "dport": 53, "l3": "ipv4",
                       "phases": {"post-arm": leaks}, "reason": "a name lookup outside Tor"}]
    verdict = analysis_verdict or {"pass": "pass", "fail": "fail", "blind": "blind"}[state]
    if problems is None:
        problems = {"pass": [],
                    "fail": ["leak test: FAIL: 1 flow(s) after arm are LEAKs (%d packets)" % leaks],
                    "blind": ["leak test: BLIND (capture incomplete): the last frame of antumbra.pcap is 321 s "
                              "before the scenario stopped the capture: frames at the end may be missing"]}[state]
    write(os.path.join(root, "verdict.json"), {
        "ok": state == "pass", "problems": problems,
        "warnings": ["antumbra: wifi_mac_new: wlan0 same",
                     "through Tor, not on the expected list: name www.gstatic.com"]})
    write(os.path.join(root, "leak-report.json"), {"schema": 2, "scenarios": {
        "antumbra": {"verdict": verdict,
                     "phases": dict({"pre-arm": {"LEAK": 120}}, **({"post-arm": post} if post_arm else {})),
                     "post_arm_tor_packets": relay + directory if post_arm else 0, "leaks": leak_flows,
                     "armed_window": armed if armed is not None else ARMED_OK},
        "baseline": {"verdict": "info", "totals": {"outbound": 83},
                     "events": [{"name": "boot_completed", "t": 10.1}, {"name": "clock_marker_after", "t": 20.8},
                                {"name": "wait_over", "t": 200.9}, {"name": "capture_stop", "t": 208.1}],
                     "flows": [{"class": "LEAK", "kind": "tcp", "proto": "tcp", "dst": "173.194.42.94", "dport": 443,
                                "l3": "ipv4", "packets": 36, "names": ["www.gstatic.com"]},
                               {"class": "LEAK", "kind": "ipv6", "proto": "udp", "dst": "ff02::fb", "dport": 5353,
                                "l3": "ipv6", "packets": 41, "names": []},
                               {"class": "link-arp", "proto": "arp", "dst": "10.0.2.2", "packets": 3, "names": []},
                               {"class": "ci-marker", "proto": "udp", "dst": "10.0.2.2", "dport": 9, "packets": 3}],
                     "dns_names": [{"name": "www.gstatic.com", "phase": "baseline", "queries": 4}]}}})
    for s in ("antumbra", "baseline"):
        write(os.path.join(root, s, "result"), "0\n" if state != "fail" else ("1\n" if s == "antumbra" else "0\n"))
    cs = checks if checks is not None else CHECKS_OK
    write(os.path.join(root, "antumbra", "checks.tsv"), "".join("%s\t%s\t%s\n" % c for c in cs))
    write(os.path.join(root, "baseline", "checks.tsv"), "system_ready\tok\t\nguest_capture\tok\tpid 1\n")
    write(os.path.join(root, "antumbra", "events.tsv"),
          "clock_marker_after\t50.0\t\nwelcome_start\t%s\t\ntor_bootstrapped\t%s\t10 s, from /status\n" % (
              tor_start, tor_done))
    write(os.path.join(root, "baseline", "events.tsv"), "clock_marker_after\t10.0\t\nwait_over\t190.0\t\n")
    write(os.path.join(root, "antumbra", "filter-status.json"), {
        "version": "ci.%d" % run, "queries": queries, "blocked": blocked,
        "list": {"version": list_version, "size": list_size}})
    write(os.path.join(root, "build", "module.md"),
          "### module\n\n- antumbra-module-0.1.0.zip: %d bytes, sha256 `cfcc`.\n" % module_zip)
    write(os.path.join(root, "build", "welcome.md"), "### welcome\n\n- app-debug.apk: 29253473 bytes, sha256 `69`.\n")
    write(os.path.join(root, "build", "tor.md"), "### tor\n\n- tor 0.4.9.14, from the cache.\n"
          "- arm64-v8a: 8065208 bytes, sha256 `49`\n- x86_64: 8537440 bytes, sha256 `98`\n")
    if screens:
        os.makedirs(os.path.join(root, "screenshots"), exist_ok=True)
        for name in ("antumbra-welcome-1", "antumbra-welcome-2-choices", "antumbra-status-1-started",
                     "antumbra-status-2-bootstrapped", "antumbra-status-3-after-tracker-test", "baseline-home"):
            png(os.path.join(root, "screenshots", name + ".png"),
                box=shot_box if name == "antumbra-welcome-2-choices" else None)
    return root


class DailyTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = self._tmp.name

    def tearDown(self):
        self._tmp.cleanup()

    def path(self, *p):
        return os.path.join(self.tmp, *p)

    def build(self, run, *extra, out="page.html"):
        argv = ["--run", run, "--out", self.path(out), "--date", "2026-10-11T06:45Z"] + list(extra)
        with contextlib.redirect_stdout(io.StringIO()):
            daily.main(argv)
        with open(self.path(out), encoding="utf-8") as f:
            return f.read()

    def script(self, page):
        return page[page.index("<script>"):]

    # --- The header ---

    def test_pass_header(self):
        page = self.build(make_run(self.path("r8")), "--run-number", "8", "--sha", SHA, "--subject", "One change",
                          "--run-url", "https://github.com/o/r/actions/runs/1")
        self.assertIn("Antumbra Daily · Sun 11 Oct 2026, 06:45 UTC", page)
        self.assertIn("<h1>Test run 8</h1>", page)
        self.assertIn('<span class="result ok">Leak test passed</span>', page)
        self.assertIn("5 of 7 checks passed · 2 with a warning · none failed", page)
        self.assertIn("Change tested: <strong>One change</strong>", page)
        self.assertIn("(500c369)", page)
        self.assertIn("virtual Android 16 phone", page)
        self.assertIn('href="https://github.com/o/r/actions/runs/1"', page)
        self.assertNotIn('class="callout', page)
        self.assertIn('"sha": "500c3697e8f4"', self.script(page))  # undo/<first 12 hex digits>

    def test_fail_header(self):
        cs = CHECKS_OK + [("ipv6_off", "fail", "fe80::1 on wlan0")]
        page = self.build(make_run(self.path("r"), state="fail", leaks=3, checks=cs), "--run-number", "9")
        self.assertIn('<span class="result bad">Test failed</span>', page)
        self.assertIn('class="callout bad"', page)
        self.assertIn("The leak test failed: 1 flow(s) after arm are LEAKs (3 packets)", page)
        self.assertIn("1 leak</strong> (3 packets)", page)
        self.assertIn("10.<wbr>0.<wbr>2.<wbr>3:<wbr>53", page)
        self.assertIn("<td>a name lookup outside Tor</td>", page)   # the leak's kind, in words
        self.assertIn("1 failed", page)
        # The failure is listed before the warnings, each saying what was
        # found rather than what was expected, with its detail.
        look = page[page.index('<ul class="look">'):page.index("</ul>", page.index('<ul class="look">'))]
        self.assertLess(look.index("IPv6 is not off"), look.index("The Wi-Fi hardware address did not change"))
        self.assertIn("No answer through Tor for an ordinary name: check.torproject.org", look)
        self.assertNotIn("A new Wi-Fi hardware address", look)
        self.assertIn("fe80::1 on wlan0", look)

    def test_blind_header(self):
        page = self.build(make_run(self.path("r"), state="blind"), "--run-number", "7")
        self.assertIn('<span class="result warn">Could not judge</span>', page)
        self.assertIn('class="callout warn"', page)
        self.assertIn("The test could not judge this run", page)
        self.assertIn("has nothing in its last 321 s", page)
        self.assertIn("The leak test could not judge: the last frame of antumbra.pcap", page)

    def test_state_rules(self):
        checks = {"antumbra": [("a", "ok", "")], "baseline": []}
        ran = {"antumbra": "0", "baseline": "0"}
        self.assertEqual(daily.state_of(True, [], "pass", checks, ran), "pass")
        self.assertEqual(daily.state_of(False, ["x"], "blind", checks, ran), "blind")
        self.assertEqual(daily.state_of(False, ["x"], "fail", checks, ran), "fail")
        self.assertEqual(daily.state_of(False, ["x"], "blind", {"antumbra": [("a", "fail", "")]}, ran), "fail")
        self.assertEqual(daily.state_of(False, ["x"], None, checks, {"antumbra": "1", "baseline": "0"}), "fail")
        self.assertEqual(daily.state_of(False, ["x"], None, checks, {"antumbra": None, "baseline": None}), "blind")

    def test_page_shape(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8")
        self.assertTrue(page.startswith("<title>Antumbra Daily</title>\n<style>"))
        self.assertNotRegex(page.lower(), r"<!doctype|</?(html|head|body)[\s>]")
        self.assertEqual(page.count("<script>"), 1)
        self.assertEqual(page.count("</script>"), 1)
        self.assertTrue(page.rstrip().endswith("</script>"))
        for needed in ('id="history"', 'id="history-rows"', 'id="ctl-off"', 'id="ctl-row"', 'id="undo"',
                       'id="pause"', 'id="stop"', 'id="ctl-saved"', 'id="photo-box"', 'id="photo"',
                       'id="photo-note"', 'id="photo-send"', 'id="photo-saved"', 'id="photos"',
                       '"feedback/" + RUN.run + "_" + name', '"controls/state"', '"undo/" + RUN.sha',
                       '"answers/" + RUN.question.id', 'collection("photos")', 'collection("metrics")'):
            self.assertIn(needed, page)
        self.assertIn(':root:not([data-theme="light"])', page)
        self.assertIn(':root[data-theme="dark"]', page)
        self.assertNotRegex(page, r"\b(alert|confirm|prompt)\(")
        self.assertNotRegex(page, r"(src|href)=\"(https?:)?//(?!github\.com)")

    def test_data_screen_ids(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8")
        ids = re.findall(r'data-screen="([^"]+)"', page)
        self.assertEqual(ids, SCREEN_IDS)
        for sid in SCREEN_IDS:
            self.assertIn('id="note-%s"' % sid, page)
        self.assertEqual(page.count('data-v="right">Looks right'), 6)
        self.assertEqual(page.count('data-v="off">Looks off'), 6)
        self.assertIn('"screens": ["welcome-1", "welcome-2-choices"', self.script(page))

    def test_other_screenshot_follows(self):
        run = make_run(self.path("r"))
        png(os.path.join(run, "screenshots", "antumbra-final.png"))
        os.remove(os.path.join(run, "screenshots", "antumbra-status-3-after-tracker-test.png"))
        page = self.build(run, "--run-number", "8")
        ids = re.findall(r'data-screen="([^"]+)"', page)
        self.assertEqual(ids[-1], "final")
        self.assertNotIn("status-3-after-tracker-test", ids)
        self.assertIn("Not taken in this run: After the tracker test.", page)

    # --- Missing files ---

    def test_empty_artifact(self):
        os.makedirs(self.path("empty"))
        page = self.build(self.path("empty"), "--run-number", "3", "--metrics-out", self.path("m.json"))
        self.assertIn('<span class="result warn">Could not judge</span>', page)
        self.assertIn("No checks were recorded.", page)
        self.assertIn("There is no leak analysis in this run", page)
        self.assertIn("No screenshots in this run.", page)
        self.assertIn("The artifact has no verdict.json", page)
        self.assertIn('<td class="num">–</td>', page)
        with open(self.path("m.json"), encoding="utf-8") as f:
            m = json.load(f)
        self.assertEqual(m["verdict"], "blind")
        for k in ("tor_bootstrap_s", "packets_after_arm", "packets_to_tor", "leaks", "armed_packets"):
            self.assertIsNone(m[k])
        self.assertEqual((m["passed"], m["total"]), (0, 0))

    def test_partly_missing(self):
        run = make_run(self.path("r"), screens=False)
        for p in ("build/module.md", "build/tor.md", "antumbra/filter-status.json", "antumbra/events.tsv",
                  "leak-report.json"):
            os.remove(os.path.join(run, p))
        write(os.path.join(run, "verdict.json"), "{not json")
        page = self.build(run, "--run-number", "8", "--prev", make_run(self.path("p"), run=7))
        self.assertIn("The artifact has no verdict.json", page)
        # With no leak analysis summary.judge does not pass the run.
        self.assertNotIn("Leak test passed", page)
        self.assertIn('<td class="num">–</td>', page)
        self.assertIn("No screenshots in this run.", page)

    def test_run_number(self):
        run = make_run(self.path("r"), run=12)
        page = self.build(run)
        self.assertIn("<h1>Test run 12</h1>", page)
        os.remove(os.path.join(run, "antumbra", "filter-status.json"))
        with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit):
            daily.main(["--run", run, "--out", self.path("x.html")])

    def test_bad_url_not_linked(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8", "--run-url", "javascript:alert(1)")
        self.assertNotIn("javascript:", page)
        self.assertNotIn("The run on GitHub", page)

    def test_date(self):
        run = make_run(self.path("r"))
        with contextlib.redirect_stdout(io.StringIO()):
            daily.main(["--run", run, "--out", self.path("d.html"), "--date", "2026-10-12", "--run-number", "8",
                        "--metrics-out", self.path("d.json")])
        with open(self.path("d.html"), encoding="utf-8") as f:
            self.assertIn("Antumbra Daily · Mon 12 Oct 2026</p>", f.read())
        with open(self.path("d.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["date"], "2026-10-12")
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            daily.main(["--run", run, "--out", self.path("d.html"), "--date", "yesterday"])

    # --- Comparison with the previous run ---

    def test_prev_deltas(self):
        prev = make_run(self.path("r7"), run=7, after_arm=(7488, 0, 2, 1), tor_done=268.5, queries=12,
                        list_version="20261010", module_zip=14102688)
        cur = make_run(self.path("r8"))
        page = self.build(cur, "--run-number", "8", "--prev", prev)
        self.assertIn("Compared with run 7.", page)
        self.assertIn('<th scope="col">Since run 7</th>', page)
        self.assertIn("↓ −667", page)                  # packets after arm: 6824 vs 7491
        self.assertIn("was 7,491", page)
        self.assertIn("↓ −139 s", page)                # Tor: 29.5 s vs 168.5 s
        self.assertIn("↑ +2", page)                    # lookups 14 vs 12
        self.assertIn(">new<", page)                   # block-list version
        self.assertIn("+2 B", page)                    # module zip: below 1 KiB
        self.assertIn('class="delta same"><span class="d">same</span></td>', page)

    def test_delta(self):
        self.assertEqual(daily.delta(5, 3, "count"), ("↑ +2", "up"))
        self.assertEqual(daily.delta(1000, 3000, "count"), ("↓ −2,000", "down"))
        self.assertEqual(daily.delta(None, 3, "count"), ("", ""))
        self.assertEqual(daily.delta(3, None, "bytes"), ("", ""))
        self.assertEqual(daily.delta(4, 4, "count"), ("same", "same"))
        self.assertEqual(daily.delta(100.0, 110.0, "s"), ("within noise", "same"))
        self.assertEqual(daily.delta(30.0, 160.0, "s"), ("↓ −130 s", "down"))
        self.assertEqual(daily.delta(3 * 1024 * 1024, 2 * 1024 * 1024, "bytes"), ("↑ +1.0 MiB", "up"))
        self.assertEqual(daily.delta("a", "a", "text"), ("same", "same"))
        self.assertEqual(daily.delta("b", "a", "text"), ("new", "up"))
        self.assertEqual(daily.fmt(None, "bytes"), "–")
        self.assertEqual(daily.fmt(None, "text"), "–")

    def test_prev_missing_dir(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            page = self.build(make_run(self.path("r")), "--run-number", "8", "--prev", self.path("nowhere"))
        self.assertIn("No earlier run to compare with.", page)
        self.assertIn("not a directory", err.getvalue())

    @unittest.skipUnless(HAVE_CONVERT, "ImageMagick's convert, compare and identify are needed")
    def test_screens_compared(self):
        prev = make_run(self.path("r7"), run=7)
        # One screen differs over a fifth of its area; another only in the status bar.
        cur = make_run(self.path("r8"), shot_box=(0, 100, 90, 160))
        png(os.path.join(cur, "screenshots", "antumbra-welcome-1.png"), box=(0, 0, 90, 6))
        page = self.build(cur, "--run-number", "8", "--prev", prev)
        changed = re.findall(r'<section class="screen changed" data-screen="([^"]+)"', page)
        self.assertEqual(changed, ["welcome-2-choices"])
        sec = page[page.index('data-screen="welcome-2-choices"'):page.index('data-screen="status-1-started"')]
        self.assertEqual(sec.count("<img "), 2)
        self.assertIn("Before (run 7)", sec)
        self.assertRegex(sec, r"\d+\.\d% of the screen changed")
        sec = page[page.index('data-screen="welcome-1"'):page.index('data-screen="welcome-2-choices"')]
        self.assertEqual(sec.count("<img "), 1)
        self.assertIn("Unchanged since run 7", sec)
        self.assertIn('src="data:image/jpeg;base64,', page)

    @unittest.skipUnless(HAVE_CONVERT, "ImageMagick's convert is needed")
    def test_first_time_shown(self):
        prev = make_run(self.path("r7"), run=7, screens=False)
        page = self.build(make_run(self.path("r8")), "--run-number", "8", "--prev", prev)
        self.assertEqual(page.count('<span class="tag">first time shown</span>'), 6)
        self.assertEqual(page.count('width="360"'), 6)

    def test_without_imagemagick(self):
        old = os.environ.get("PATH", "")
        os.environ["PATH"] = self.path("no-bin")
        try:
            page = self.build(make_run(self.path("r")), "--run-number", "8", "--prev", make_run(self.path("p")))
        finally:
            os.environ["PATH"] = old
        self.assertEqual(page.count("The screenshot could not be embedded."), 6)
        self.assertEqual(re.findall(r'data-screen="([^"]+)"', page), SCREEN_IDS)

    # --- The metrics document ---

    def test_metrics_document(self):
        self.build(make_run(self.path("r")), "--run-number", "8", "--sha", SHA, "--subject", "One change",
                   "--run-url", "https://github.com/o/r/actions/runs/1", "--metrics-out", self.path("m.json"))
        with open(self.path("m.json"), encoding="utf-8") as f:
            m = json.load(f)
        self.assertEqual(m, {
            "track": "android", "run": 8, "sha": SHA, "subject": "One change", "date": "2026-10-11",
            "url": "https://github.com/o/r/actions/runs/1", "verdict": "pass",
            "passed": 5, "warned": 2, "failed": 0, "total": 7, "tor_bootstrap_s": 30,
            "packets_after_arm": 6824, "packets_to_tor": 6821, "leaks": 0, "armed_packets": 0})

    # --- Escaping ---

    def test_hostile_strings_escaped(self):
        evil = '</script><script>alert(1)</script><img src=x onerror=alert(2)> & "q"  '
        cs = CHECKS_OK + [("x<b>", "fail", evil)]
        run = make_run(self.path("r"), state="fail", checks=cs, problems=["leak test: FAIL: " + evil])
        write(self.path("q.json"), {"id": "q<1>", "text": evil,
                                    "options": [{"id": 'a"b', "label": evil, "recommended": True}]})
        page = self.build(run, "--run-number", "8", "--subject", evil, "--sha", SHA, "--question",
                          self.path("q.json"))
        self.assertNotIn("<script>alert", page)
        self.assertNotIn("<img src=x", page)
        self.assertNotIn("<b>", page)
        self.assertEqual(page.count("</script>"), 1)
        self.assertEqual(page.count("<script>"), 1)
        self.assertIn("&lt;/script&gt;&lt;script&gt;alert(1)", page)
        self.assertIn('data-choice="a&quot;b"', page)
        data = self.script(page).split("\n", 2)[1]
        self.assertTrue(data.startswith("const RUN = "))
        self.assertNotIn("<", data)
        obj = json.loads(data[len("const RUN = "):].rstrip(";"))
        self.assertEqual(obj["subject"], evil.strip())
        self.assertEqual(obj["question"]["id"], "q<1>")

    def test_placeholder_in_a_value_stays_text(self):
        write(self.path("q.json"), {"id": "q1", "text": "Keep {{LEAK}}?",
                                    "options": [{"id": "a", "label": "{{DATA}}"}]})
        page = self.build(make_run(self.path("r")), "--run-number", "8", "--sha", SHA,
                          "--question", self.path("q.json"), "--subject", "Fix {{SCREENS}} and {{LEAK}} and {{DATA}}")
        self.assertIn("Change tested: <strong>Fix {{SCREENS}} and {{LEAK}} and {{DATA}}</strong>", page)
        self.assertIn("<p>Keep {{LEAK}}?</p>", page)
        self.assertEqual(re.findall(r'data-screen="([^"]+)"', page), SCREEN_IDS)
        for sid in SCREEN_IDS:
            self.assertEqual(page.count('id="note-%s"' % sid), 1)
        self.assertEqual(page.count('<dl class="stats">'), 1)
        self.assertEqual(page.count("const RUN = "), 1)

    def test_bad_sha_refused(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            daily.main(["--run", make_run(self.path("r")), "--out", self.path("x.html"), "--sha", '<b>"x'])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            daily.main(["--run", self.path("r"), "--out", self.path("x.html"), "--sha", "../controls/state"])

    def test_no_sha_no_undo(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8", "--metrics-out", self.path("m.json"))
        self.assertIn('id="undo-off" hidden>No commit was given for this run', page)
        js = self.script(page)
        self.assertIn('"sha": ""', js)
        self.assertIn("if (RUN.sha) {", js)
        self.assertNotIn('"none"', js)
        with open(self.path("m.json"), encoding="utf-8") as f:
            m = json.load(f)
        self.assertEqual((m["sha"], m["subject"], m["url"]), (None, None, None))

    def test_controls_keep_other_fields(self):
        js = self.script(self.build(make_run(self.path("r")), "--run-number", "8", "--sha", SHA))
        self.assertIn("ctlRef.set(Object.assign({}, ctl, { pause: !!ctl.pause, stop: !!ctl.stop, [key]: !ctl[key]", js)
        self.assertIn("ctl.reason", js)
        self.assertIn('getElementById("ctl-state")', js)
        # The paused/stopped line is filled before the write check, so that
        # readers who cannot write see it too.
        self.assertLess(js.index('getElementById("ctl-state")'), js.index('user.can("data.write")'))

    def test_history_labels(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8")
        self.assertIn('<th scope="col">Tor connected after</th>', page)
        self.assertIn('<th scope="col">After the firewall went on (to Tor)</th>', page)
        self.assertNotIn('<th scope="col">Change</th>', page)    # the subject has a row of its own
        self.assertIn('sr.className = "subj"', page)
        self.assertIn("td.dataset.label = LABELS[i]", page)
        self.assertIn("@media (max-width: 40rem)", page)

    def test_header_says_wifi_only(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8")
        self.assertIn("its simulated mobile data is switched off, so it uses Wi-Fi only", page)
        self.assertNotIn("no SIM", page)

    # --- What the leak test did not measure ---

    def metrics(self, run, *extra):
        page = self.build(run, "--run-number", "8", "--metrics-out", self.path("m.json"), *extra)
        with open(self.path("m.json"), encoding="utf-8") as f:
            return page, json.load(f)

    def armed_part(self, page):
        return page[page.index("<h3>Firewall closed, network up</h3>"):page.index("<h3>Plain Android")]

    def test_armed_not_run(self):
        armed = {"status": "not-run", "packets": 0, "allowed": 0, "leaks": 0}
        page, m = self.metrics(make_run(self.path("r"), state="blind", armed=armed,
                                        problems=["leak test: BLIND: the armed window is not-run"]))
        part = self.armed_part(page)
        self.assertIn("Not measured", part)
        self.assertIn("This part of the test did not run.", part)
        self.assertNotIn("sent nothing", part)
        self.assertIsNone(m["armed_packets"])
        rows = page[page.index('id="num-h"'):]
        self.assertIn('<th scope="row">With the firewall closed</th><td class="num">–</td>', rows)

    def test_armed_too_short(self):
        armed = {"status": "too-short", "seconds": -92.7, "packets": 0, "allowed": 0, "leaks": 0}
        page, m = self.metrics(make_run(self.path("r"), state="blind", armed=armed))
        part = self.armed_part(page)
        self.assertIn("The window was too short to judge", part)
        self.assertNotIn("-93", part)
        self.assertNotIn("−93", part)
        self.assertNotIn("sent nothing", part)
        self.assertIsNone(m["armed_packets"])

    def test_armed_measured(self):
        armed = {"status": "fail", "seconds": 30.2, "packets": 3, "allowed": 2, "leaks": 1}
        page, m = self.metrics(make_run(self.path("r"), state="fail", armed=armed))
        part = self.armed_part(page)
        self.assertIn("Did not hold", part)
        self.assertIn("For 30 s the test closed the firewall", part)
        self.assertIn("3 packets, 2 of them link-level (ARP, DHCP, empty or Wi-Fi joining frames)", part)
        self.assertEqual(m["armed_packets"], 3)

    def test_leak_analysis_error(self):
        armed = {"status": "not-run", "packets": 0, "allowed": 0, "leaks": 0}
        run = make_run(self.path("r"), state="blind", analysis_verdict="error", post_arm=False, armed=armed,
                       problems=["leak test: ERROR: consensus: has no relay ('r') lines: not a consensus"])
        page, m = self.metrics(run)
        leak = page[page.index('id="leak-h"'):page.index('id="screens-h"')]
        self.assertIn("The leak test could not run: consensus", leak)
        self.assertIn("The leak test could not run, so nothing can be said about leaks in this run.", leak)
        self.assertIn('<dt>Leaks</dt><dd>–</dd>', leak)
        self.assertIn('<dt>To the Tor network</dt><dd>–</dd>', leak)
        self.assertNotIn("Leaks: <strong>0</strong>", leak)
        self.assertNotIn("Nothing was seen leaking", leak)
        for k in ("packets_after_arm", "packets_to_tor", "leaks", "armed_packets"):
            self.assertIsNone(m[k], k)

    def test_leak_analysis_error_with_post_arm(self):
        # Without a consensus every relay looks like a leak: no count is shown.
        run = make_run(self.path("r"), state="fail", analysis_verdict="error", leaks=6)
        page, m = self.metrics(run)
        self.assertIn("The leak test could not run, so nothing can be said", page)
        self.assertNotIn("6 leak", page)
        self.assertIsNone(m["leaks"])

    def test_no_post_arm_phase(self):
        page, m = self.metrics(make_run(self.path("r"), state="blind", post_arm=False))
        self.assertIn("The recordings have no time after the firewall went on, so nothing can be said", page)
        self.assertIsNone(m["packets_to_tor"])
        self.assertIsNone(m["leaks"])

    def test_leak_definition(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8")
        self.assertIn("apart from the Wi-Fi network&#x27;s own housekeeping (ARP, DHCP, empty and Wi-Fi joining "
                      "frames)", page)
        self.assertIn("DHCP and ARP keep the Wi-Fi address working.", page)

    def test_baseline_sentence(self):
        page = self.build(make_run(self.path("r")), "--run-number", "8")
        # 83 packets, 3 of them the test's markers: 80 to the 3 destinations.
        self.assertIn("plain Android from boot to the end of the recording (about 208 s, 180 s of it left alone) "
                      "sent 80 packets to 3 destinations", page)

    def test_tor_seconds_one_rounding(self):
        # 29.5 s: the page, the metrics and the history all say 30 s.
        page, m = self.metrics(make_run(self.path("r"), tor_done=129.5))
        self.assertIn('<th scope="row">Start to connected</th><td class="num">30 s</td>', page)
        self.assertEqual(m["tor_bootstrap_s"], 30)
        self.assertEqual(daily.secs(29.46), 29)
        self.assertEqual(daily.secs(2.5), 3)
        self.assertEqual(daily.fmt_s(29.46), "29 s")

    def test_plain_warnings(self):
        w = daily.plain_warning("through Tor, not on the expected list: name www.gstatic.com (4 look-up(s) through "
                                "Tor; filter: forwarded 1, servfail (timeout) 4)")
        self.assertEqual(w, "www.gstatic.com was looked up through Tor 4 times, but it is not on the list of names "
                            "the test expects. The tracker filter's answers: 1 passed on to Tor, 4 timed out.")
        self.assertIn("Something reached 142.251.155.120:443 through Tor (2 connections)", daily.plain_warning(
            "through Tor, not on the expected list: target 142.251.155.120:443 (2 stream(s), CLOSED 2)"))
        self.assertEqual(daily.plain_warning("odd thing"), "Odd thing")
        self.assertEqual(daily.plain_check("wifi_mac_new", "warn"),
                         "The Wi-Fi hardware address did not change for the session")
        self.assertEqual(daily.plain_check("new_check", "fail"), "Not as expected: new check")
        self.assertEqual(daily.plain_check("welcome_emergency_dialer", "fail"),
                         "Emergency calls from the Welcome screen did not work as expected (nothing was dialled)")
        self.assertEqual(daily.plain_check("tracker_blocked:x.net", "ok"), "Tracker blocked: x.net")

    def test_odd_shapes_do_not_crash(self):
        def mutate(name, fn):
            run = make_run(self.path(name), screens=False)
            fn(run)
            page = self.build(run, "--run-number", "8", out=name + ".html")
            self.assertIn("<h1>Test run 8</h1>", page)
            return page

        def edit(run, rel, fn):
            path = os.path.join(run, rel)
            with open(path, encoding="utf-8") as f:
                obj = json.load(f)
            fn(obj)
            write(path, obj)

        def leaks_odd(o):
            a = o["scenarios"]["antumbra"]
            a["leaks"] = [{"class": "LEAK", "dst": 5, "dport": 53, "kind": ["x"], "phases": {"post-arm": 2}}, "x"]
        page = mutate("dst", lambda r: edit(r, "leak-report.json", leaks_odd))
        self.assertIn("5:<wbr>53", page)
        mutate("warnings", lambda r: edit(r, "verdict.json", lambda v: v.update(warnings=5)))
        mutate("flows", lambda r: edit(r, "leak-report.json",
                                       lambda o: o["scenarios"]["baseline"].update(flows=3, flows_total=9)))
        mutate("names", lambda r: edit(r, "leak-report.json", lambda o: o["scenarios"]["baseline"].update(
            dns_names=[{"name": 7}, {"name": "a.example"}, "x"])))
        mutate("flow-names", lambda r: edit(r, "leak-report.json", lambda o: o["scenarios"]["baseline"]["flows"][0]
                                            .update(names="abc", dst=["x"])))
        mutate("armed", lambda r: edit(r, "leak-report.json", lambda o: o["scenarios"]["antumbra"].update(
            armed_window={"status": ["ok"], "packets": "3"})))
        mutate("question", lambda r: None)

        def no_verdict_list_analysis(run):
            os.remove(os.path.join(run, "verdict.json"))
            os.remove(os.path.join(run, "leak-report.json"))
            write(os.path.join(run, "antumbra", "analysis.json"), [1, 2])
        page = mutate("analysis-list", no_verdict_list_analysis)
        self.assertNotIn("Leak test passed", page)
        write(self.path("q.json"), {"id": "q", "text": "?", "options": 5})
        self.build(make_run(self.path("q"), screens=False), "--run-number", "8", "--question", self.path("q.json"))

    @unittest.skipUnless(HAVE_CONVERT, "ImageMagick's convert, compare and identify are needed")
    def test_changed_share_at_full_size(self):
        # A one-pixel line in a 360 px wide screen is 1/360 of it, not more.
        a, b = self.path("a.png"), self.path("b.png")
        png(a, w=360, h=400)
        png(b, w=360, h=400, box=(100, 0, 101, 400))
        frac = daily.changed_fraction(a, b, self.tmp)
        self.assertAlmostEqual(frac, 1 / 360, places=5)


if __name__ == "__main__":
    unittest.main()
