#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the "Antumbra Daily" page from one Android emulator run's artifact.

The emulator job of .github/workflows/antumbra-android.yml uploads an
artifact antumbra-android-<run number> per run (see README.md, "Artifacts"):
verdict.json, leak-report.json, <scenario>/checks.tsv and events.tsv,
antumbra/filter-status.json, bootstrap-progress.tsv, build/*.md and
screenshots/. This script turns the newest run, compared with the one before
it, into one self-contained HTML page for the owner: the verdict, the leak
test in plain words, each screen before and after, the numbers that can be
compared between runs, and the checks. Screenshots are embedded as small
JPEGs (ImageMagick's convert and compare); without ImageMagick the page is
built without them.

The artifact does not carry the run's number, commit or link: the routine
passes them (--run-number, --sha, --subject, --run-url). The previous run's
number is read from its DNS filter's version ("ci.<n>") unless
--prev-run-number gives it.

The page is published as a private Claude artifact with the db, user and
assets capabilities. Its buttons write small documents to the artifact's
database, which the next morning's routine reads. The model is the one the
Debian track's page used (antumbra/tests/vm/report/daily.py), unchanged:

  feedback/<run>_<screen>   {run, screen, verdict: right|off, note, at}
                            screen: welcome-1, welcome-2-choices,
                            status-1-started, status-2-bootstrapped,
                            status-3-after-tracker-test, baseline-home
                            (any other screenshot: its name without
                            "antumbra-")
  controls/state            {pause, stop, at}: no change / no routine; other
                            fields (a "reason" the planning session wrote)
                            are kept when a button is pressed, and the page
                            says in words that changes are paused, and why
  undo/<sha>                {sha, subject, run, at}: revert that change
                            (sha: the first 12 hex digits; without --sha
                            the page offers no Undo)
  answers/<question id>     {choice, at}
  photos/<asset id>         {asset, note, run, at}: a photo of the phone
  metrics/<run>             written by the routine (one row per run), read
                            by the page for the history table

metrics/<run> is the document --metrics-out writes, to be stored as it is
with one ArtifactData set:

  {"track": "android", "run": 8, "sha": "<full sha>", "subject": "...",
   "date": "2026-10-11", "url": "https://github.com/.../runs/...",
   "verdict": "pass" | "fail" | "blind",
   "passed": 36, "warned": 2, "failed": 0, "total": 38,
   "tor_bootstrap_s": 29, "packets_after_arm": 6824,
   "packets_to_tor": 6821, "leaks": 0, "armed_packets": 0}

passed, warned and failed count the checks of both scenarios (ok, warn,
fail); tor_bootstrap_s is the time from "Start Antumbra" to Tor's 100%, in
whole seconds rounded half up (as the page shows it); packets_after_arm,
packets_to_tor and leaks (LEAK flows) come from the ANTUMBRA scenario's
leak analysis, and are null when it did not cover the time after the
firewall went on (verdict "error", or no post-arm phase); armed_packets
comes from its armed window, null unless that window was measured (status
"ok" or "fail"). A value the artifact does not hold is null, and so are
sha, subject and url when they were not given. Rows from the Debian track
({run, sha, subject, passed, total, phosh_ready, squashfs_mib, packages,
date}) have no "track" and still show in the table.

usage: daily.py --run DIR [--prev DIR] [--question FILE.json] --out PAGE.html
                [--run-number N] [--sha SHA] [--subject TEXT] [--run-url URL]
                [--date YYYY-MM-DD[THH:MM]] [--prev-run-number N]
                [--metrics-out FILE.json]
"""
import argparse
import base64
import datetime
import glob
import html
import json
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import summary  # noqa: E402  the CI's own reading of the artifact

E = html.escape
DASH = "–"
SCENARIOS = ("antumbra", "baseline")
# The screens, in this order: (page id, file name, title, what it shows).
# Any other screenshot (antumbra-final.png after a failure) follows by name.
SCREENS = (
    ("welcome-1", "antumbra-welcome-1", "Welcome",
     "The first screen after Antumbra is installed. Nothing reaches the network until Start."),
    ("welcome-2-choices", "antumbra-welcome-2-choices", "The session's choices",
     "Further down: the choices the test made (Tor directly, a new Wi-Fi address, Administration off)."),
    ("status-1-started", "antumbra-status-1-started", "Started",
     "Right after Start Antumbra, while Tor connects."),
    ("status-2-bootstrapped", "antumbra-status-2-bootstrapped", "Connected to Tor",
     "Tor at 100%: the phone can reach the internet, through Tor only."),
    ("status-3-after-tracker-test", "antumbra-status-3-after-tracker-test", "After the tracker test",
     "The tracker filter's counts after the test asked for two tracker names."),
    ("baseline-home", "baseline-home", "Plain Android's home screen",
     "The baseline: Android 16 with nothing installed, recorded for comparison."),
)
# A screen counts as changed above this share of differing pixels, the
# status bar (clock, battery: the top 4%) left out.
CHANGED = 0.02
STATUS_BAR = 4
TOR_CLASSES = ("tor-relay", "tor-directory", "bridge")
CLASS_WORDS = {
    "lan-dhcp": "DHCP (asking the Wi-Fi network for an address)",
    "link-arp": "ARP (finding the router on the Wi-Fi network)",
    "link-80211": "Wi-Fi joining frames",
    "link-empty": "empty frames (a network header with nothing after it)",
    "ci-marker": "the test's own clock marker",
    "LEAK": "leaks",
}
# What the analyser lets through besides Tor (leak_analyser.py, ALLOWED):
# the Wi-Fi link's own housekeeping, and the test's clock marker.
HOUSEKEEPING = "the Wi-Fi network's own housekeeping (ARP, DHCP, empty and Wi-Fi joining frames)"
# The kinds of LEAK flow (leak_analyser.py), in plain words.
KIND_WORDS = {
    "armed": "while the firewall was fully closed",
    "dns": "a name lookup outside Tor",
    "dhcp": "DHCP to outside the local network",
    "dhcp-lease": "DHCP asking for an earlier address",
    "dhcp-hostname": "DHCP giving the phone's name",
    "ipv6": "IPv6 (switched off, must not leave)",
    "tcp": "a TCP connection outside Tor",
    "udp": "UDP (Tor never uses it)",
    "lan": "to the local network",
    "multicast": "an announcement to the local network",
    "icmp": "ICMP (ping and the like)",
    "fragment": "a piece of a split packet",
    "undecoded": "a frame the test could not read",
    "unattributed": "from an address that is not the phone's",
    "other": "another protocol",
}
# Checks in plain words, (what was checked, what it means when it was not
# met: a warning or a failure). A name with a colon is "kind:target".
CHECK_WORDS = {
    "adb_root": ("The test could control the phone", "The test could not get full control of the phone"),
    "system_ready": ("Android started", "Android did not start in time"),
    "guest_capture": ("Recording of the phone's traffic started inside the phone",
                      "The recording inside the phone did not start"),
    "guest_capture_pulled": ("The recording was copied off the phone whole",
                             "The recording inside the phone was not copied off whole"),
    "default_network": ("Plain Android had a network", "Plain Android had no network"),
    "airplane_mode": ("No network before Antumbra was installed",
                      "Android still had a network before Antumbra was installed"),
    "module_install": ("Antumbra installed, its firewall on",
                       "Antumbra did not install, or its firewall did not come on"),
    "mobile_data_off": ("Mobile data off (the test uses Wi-Fi only)",
                        "Mobile data stayed on (the test uses Wi-Fi only)"),
    "device_owner": ("Welcome became the phone's managing app", "Welcome did not become the phone's managing app"),
    "welcome_screen": ("Welcome screen shown", "The Welcome screen did not appear"),
    "welcome_emergency_dialer": ("The emergency dialer opened from the Welcome screen (nothing was dialled)",
                                 "Emergency calls from the Welcome screen did not work as expected (nothing was dialled)"),
    "welcome_emergency_recover": ("Welcome came back after the emergency dialer check",
                                  "Welcome did not come back after the emergency dialer check"),
    "welcome_power_menu_emergency": (
        "The power menu's Emergency button showed over the Welcome screen (not pressed, nothing dialled)",
        "The power menu check on the Welcome screen did not go as expected "
        "(nothing in the power menu was pressed, nothing dialled)"),
    "welcome_power_menu_recover": ("The phone was put back after the power menu check",
                                   "The phone was not fully put back after the power menu check"),
    "welcome_mac": ("The new Wi-Fi address switch set in Welcome",
                    "The test could not set the new Wi-Fi address switch in Welcome"),
    "welcome_unsafe": ("The Unsafe Browser switch found off", "The test could not find the Unsafe Browser switch off"),
    "status_screen": ("Status screen shown after Start", "The status screen did not appear after Start"),
    "provider_started": ("Welcome reports the session started", "Welcome does not report the session as started"),
    "provider_mode": ("Tor mode: directly", "Tor mode is not \"directly\""),
    "provider_admin": ("Administration off", "Administration is on"),
    "wifi_default": ("Wi-Fi became the phone's network", "Wi-Fi did not become the phone's network"),
    "wifi_mac_new": ("A new Wi-Fi hardware address for the session",
                     "The Wi-Fi hardware address did not change for the session"),
    "welcome_policies": ("Welcome's restrictions in place", "Welcome's restrictions are not as expected"),
    "welcome_addon": ("Welcome shows the firewall live", "Welcome does not show the firewall live"),
    "welcome_module_word": ("Welcome takes the add-on's word on recent calls from the add-on alone",
                            "Welcome's check of who may tell it about recent calls did not go as expected"),
    "module_parsers": ("The add-on read the virtual phone's call and IMS state",
                       "The add-on could not read the virtual phone's call or IMS state"),
    "tor_bootstrap": ("Tor connected", "Tor did not connect"),
    "tracker_blocked": ("Tracker blocked", "Tracker not blocked"),
    "tracker_test": ("The tracker test ran", "The tracker test could not run"),
    "control_resolves": ("An ordinary name answered through Tor", "No answer through Tor for an ordinary name"),
    "other_app_listener": ("A stand-in app listened on a private port",
                           "The stand-in app did not listen, so the private-port test proves nothing"),
    "other_app_port": ("No app could reach another app's private port", "An app reached another app's private port"),
    "armed_state_held": ("The closed firewall stayed closed during the test",
                         "The closed firewall opened during the test"),
    "armed_phase": ("Firewall closed with the network up, then open to Tor again",
                    "The firewall did not close and open again as expected"),
    "tor_streams": ("Tor's connection log recorded", "Tor's connection log was not recorded"),
    "firewall_live": ("Firewall live at the end", "The firewall was not live at the end"),
    "process_caps_2950": ("Tor runs without special powers", "Tor runs with special powers"),
    "process_caps_2951": ("The tracker filter runs without special powers",
                          "The tracker filter runs with special powers"),
    "process_uid_2950": ("Tor is running", "Tor is not running"),
    "process_uid_2951": ("The tracker filter is running", "The tracker filter is not running"),
    "listeners": ("Tor and the filter listen only inside the phone", "A program listens where it should not"),
    "listener": ("Listening where expected", "Not listening where expected"),
    "control_socket": ("Tor's control socket locked to Tor", "Tor's control socket is not locked to Tor"),
    "wifi_store_in_ram": ("Saved Wi-Fi networks kept in memory only",
                          "Saved Wi-Fi networks are not kept in memory only"),
    "dhcp_memory_in_ram": ("Old Wi-Fi addresses kept in memory only",
                           "Old Wi-Fi addresses are not kept in memory only"),
    "ipv6_off": ("IPv6 off", "IPv6 is not off"),
    "filter_query_log": ("The tracker filter's lookup log recorded",
                         "The tracker filter's lookup log was not recorded"),
    "evidence": ("The evidence collected at the end", "The evidence at the end was not collected"),
}
# The tracker filter's answers (its lookup log), in plain words.
DECISION_WORDS = {"forwarded": "passed on to Tor", "servfail (timeout)": "timed out", "blocked": "blocked",
                  "nxdomain": "answered \"no such name\""}
PROBLEM_LEADS = (
    ("leak test: BLIND (capture incomplete): ", "The leak test could not judge: "),
    ("leak test: FAIL: ", "The leak test failed: "),
    ("leak test: ERROR: ", "The leak test could not run: "),
    ("the antumbra scenario failed: ", "Checks failed on the Antumbra phone: "),
    ("the baseline scenario failed: ", "Checks failed on plain Android: "),
)


# --- Reading the artifact ---------------------------------------------------

def get(d, *keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def num(x):
    """x if it is a finite number (not a bool), else None."""
    if isinstance(x, bool) or not isinstance(x, (int, float)) or x != x or x in (float("inf"), float("-inf")):
        return None
    return x


def secs(x):
    """Whole seconds, half up: the one rounding of seconds on the page and
    in the metrics document (the history table shows them as they are)."""
    return None if x is None else int(x + 0.5) if x >= 0 else -int(-x + 0.5)


def strs(x):
    """The strings (and numbers, as text) of x if it is a list, else []."""
    return [str(i) for i in x if isinstance(i, (str, int, float)) and not isinstance(i, bool)] \
        if isinstance(x, list) else []


def read_tsv(path):
    t = summary.read_text(path) or ""
    return [line.split("\t") for line in t.splitlines() if line.strip()]


def run_number_of(root):
    """The run number in the DNS filter's version ("ci.<n>"), or None."""
    st = summary.read_json(os.path.join(root, "antumbra", "filter-status.json"))
    m = re.fullmatch(r"ci\.(\d+)", str(get(st, "version") or ""))
    return int(m.group(1)) if m else None


def tor_seconds(adir):
    """Seconds from "Start Antumbra" to Tor's 100%, or None."""
    ev = summary.events(adir)
    if "welcome_start" not in ev:
        return None
    start = ev["welcome_start"][0]
    if "tor_bootstrapped" in ev:
        return max(0.0, ev["tor_bootstrapped"][0] - start)
    for row in read_tsv(os.path.join(adir, "bootstrap-progress.tsv"))[1:]:
        try:
            if int(row[1]) >= 100:
                return max(0.0, float(row[0]) - start)
        except (IndexError, ValueError):
            continue
    return None


def build_notes(root):
    """Sizes and versions from build/*.md (the only place they are kept)."""
    out = {}

    def text(name):
        return summary.read_text(os.path.join(root, "build", name)) or ""
    m = re.search(r"(\S+\.zip): (\d+) bytes", text("module.md"))
    out["module_zip"] = int(m.group(2)) if m else None
    m = re.search(r"(\S+\.apk): (\d+) bytes", text("welcome.md"))
    out["apk"] = int(m.group(2)) if m else None
    tor = text("tor.md")
    for abi, key in (("arm64-v8a", "tor_arm64"), ("x86_64", "tor_x86_64")):
        m = re.search(r"^- %s: (\d+) bytes" % re.escape(abi), tor, re.M)
        out[key] = int(m.group(1)) if m else None
    m = re.search(r"^- tor (\d[\w.-]*)", tor, re.M)
    out["tor_version"] = m.group(1) if m else None
    m = re.search(r"Block list: version (\S+?),? (\d+) entries", text("dnsfilter.md"))
    out["list_version"], out["list_size"] = (m.group(1), int(m.group(2))) if m else (None, None)
    return out


def analysis(root, scenario):
    a = get(summary.read_json(os.path.join(root, "leak-report.json")), "scenarios", scenario)
    if not isinstance(a, dict):
        a = summary.read_json(os.path.join(root, scenario, "analysis.json"))
    return a if isinstance(a, dict) else None


def state_of(ok, problems, ana_verdict, checks, results):
    """pass, fail or blind ("could not judge")."""
    if ok:
        return "pass"
    failed = any(c[1] == "fail" for cs in checks.values() for c in cs)
    if failed or ana_verdict == "fail" or any(r not in (None, "0") for r in results.values()):
        return "fail"
    return "blind"


def screens(root):
    """[(page id, png path)] of a run, the known screens first."""
    found = {os.path.splitext(os.path.basename(p))[0]: p
             for p in glob.glob(os.path.join(root, "screenshots", "*.png"))}
    out = [(sid, found.pop(fname)) for sid, fname, _, _ in SCREENS if fname in found]
    for name in sorted(found):
        sid = re.sub(r"[^A-Za-z0-9_-]", "-", name[len("antumbra-"):] if name.startswith("antumbra-") else name)
        out.append((sid, found[name]))
    return out


def facts(root):
    """Everything the page and the metrics document need from one artifact."""
    f = {"root": root}
    v = summary.read_json(os.path.join(root, "verdict.json"))
    if isinstance(v, dict) and isinstance(v.get("problems"), list):
        f["ok"] = v.get("ok") is True
        f["problems"] = strs(v["problems"])
        f["warnings"] = strs(v.get("warnings"))
        f["verdict_file"] = True
    else:
        f["verdict_file"] = False
        try:  # the CI's own judgement, from the other files
            ok, problems, sfacts = summary.judge(root)
            f["ok"], f["problems"], f["warnings"] = ok, [str(p) for p in problems], summary.warnings(sfacts)
        except (AttributeError, TypeError, ValueError, KeyError) as e:
            f["ok"], f["problems"], f["warnings"] = False, ["the artifact's files could not be read (%s)" % e], []
    f["checks"] = {s: summary.checks(os.path.join(root, s)) for s in SCENARIOS}
    f["results"] = {s: ((summary.read_text(os.path.join(root, s, "result")) or "").strip() or None)
                    for s in SCENARIOS}
    all_checks = [c for s in SCENARIOS for c in f["checks"][s]]
    for k in ("ok", "warn", "fail"):
        f["checks_" + k] = sum(1 for c in all_checks if c[1] == k)
    f["checks_total"] = len(all_checks)

    a = f["analysis"] = analysis(root, "antumbra")
    f["baseline"] = analysis(root, "baseline")
    verdict = get(a, "verdict")
    post = get(a, "phases", "post-arm")
    post = {str(k): n for k, n in post.items() if num(n) is not None} if isinstance(post, dict) else None
    # The counts mean something only when the analysis ran (not "error":
    # without a consensus every Tor relay looks like a leak) and the
    # recording covers the time after the firewall went on.
    f["leak_judged"] = "no-analysis" if a is None else "error" if verdict == "error" else \
        "no-post-arm" if post is None else "yes"
    if f["leak_judged"] != "yes":
        post = None
    f["post_arm"] = post
    f["after_arm"] = sum(post.values()) if post is not None else None
    f["to_tor"] = num(get(a, "post_arm_tor_packets")) if post is not None else None
    if f["to_tor"] is None and post is not None:
        f["to_tor"] = sum(n for k, n in post.items() if k in TOR_CLASSES)
    leaks = get(a, "leaks")
    f["leak_flows"] = ([x for x in leaks if isinstance(x, dict)] if isinstance(leaks, list) else None) \
        if post is not None else None
    f["leaks"] = len(f["leak_flows"]) if f["leak_flows"] is not None else None
    aw = get(a, "armed_window")
    aw = dict(aw) if isinstance(aw, dict) else {}
    aw["status"] = aw.get("status") if isinstance(aw.get("status"), str) else None
    f["armed"] = aw
    # The analyser fills packets 0 in before it measures: only a window it
    # judged ("ok" or "fail") has a count.
    f["armed_measured"] = aw["status"] in ("ok", "fail") and verdict != "error"
    f["armed_packets"] = num(aw.get("packets")) if f["armed_measured"] else None
    f["state"] = state_of(f["ok"], f["problems"], verdict, f["checks"], f["results"])

    adir = os.path.join(root, "antumbra")
    f["tor_s"] = secs(tor_seconds(adir))
    st = summary.read_json(os.path.join(adir, "filter-status.json"))
    f["queries"], f["blocked"] = num(get(st, "queries")), num(get(st, "blocked"))
    b = build_notes(root)
    f.update({k: b[k] for k in ("module_zip", "apk", "tor_arm64", "tor_x86_64", "tor_version")})
    lv, ls = get(st, "list", "version"), num(get(st, "list", "size"))
    f["list_version"] = str(lv) if lv not in (None, "") else b["list_version"]
    f["list_size"] = ls if ls is not None else b["list_size"]
    f["run_hint"] = run_number_of(root)
    f["screens"] = screens(root)
    return f


# --- Screenshots ------------------------------------------------------------

def jpeg(png, tmp, width=360):
    """The screenshot as a data: URI, width px wide; None without ImageMagick."""
    out = os.path.join(tmp, "%d.jpg" % len(os.listdir(tmp)))
    try:
        subprocess.run(["convert", png, "-resize", "%dx" % width, "-strip", "-quality", "70", out],
                       check=True, capture_output=True, timeout=60)
        with open(out, "rb") as fh:
            return "data:image/jpeg;base64," + base64.b64encode(fh.read()).decode()
    except (OSError, subprocess.SubprocessError):
        return None


def changed_fraction(a, b, tmp):
    """Share of pixels that differ between two screenshots at their full
    size, the status bar cropped off (a pixel differs when its grey level
    moved more than 8%); None if they cannot be compared."""
    norm = []
    try:
        for i, p in enumerate((a, b)):
            out = os.path.join(tmp, "cmp%d.png" % i)
            r = subprocess.run(["convert", p, "-gravity", "south", "-crop", "100%%x%d%%+0+0" % (100 - STATUS_BAR),
                                "+repage", "-colorspace", "gray", out],
                               capture_output=True, timeout=60)
            if r.returncode:
                return None
            norm.append(out)
        size = [subprocess.run(["identify", "-format", "%w %h", p], capture_output=True, text=True,
                               timeout=60).stdout for p in norm]
        if not size[0] or not size[1]:
            return None
        if size[0] != size[1]:
            return 1.0
        r = subprocess.run(["compare", "-metric", "AE", "-fuzz", "8%", norm[0], norm[1], "null:"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    m = re.match(r"\s*([\d.]+(?:e[+-]?\d+)?)", r.stderr)
    if not m or r.returncode not in (0, 1):
        return None
    w, h = (int(x) for x in size[0].split())
    return float(m.group(1)) / (w * h)


# --- Formatting -------------------------------------------------------------

def fmt_count(n):
    if isinstance(n, float) and n.is_integer():
        n = int(n)
    return DASH if n is None else "{:,}".format(n)


def fmt_bytes(n):
    if n is None:
        return DASH
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(n) < 1024 or unit == "GiB":
            return "%.0f %s" % (n, unit) if unit == "B" else "%.1f %s" % (n, unit)
        n /= 1024.0
    return str(n)


def fmt_s(x):
    return DASH if x is None else "%d s" % secs(x)


def fmt(value, kind):
    if kind == "bytes":
        return fmt_bytes(value)
    if kind == "s":
        return fmt_s(value)
    if kind == "count":
        return fmt_count(value)
    return DASH if value in (None, "") else str(value)


def delta(cur, prev, kind):
    """Text and class of the change from prev to cur ("" when either is missing)."""
    if cur is None or prev is None:
        return "", ""
    if kind == "text":
        return ("same", "same") if str(cur) == str(prev) else ("new", "up")
    if kind == "s":
        cur, prev = secs(cur), secs(prev)
    d = cur - prev
    if d == 0:
        return "same", "same"
    arrow = "↑ " if d > 0 else "↓ "
    if kind == "bytes":
        if abs(d) < 1024:
            return ("%+d B" % d).replace("-", "−"), "same"
        text = ("+" if d > 0 else "−") + fmt_bytes(abs(d))
    elif kind == "count":
        text = "{:+,}".format(int(d) if isinstance(d, float) and d.is_integer() else d)
    else:  # seconds: only a change above 20% counts
        if prev and abs(d) / prev < 0.2:
            return "within noise", "same"
        text = "%+d s" % d
    return arrow + text.replace("-", "−"), ("up" if d > 0 else "down")


def numbers(f):
    """The comparable numbers of a run, in groups: [(group, [(label, value, kind)])]."""
    f = f or {}
    return [
        ("The leak test, packets", [
            ("After the firewall went on", f.get("after_arm"), "count"),
            ("… to the Tor network", f.get("to_tor"), "count"),
            ("Leaks", f.get("leaks"), "count"),
            ("With the firewall closed", f.get("armed_packets"), "count"),
        ]),
        ("Tor", [
            ("Start to connected", f.get("tor_s"), "s"),
            ("Tor version", f.get("tor_version"), "text"),
        ]),
        ("Tracker filter", [
            ("Name lookups", f.get("queries"), "count"),
            ("Blocked", f.get("blocked"), "count"),
            ("Domains on the list", f.get("list_size"), "count"),
            ("List version", f.get("list_version"), "text"),
        ]),
        ("Builds", [
            ("Module (zip)", f.get("module_zip"), "bytes"),
            ("Welcome app (APK)", f.get("apk"), "bytes"),
            ("tor for phones (arm64)", f.get("tor_arm64"), "bytes"),
            ("tor for the emulator (x86_64)", f.get("tor_x86_64"), "bytes"),
        ]),
        ("Checks", [
            ("Passed", f.get("checks_ok"), "count"),
            ("Warnings", f.get("checks_warn"), "count"),
            ("Failed", f.get("checks_fail"), "count"),
        ]),
    ]


def plain_check(name, status="ok"):
    """What a check looked at, in plain words; for a warning or a failure,
    what it found instead ("Tor did not connect")."""
    kind, _, target = name.partition(":")
    words = CHECK_WORDS.get(kind)
    if words:
        words = words[0] if status == "ok" else words[1]
    else:
        words = kind.replace("_", " ").capitalize()
        if status != "ok":
            words = "Not as expected: " + words[:1].lower() + words[1:]
    return "%s: %s" % (words, target) if target else words


def plain_warning(w):
    """A warning of verdict.json that is not a check's, in plain words."""
    m = re.fullmatch(r"through Tor, not on the expected list: name (.+?) \((.*)\)", w)
    if m:
        name, how = m.group(1), m.group(2)
        n = re.search(r"(\d+) look-up\(s\) through Tor", how)
        text = "%s was looked up through Tor%s, but it is not on the list of names the test expects." % (
            name, " %s time%s" % (n.group(1), "" if n.group(1) == "1" else "s") if n else "")
        fm = re.search(r"filter: (.*)", how)
        if fm:
            parts = []
            for item in fm.group(1).split(", "):
                im = re.fullmatch(r"(.+) (\d+)", item.strip())
                if im:
                    parts.append("%s %s" % (im.group(2), DECISION_WORDS.get(im.group(1), im.group(1))))
            if parts:
                text += " The tracker filter's answers: %s." % ", ".join(parts)
        return text
    m = re.fullmatch(r"through Tor, not on the expected list: target (\S+) \((\d+) stream\(s\).*\)", w)
    if m:
        return ("Something reached %s through Tor (%s connection%s) that is not on the list the test expects."
                % (m.group(1), m.group(2), "" if m.group(2) == "1" else "s"))
    if w.startswith("tor's STREAM events were not recorded"):
        return "Tor's connection log was not recorded, so where the phone went through Tor is unknown."
    return w[:1].upper() + w[1:]


def plain_problem(p):
    for raw, lead in PROBLEM_LEADS:
        if p.startswith(raw):
            return lead + p[len(raw):]
    return p[:1].upper() + p[1:]


def short(text, n=280):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n - 1] + "…"


def tidy_detail(text):
    """A check's detail without a trailing JSON object, whose telling
    fields (rcode, error) follow in brackets."""
    m = re.match(r"(.*?):?\s*(\{.*\})\s*$", str(text), re.S)
    if not m:
        return str(text)
    try:
        obj = json.loads(m.group(2))
    except ValueError:
        return str(text)
    if not isinstance(obj, dict):
        return str(text)
    keep = ["%s %s" % (k, obj[k]) for k in ("rcode", "error") if isinstance(obj.get(k), (str, int)) and obj[k] != ""]
    return m.group(1).strip() + (" (%s)" % ", ".join(keep) if keep else "")


def dest(r):
    d = str(r.get("dst") or r.get("label") or "?")
    if r.get("l3") == "ipv6" and r.get("dst"):
        d = "[%s]" % d
    if r.get("dport") is not None:
        d += ":%s" % r["dport"]
    return d


def dest_html(r):
    """The destination, escaped, with break points after dots and colons."""
    return E(dest(r)).replace(".", ".<wbr>").replace(":", ":<wbr>")


def what_is(r):
    """A few plain words for a destination of plain Android's."""
    if r["names"]:
        names = sorted(r["names"])
        return ", ".join(names[:2]) + (", …" if len(names) > 2 else "")
    port, proto, dst = r.get("dport"), r.get("proto"), str(r.get("dst") or "")
    if port == 5353:
        return "announcing the phone on the local network (mDNS)"
    if port in (53, 853):
        return "name lookups at the network's resolver"
    if port == 123:
        return "setting the clock (NTP)"
    if proto == "arp":
        return "finding the router (ARP)"
    if proto == "icmpv6" or r.get("l3") == "ipv6":
        return "IPv6 network set-up"
    if dst.startswith("224.") or dst.startswith("239."):
        return "joining a local multicast group"
    return DASH


def baseline_rows(b):
    """Plain Android's destinations (the test's own markers left out)."""
    rows = {}
    flows = get(b, "flows")
    for fl in flows if isinstance(flows, list) else []:
        if not isinstance(fl, dict) or fl.get("class") == "ci-marker":
            continue
        k = tuple(str(fl.get(x)) for x in ("proto", "dst", "dport"))
        r = rows.setdefault(k, {"l3": fl.get("l3"), "dst": fl.get("dst"), "dport": num(fl.get("dport")),
                                "proto": fl.get("proto"), "label": fl.get("label"), "packets": 0,
                                "names": set(), "class": fl.get("class")})
        r["packets"] += num(fl.get("packets")) or 0
        names = fl.get("names")
        if isinstance(names, list):
            r["names"].update(n for n in names if isinstance(n, str))
    return sorted(rows.values(), key=lambda r: (-r["packets"], str(r["dst"])))


# --- The page ---------------------------------------------------------------

def pill(state):
    return {"pass": ("ok", "Leak test passed"), "fail": ("bad", "Test failed"),
            "blind": ("warn", "Could not judge")}[state]


def checks_line(f):
    if not f["checks_total"]:
        return "No checks were recorded."
    parts = ["%d of %d checks passed" % (f["checks_ok"], f["checks_total"])]
    if f["checks_warn"]:
        parts.append("%d with a warning" % f["checks_warn"])
    parts.append("%d failed" % f["checks_fail"] if f["checks_fail"] else "none failed")
    return " · ".join(parts)


def join_words(words):
    return ", ".join(words[:-1]) + " and " + words[-1] if len(words) > 1 else "".join(words)


def leak_section(f):
    out = []
    state, a = f["state"], f["analysis"]
    judged = f["leak_judged"] == "yes"
    if state != "pass":
        head = ("The test could not judge this run" if state == "blind" else "This run failed")
        rest = "so it does not count as a pass." if state == "blind" else (
            "The phone sent something outside Tor after the firewall went on." if f["leaks"] else "")
        if state == "blind" and f["leaks"] == 0:
            rest += " Nothing was seen leaking, but part of the evidence is missing."
        for p in f["problems"]:
            m = re.search(r"last frame of (\S+) is (\d+) s before", p)
            if m:
                rest += (" One recording of the phone's traffic (%s) has nothing in its last %s s, so packets "
                         "at the end may be missing." % (m.group(1), m.group(2)))
                break
        items = "".join("<li>%s</li>" % E(short(plain_problem(p), 400)) for p in f["problems"])
        out.append('<div class="callout %s" role="note"><p><strong>%s</strong>%s %s</p>%s</div>' % (
            "warn" if state == "blind" else "bad", E(head), "," if state == "blind" else ".", E(rest),
            '<p class="small">In the test\'s own words:</p><ul class="plain">%s</ul>' % items if items else ""))
    if a is None:
        out.append("<p>There is no leak analysis in this run: the recordings of the phone's traffic "
                   "are missing or could not be read.</p>")
    else:
        others = f["after_arm"] - f["to_tor"] if f["after_arm"] is not None and f["to_tor"] is not None else None
        leak_cls = "bad" if f["leaks"] else ("ok" if f["leaks"] == 0 and state == "pass" else "")
        out.append('<dl class="stats">'
                   '<div><dt>After the firewall went on</dt><dd>%s</dd></div>'
                   '<div><dt>To the Tor network</dt><dd>%s</dd></div>'
                   '<div><dt>Other, allowed</dt><dd>%s</dd></div>'
                   '<div class="%s"><dt>Leaks</dt><dd>%s</dd></div></dl>' % (
                       fmt_count(f["after_arm"]), fmt_count(f["to_tor"]),
                       fmt_count(None if others is None else max(0, others - (get(f, "post_arm", "LEAK") or 0))),
                       leak_cls, fmt_count(f["leaks"])))
        if not judged:
            why = ("The leak test could not run" if f["leak_judged"] == "error" else
                   "The recordings have no time after the firewall went on")
            out.append("<p>%s, so nothing can be said about leaks in this run.</p>" % E(why))
        if f["after_arm"] is not None:
            out.append("<p>After Antumbra's firewall was switched on, the phone sent %s packets; %s went to the "
                       "Tor network.</p>" % (fmt_count(f["after_arm"]), fmt_count(f["to_tor"])))
        rest = [(k, n) for k, n in sorted((f["post_arm"] or {}).items(), key=lambda kv: -kv[1])
                if k not in TOR_CLASSES and k != "LEAK" and n]
        if rest:
            words = ["%s %s" % (fmt_count(n), CLASS_WORDS.get(k, k)) for k, n in rest]
            text = "The rest: " + join_words(words) + "."
            kinds = {k for k, _ in rest}
            if kinds & {"lan-dhcp", "link-arp"}:
                text += " DHCP and ARP keep the Wi-Fi address working."
            if kinds & {"link-empty", "link-80211"}:
                text += " Empty frames and Wi-Fi joining frames belong to the Wi-Fi link itself."
            if kinds & {"lan-dhcp", "link-arp", "link-empty", "link-80211"}:
                text += " Android sends them outside the firewall by design, and they carry nothing of yours."
            out.append("<p>%s</p>" % E(text))
        if f["leaks"] == 0:
            out.append("<p>Leaks: <strong>0</strong>. A leak is anything the phone sent outside Tor, apart from "
                       "%s and the test's own clock markers.</p>" % E(HOUSEKEEPING))
        elif f["leaks"]:
            rows = "".join(
                "<tr><td class=\"where\">%s</td><td>%s</td><td class=\"num\">%s</td><td class=\"what\">%s</td>"
                "</tr>" % (dest_html(fl), E(KIND_WORDS.get(str(fl.get("kind")), str(fl.get("kind") or DASH))),
                           fmt_count(num(get(fl, "phases", "post-arm"))),
                           E(short(fl.get("reason") or DASH, 200))) for fl in f["leak_flows"][:12])
            pk = num(get(f, "post_arm", "LEAK"))
            out.append("<p><strong>%s leak%s</strong>%s: the phone sent these outside Tor after the firewall was "
                       "switched on.</p>" % (fmt_count(f["leaks"]), "" if f["leaks"] == 1 else "s",
                                             " (%s packet%s)" % (fmt_count(pk), "" if pk == 1 else "s") if pk else ""))
            out.append('<div class="table-wrap"><table><thead><tr><th scope="col">Where to</th>'
                       '<th scope="col">What</th><th scope="col">Packets</th><th scope="col">Why it counts</th>'
                       '</tr></thead><tbody>%s</tbody></table></div>' % rows)

        aw = f["armed"]
        st = aw["status"]
        out.append("<h3>Firewall closed, network up</h3>")
        what = ("the test closed the firewall again with Wi-Fi on and tried to get out: ping, a name lookup, "
                "a web page and a Tor relay, as the system and as an app.")
        if f["armed_measured"]:
            word = {"ok": ("ok", "Held"), "fail": ("bad", "Did not hold")}[st]
            sec = num(aw.get("seconds"))
            pk, allowed = f["armed_packets"], num(aw.get("allowed")) or 0
            sent = ("The phone sent nothing." if pk == 0 else
                    "The phone sent %s packet%s, %s of them link-level (ARP, DHCP, empty or Wi-Fi joining "
                    "frames)." % (fmt_count(pk), "" if pk == 1 else "s", fmt_count(allowed)) if pk is not None else "")
            out.append('<p><span class="chip %s">%s</span> %s %s %s</p>' % (
                word[0], word[1], E("For %s" % fmt_s(sec) if sec is not None and sec >= 5 else "For a while"),
                E(what), E(sent)))
        else:
            if f["leak_judged"] == "error":
                why = "This part could not be judged: the leak test could not run."
            elif st in (None, "not-asked"):
                why = "This part of the test was not asked for in this run."
            elif st == "not-run":
                why = "This part of the test did not run."
            elif st == "too-short":
                why = "The window was too short to judge (the test needs at least 5 s)."
            else:
                why = "This part could not be judged (%s)." % st
            out.append('<p><span class="chip warn">Not measured</span> %s In it, %s</p>' % (
                E(why), E(what.replace("closed", "closes").replace("tried", "tries"))))

    b = f["baseline"]
    out.append("<h3>Plain Android, for comparison</h3>")
    if b is None:
        out.append("<p>No recording of plain Android in this run.</p>")
    else:
        rows = baseline_rows(b)
        dn = get(b, "dns_names")
        names = sorted({d["name"] for d in dn if isinstance(d, dict) and isinstance(d.get("name"), str)
                        and d["name"]} if isinstance(dn, list) else set())
        ev = summary.events(os.path.join(f["root"], "baseline"))
        alone = (ev["wait_over"][0] - ev["clock_marker_after"][0]
                 if "wait_over" in ev and "clock_marker_after" in ev else None)
        # How long the recording ran: from its first frame (t = 0) to the
        # end of the capture, on the analysis' own time line.
        span = None
        evs = get(b, "events")
        for e in evs if isinstance(evs, list) else []:
            if isinstance(e, dict) and e.get("name") == "capture_stop" and num(e.get("t")) is not None:
                span = num(e.get("t"))
        if span is None:
            fl = get(b, "flows")
            lasts = [num(x.get("last")) for x in fl if isinstance(x, dict)] if isinstance(fl, list) else []
            span = max([x for x in lasts if x is not None], default=None)
        # The packets, the test's own markers left out, so that they add up
        # to the destinations below.
        out_total = num(get(b, "totals", "outbound"))
        fl = get(b, "flows")
        markers = sum(num(x.get("packets")) or 0 for x in fl if isinstance(x, dict) and x.get("class") == "ci-marker") \
            if isinstance(fl, list) else 0
        sent = out_total - markers if out_total is not None else (sum(r["packets"] for r in rows) if rows else None)
        listed_all = (num(get(b, "flows_total")) or 0) <= (len(fl) if isinstance(fl, list) else 0)
        would = sum(1 for r in rows if r["class"] == "LEAK")
        when = ""
        if span and span > 0:
            when = "from boot to the end of the recording (about %s" % fmt_s(span)
            when += ", %s of it left alone) " % fmt_s(alone) if alone and 0 < alone <= span + 5 else ") "
        text = "Without Antumbra, plain Android %ssent %s packets" % (when, fmt_count(sent))
        if rows:
            text += " to %s%d destinations" % ("" if listed_all else "at least ", len(rows))
        text += (" and looked up %d names: %s." % (
            len(names), ", ".join(names[:8]) + (", …" if len(names) > 8 else "")) if names else ".")
        if rows:
            text += " Under Antumbra, %d of these destinations would count as leaks." % would
        out.append("<p>%s</p>" % E(text))
        if rows:
            body = "".join("<tr><td class=\"what\">%s</td><td class=\"where\">%s</td><td class=\"num\">%s</td>"
                           "</tr>" % (E(what_is(r)), dest_html(r), fmt_count(r["packets"])) for r in rows[:40])
            out.append('<details><summary>Where plain Android\'s packets went</summary><div class="table-wrap">'
                       '<table><thead><tr><th scope="col">What it is</th><th scope="col">Where to</th>'
                       '<th scope="col">Packets</th></tr></thead><tbody>%s</tbody></table></div></details>' % body)
    return "\n    ".join(out)


def screen_cards(f, prev, prev_label, tmp):
    titles = {sid: (title, about) for sid, _, title, about in SCREENS}
    prev_screens = dict(prev["screens"]) if prev else {}
    cards, changed = [], 0
    for sid, path in f["screens"]:
        title, about = titles.get(sid, (sid.replace("-", " ").capitalize(), ""))
        now = jpeg(path, tmp)
        before_path = prev_screens.get(sid)
        frac = changed_fraction(before_path, path, tmp) if before_path else None
        # A pair that cannot be compared counts as changed, unless the
        # screenshots cannot be embedded at all (no ImageMagick).
        is_changed = bool(before_path) and (frac > CHANGED if frac is not None else now is not None)
        before = jpeg(before_path, tmp) if is_changed else None

        def fig(uri, alt, cap):
            img = ('<img src="%s" alt="%s" width="360">' % (uri, E(alt)) if uri
                   else '<p class="noimg">The screenshot could not be embedded.</p>')
            return "<figure>%s<figcaption>%s</figcaption></figure>" % (img, E(cap))
        if is_changed:
            changed += 1
            pair = (fig(before, "%s in %s" % (title, prev_label), "Before (%s)" % prev_label)
                    + fig(now, title + " now", "Now"))
            tag = "%.1f%% of the screen changed" % (frac * 100) if frac is not None else "changed"
        elif before_path and frac is None:
            pair = fig(now, title, "Now")
            tag = "not compared"
        elif before_path:
            pair = fig(now, title, "Unchanged since %s" % prev_label)
            tag = "unchanged"
        else:
            pair = fig(now, title, "Now")
            tag = "first time shown" if prev else ""
        cards.append('''<section class="screen%s" data-screen="%s">
  <header><h3>%s</h3>%s</header>
  %s
  <div class="pair">%s</div>
  <div class="verdict" hidden>
    <button type="button" data-v="right">Looks right</button>
    <button type="button" data-v="off">Looks off</button>
    <input type="text" id="note-%s" placeholder="A few words, if it looks off" maxlength="300">
    <span class="saved" aria-live="polite"></span>
  </div>
</section>''' % (" changed" if is_changed else "", E(sid), E(title),
                 '<span class="tag">%s</span>' % E(tag) if tag else "",
                 '<p class="small">%s</p>' % E(about) if about else "", pair, E(sid)))
    missing = [title for sid, _, title, _ in SCREENS if sid not in dict(f["screens"])]
    if missing and cards:
        cards.append('<p class="small">Not taken in this run: %s.</p>' % E(", ".join(missing)))
    return cards, changed


def number_rows(f, prev):
    """Rows of the numbers table: what, this run and, with a previous run,
    the change with the earlier value under it."""
    rows = []
    cols = 3 if prev else 2
    for (group, items), (_, before_items) in zip(numbers(f), numbers(prev)):
        rows.append('<tr class="group"><th scope="rowgroup" colspan="%d">%s</th></tr>' % (cols, E(group)))
        for (label, value, kind), (_, before, _) in zip(items, before_items):
            change = ""
            if prev:
                d, cls = delta(value, before, kind)
                was = "" if d == "same" else '<span class="was">was %s</span>' % E(fmt(before, kind))
                change = '<td class="delta %s">%s%s</td>' % (
                    cls, '<span class="d">%s</span>' % E(d) if d else "", was)
            rows.append('<tr><th scope="row">%s</th><td class="num">%s</td>%s</tr>' % (
                E(label), E(fmt(value, kind)), change))
    return "\n".join(rows)


def checks_html(f):
    look = []
    for s in SCENARIOS:
        where = "" if s == "antumbra" else "Plain Android: "
        for name, status, detail in f["checks"][s]:
            if status in ("warn", "fail"):
                look.append((0 if status == "fail" else 1, '<li class="%s"><span class="chip %s">%s</span> '
                             '<strong>%s</strong>%s</li>' % (
                                 "bad" if status == "fail" else "warn", "bad" if status == "fail" else "warn",
                                 "Failed" if status == "fail" else "Warning", E(where + plain_check(name, status)),
                                 '<span class="detail">%s</span>' % E(short(tidy_detail(detail))) if detail else "")))
    for w in f["warnings"]:
        if w.split(":", 1)[0] in SCENARIOS:
            continue  # a warning check, listed above
        look.append((2, '<li class="warn"><span class="chip warn">Note</span> <span>%s</span></li>' % E(
            short(plain_warning(w), 400))))
    look.sort(key=lambda x: x[0])
    if look:
        first = '<ul class="look">%s</ul>' % "".join(x[1] for x in look)
    elif f["checks_total"]:
        first = "<p>Nothing failed and nothing gave a warning.</p>"
    else:
        first = "<p>No checks were recorded in this run.</p>"
    full = []
    for s, heading in (("antumbra", "On the Antumbra phone"), ("baseline", "On plain Android")):
        cs = f["checks"][s]
        if not cs:
            continue
        items = "".join('<li class="%s"><span class="mark" aria-hidden="true">%s</span> %s <code>%s</code>%s</li>' % (
            {"ok": "ok", "warn": "warn"}.get(st, "bad"), {"ok": "✓", "warn": "!"}.get(st, "✗"),
            E(plain_check(n, st)), E(n),
            '<span class="detail">%s</span>' % E(short(tidy_detail(d), 200)) if d else "") for n, st, d in cs)
        full.append("<h3>%s</h3><ul class=\"checks\">%s</ul>" % (E(heading), items))
    all_html = ('<details><summary>All %d checks</summary>%s</details>' % (f["checks_total"], "".join(full))
                if full else "")
    return first + "\n    " + all_html


def question_html(question):
    if not isinstance(question, dict):
        return ""
    options = question.get("options")
    opts = "".join('<button type="button" data-choice="%s">%s%s</button>' % (
        E(str(o.get("id", ""))), E(str(o.get("label", ""))), " (recommended)" if o.get("recommended") else "")
        for o in (options if isinstance(options, list) else []) if isinstance(o, dict))
    return '''<section class="card" id="question">
    <h2>Today's question</h2>
    <p>%s</p>
    <div class="choices">%s</div>
    <p class="small">No answer in 48 hours means the recommended option.</p>
    <span class="saved" aria-live="polite"></span>
  </section>''' % (E(str(question.get("text", ""))), opts)


def parse_date(s):
    """(UTC datetime, has a time) from YYYY-MM-DD or an ISO date and time."""
    if s is None:
        return datetime.datetime.now(datetime.timezone.utc), True
    s = s.strip()
    try:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
            return datetime.datetime.strptime(s, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc), False
        d = datetime.datetime.fromisoformat(s[:-1] + "+00:00" if s.endswith("Z") else s)
    except ValueError:
        raise argparse.ArgumentTypeError("not a date: %r (YYYY-MM-DD or YYYY-MM-DDTHH:MM[:SS][Z])" % s)
    d = d.replace(tzinfo=datetime.timezone.utc) if d.tzinfo is None else d.astimezone(datetime.timezone.utc)
    return d, True


def sha_arg(s):
    """--sha: a commit id, 7 to 40 hex digits (it names undo/<sha>)."""
    s = s.strip().lower()
    if not re.fullmatch(r"[0-9a-f]{7,40}", s):
        raise argparse.ArgumentTypeError("not a commit id: %r (7 to 40 hex digits)" % s)
    return s


def metrics_doc(f, run_no, sha, subject, when, url):
    """The metrics/<run> document of this run (see the module docstring)."""
    return {
        "track": "android", "run": run_no, "sha": sha or None, "subject": subject or None,
        "date": when.strftime("%Y-%m-%d"), "url": url or None, "verdict": f["state"],
        "passed": f["checks_ok"], "warned": f["checks_warn"], "failed": f["checks_fail"],
        "total": f["checks_total"],
        "tor_bootstrap_s": f["tor_s"],
        "packets_after_arm": f["after_arm"], "packets_to_tor": f["to_tor"], "leaks": f["leaks"],
        "armed_packets": f["armed_packets"],
    }


def build(args):
    f = facts(args.run)
    prev = None
    if args.prev:
        if os.path.isdir(args.prev):
            prev = facts(args.prev)
        else:
            print("%s: not a directory, built without a comparison" % args.prev, file=sys.stderr)
    question = summary.read_json(args.question) if args.question else None
    run_no = args.run_number if args.run_number is not None else f["run_hint"]
    if run_no is None:
        sys.exit("%s: no run number in the artifact; give --run-number" % args.run)
    prev_no = args.prev_run_number if args.prev_run_number is not None else (prev or {}).get("run_hint")
    prev_label = "run %d" % prev_no if prev_no is not None else "the run before"
    sha_full = args.sha or ""
    sha = sha_full[:12]
    subject = (args.subject or "").strip()
    url = (args.run_url or "").strip()
    url = url if re.match(r"https?://", url) else ""
    when, has_time = args.date
    when_text = when.strftime("%a %d %b %Y, %H:%M UTC" if has_time else "%a %d %b %Y")

    with tempfile.TemporaryDirectory() as tmp:
        cards, n_changed = screen_cards(f, prev, prev_label, tmp)
    cls, word = pill(f["state"])
    change = ""
    if subject or sha:
        change = "<p>Change tested: <strong>%s</strong>%s</p>" % (
            E(subject) or "(no description)", ' <span class="small mono">(%s)</span>' % E(sha[:7]) if sha else "")
    compared = ("Compared with %s." % E(prev_label)) if prev else "No earlier run to compare with."
    link = ' <a href="%s" target="_blank" rel="noopener">The run on GitHub</a>.' % E(url) if url else ""
    data = {"run": run_no, "sha": sha, "subject": subject, "screens": [sid for sid, _ in f["screens"]],
            "question": question if isinstance(question, dict) else None}
    values = {
        "WHEN": E(when_text), "RUN": E(str(run_no)), "STATE": cls, "RESULT": E(word),
        "CHECKS_LINE": E(checks_line(f)), "CHANGE": change, "COMPARED": compared, "LINK": link,
        "NOVERDICT": ('<p class="small">The artifact has no verdict.json: the result was worked out from '
                      'its other files.</p>' if not f["verdict_file"] else ""),
        "QUESTION": question_html(question), "LEAK": leak_section(f),
        "SCREENS": "\n".join(cards) or "<p>No screenshots in this run.</p>",
        "NUM_HEAD": '<th scope="col">This run</th>%s' % (
            '<th scope="col">Since %s</th>' % E(prev_label) if prev else ""),
        "NUMBERS": number_rows(f, prev), "CHECKS": checks_html(f),
        "DATA": json.dumps(data).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026"),
    }
    # One pass over the template: a value that holds "{{SCREENS}}" (a
    # subject, a question) stays as it is.
    page = re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: values[m.group(1)], TEMPLATE)
    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(page)
    if args.metrics_out:
        with open(args.metrics_out, "w", encoding="utf-8") as fh:
            json.dump(metrics_doc(f, run_no, sha_full, subject, when, url), fh, indent=1)
            fh.write("\n")
    print("%s: run %s, %s, %s, %d screens, %d changed, %d bytes" % (
        args.out, run_no, f["state"], checks_line(f), len(f["screens"]), n_changed, len(page)))
    return f


TEMPLATE = r"""<title>Antumbra Daily</title>
<style>
/* One column of cards: the verdict, the leak test, the screens (before and
   after), the numbers, the checks, the history, the controls. Palette:
   Antumbra's own Material 3 tones, as on the Debian track's page. */
:root {
  --bg: #fdf8ff; --surface: #f4eef9; --surface-2: #ebe4f2; --fg: #1d1a22; --muted: #4d4757;
  --line: #d5cde0; --accent: #5a3ea6; --accent-soft: #e9ddff; --on-accent-soft: #23005c;
  --ok: #1f6b3a; --ok-bg: #dcf3e2; --bad: #9b2c1f; --bad-bg: #fbe0dc; --warn: #7a4b00; --warn-bg: #ffe9c2;
  --sans: "Roboto Flex", Roboto, "Segoe UI", system-ui, -apple-system, sans-serif;
  --mono: "Roboto Mono", ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #141218; --surface: #1d1a22; --surface-2: #29252f; --fg: #e8e0ee; --muted: #c9c1d4;
    --line: #3d3747; --accent: #cfbcff; --accent-soft: #3d2a73; --on-accent-soft: #eaddff;
    --ok: #9fdcb0; --ok-bg: #173323; --bad: #f6b0a5; --bad-bg: #431a14; --warn: #f5c97a; --warn-bg: #3d2c0b;
    color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --bg: #141218; --surface: #1d1a22; --surface-2: #29252f; --fg: #e8e0ee; --muted: #c9c1d4;
  --line: #3d3747; --accent: #cfbcff; --accent-soft: #3d2a73; --on-accent-soft: #eaddff;
  --ok: #9fdcb0; --ok-bg: #173323; --bad: #f6b0a5; --bad-bg: #431a14; --warn: #f5c97a; --warn-bg: #3d2c0b;
  color-scheme: dark;
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--fg); font-family: var(--sans); font-size: 1rem; line-height: 1.5; }
.wrap { max-width: 44rem; margin: 0 auto; padding-inline: 16px; padding-block: 20px 48px; display: grid; gap: 18px; }
.wrap > *, .screens > * { min-width: 0; }
h1 { font-size: 1.6rem; line-height: 1.2; margin: 0; font-weight: 650; }
h2 { font-size: 1.15rem; margin: 0 0 8px; }
h3 { font-size: 1rem; margin: 14px 0 6px; }
h1, h2, h3 { text-wrap: balance; }
p { margin: 0 0 8px; max-width: 65ch; }
.top { display: grid; gap: 8px; }
.top p { margin: 0; }
.eyebrow { font-size: 0.8rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); margin: 0; }
.verdict-row { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 12px; }
.result { display: inline-block; font-weight: 650; padding: 4px 12px; border-radius: 999px; }
.result.ok, .chip.ok { color: var(--ok); background: var(--ok-bg); }
.result.bad, .chip.bad { color: var(--bad); background: var(--bad-bg); }
.result.warn, .chip.warn { color: var(--warn); background: var(--warn-bg); }
.chip { display: inline-block; font-size: 0.75rem; font-weight: 650; padding: 1px 8px; border-radius: 999px; margin-right: 4px; white-space: nowrap; }
.small, .note { font-size: 0.875rem; color: var(--muted); }
.mono, code { font-family: var(--mono); font-size: 0.85em; overflow-wrap: anywhere; }
.card { background: var(--surface); border-radius: 18px; padding: 16px; }
.card > :last-child { margin-bottom: 0; }
.callout { border-radius: 12px; padding: 10px 14px; margin-bottom: 12px; }
.callout.bad { background: var(--bad-bg); color: var(--fg); }
.callout.warn { background: var(--warn-bg); color: var(--fg); }
.callout p { margin: 0 0 6px; }
ul.plain { margin: 0; padding-left: 1.2rem; font-size: 0.875rem; overflow-wrap: anywhere; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(8.5rem, 1fr)); gap: 8px; margin: 0 0 12px; }
.stats > div { background: var(--bg); border-radius: 12px; padding: 8px 12px; }
.stats dt { font-size: 0.8rem; color: var(--muted); }
.stats dd { margin: 0; font-size: 1.35rem; font-weight: 650; font-variant-numeric: tabular-nums; }
.stats .ok dd { color: var(--ok); }
.stats .bad dd { color: var(--bad); }
.screens { display: grid; gap: 18px; }
.screen { background: var(--surface); border-radius: 18px; padding: 14px; display: grid; gap: 10px; }
.screen.changed { outline: 2px solid var(--accent); }
.screen header { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 6px; }
.screen header h3 { margin: 0; }
.screen p.small { margin: 0; }
.tag { font-size: 0.8rem; color: var(--muted); }
.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; max-width: 610px; }
figure { margin: 0; min-width: 0; max-width: 300px; }
figure img { width: 100%; max-width: 100%; height: auto; display: block; border-radius: 12px; border: 1px solid var(--line); }
figcaption { font-size: 0.8rem; color: var(--muted); margin-top: 4px; }
.noimg { font-size: 0.875rem; color: var(--muted); border: 1px dashed var(--line); border-radius: 12px; padding: 24px 12px; margin: 0; }
.verdict { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
button { font: inherit; font-size: 0.9rem; padding: 7px 14px; border-radius: 999px; border: 1px solid var(--line);
  background: var(--bg); color: var(--fg); cursor: pointer; }
button[aria-pressed="true"] { background: var(--accent-soft); color: var(--on-accent-soft); border-color: transparent; font-weight: 600; }
button:focus-visible, input:focus-visible, summary:focus-visible, a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
input[type="text"] { font: inherit; font-size: 0.9rem; flex: 1 1 12rem; min-width: 0; padding: 7px 10px;
  border-radius: 10px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); }
input[type="file"] { max-width: 100%; font: inherit; font-size: 0.875rem; }
.saved { font-size: 0.8rem; color: var(--muted); }
.table-wrap { overflow-x: auto; margin-bottom: 8px; }
table { border-collapse: collapse; width: 100%; font-size: 0.9rem; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 7px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th[scope="row"] { font-weight: 500; }
tr.group th { font-size: 0.75rem; letter-spacing: 0.06em; text-transform: uppercase; color: var(--muted); font-weight: 600; padding-top: 14px; }
td.num { white-space: nowrap; }
td.where { font-family: var(--mono); font-size: 0.8rem; }
td.what { overflow-wrap: anywhere; }
.delta { color: var(--muted); }
.delta .d, .delta .was { display: block; white-space: nowrap; }
.delta .was { font-size: 0.8rem; }
.delta.up .d, .delta.down .d { color: var(--fg); font-weight: 600; }
ul.look { list-style: none; margin: 0 0 12px; padding: 0; display: grid; gap: 8px; }
ul.look li { background: var(--bg); border-radius: 12px; padding: 8px 12px; overflow-wrap: anywhere; }
.detail { display: block; font-size: 0.8rem; color: var(--muted); margin-top: 2px; overflow-wrap: anywhere; }
ul.checks { list-style: none; margin: 0; padding: 0; font-size: 0.875rem; display: grid; gap: 4px; }
ul.checks li { overflow-wrap: anywhere; }
ul.checks code { color: var(--muted); }
ul.checks .mark { display: inline-block; width: 1.2em; font-weight: 700; }
ul.checks li.ok .mark { color: var(--ok); }
ul.checks li.warn .mark { color: var(--warn); }
ul.checks li.bad .mark, ul.checks li.bad { color: var(--bad); }
details summary { cursor: pointer; font-weight: 600; }
details[open] summary { margin-bottom: 6px; }
.controls { display: grid; gap: 10px; }
.controls h2, .controls h3, .controls p { margin: 0; }
.row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 8px; margin-top: 8px; }
.photos img { width: 100%; height: auto; border-radius: 10px; border: 1px solid var(--line); }
.choices { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; }
#ctl-state { background: var(--warn-bg); border-radius: 12px; padding: 8px 12px; overflow-wrap: anywhere; }
/* The history: one row of numbers per run, the change it tested on a row
   of its own under it. On a phone each run is a small block, its numbers
   two by two with their labels. */
table.history td { white-space: nowrap; }
table.history tr.has-subj td { border-bottom: 0; padding-bottom: 0; }
table.history tr.subj td { white-space: normal; color: var(--muted); overflow-wrap: anywhere; padding-top: 2px; }
@media (max-width: 40rem) {
  table.history, table.history tbody, table.history tr, table.history td { display: block; }
  table.history thead { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
  table.history tr { display: grid; grid-template-columns: 1fr 1fr; gap: 6px 12px; padding: 10px 0; border-bottom: 1px solid var(--line); }
  table.history tr.has-subj { border-bottom: 0; padding-bottom: 4px; }
  table.history tr.subj { display: block; padding: 0 0 10px; }
  table.history td, table.history tr.subj td { border: 0; padding: 0; min-width: 0; white-space: normal; }
  table.history td::before { content: attr(data-label); display: block; font-size: 0.75rem; color: var(--muted); }
  table.history tr.subj td::before { content: none; }
}
a { color: var(--accent); }
</style>

<div class="wrap">
  <header class="top">
    <p class="eyebrow">Antumbra Daily · {{WHEN}}</p>
    <h1>Test run {{RUN}}</h1>
    <p class="verdict-row"><span class="result {{STATE}}">{{RESULT}}</span><span class="small">{{CHECKS_LINE}}</span></p>
    {{CHANGE}}
    {{NOVERDICT}}
    <p class="small">This is a virtual Android 16 phone that GitHub starts for each change, not the real phone: its simulated mobile data is switched off, so it uses Wi-Fi only, and Antumbra is started by hand after boot. {{COMPARED}}{{LINK}}</p>
  </header>

  {{QUESTION}}

  <section class="card" aria-labelledby="leak-h">
    <h2 id="leak-h">The leak test</h2>
    {{LEAK}}
  </section>

  <section aria-labelledby="screens-h">
    <h2 id="screens-h">Screens</h2>
    <p class="small">A screen with a coloured border changed since the run before. Tap a verdict; "Looks off" means it is undone or adjusted the next morning.</p>
    <div class="screens">{{SCREENS}}</div>
  </section>

  <section class="card" aria-labelledby="num-h">
    <h2 id="num-h">Numbers</h2>
    <div class="table-wrap"><table>
      <thead><tr><th scope="col">What</th>{{NUM_HEAD}}</tr></thead>
      <tbody>{{NUMBERS}}</tbody>
    </table></div>
    <p class="small">How long Tor takes depends on the network that day; a change below 20% is noise. A dash means the run did not record that number.</p>
  </section>

  <section class="card" aria-labelledby="checks-h">
    <h2 id="checks-h">Checks</h2>
    {{CHECKS}}
  </section>

  <section class="card" id="history" aria-labelledby="history-h" hidden>
    <h2 id="history-h">Recent runs</h2>
    <div class="table-wrap"><table class="history"><thead><tr><th scope="col">Run</th><th scope="col">Result</th><th scope="col">Checks passed</th><th scope="col">Tor connected after</th><th scope="col">After the firewall went on (to Tor)</th><th scope="col">Leaks</th></tr></thead><tbody id="history-rows"></tbody></table></div>
    <p class="small">Under each run, the change it tested. "After the firewall went on": the packets the phone sent once Antumbra's firewall was on, and in brackets how many of them went to the Tor network.</p>
  </section>

  <section class="card controls" aria-labelledby="ctl-h">
    <h2 id="ctl-h">Controls</h2>
    <p id="ctl-state" hidden></p>
    <p class="small" id="ctl-off">The buttons work when you open this page signed in to Claude.</p>
    <div class="row" id="ctl-row" hidden>
      <button type="button" id="undo" aria-pressed="false">Undo this change</button>
      <button type="button" id="pause" aria-pressed="false">Pause changes</button>
      <button type="button" id="stop" aria-pressed="false">Stop the morning routine</button>
      <span class="saved" id="ctl-saved" aria-live="polite"></span>
    </div>
    <p class="small" id="undo-off" hidden>No commit was given for this run, so its change cannot be undone from here.</p>
    <p class="small">Undo reverts this change tomorrow morning. Pause: the routine still reports but changes nothing. Stop: it ends at once (for holidays).</p>
    <div id="photo-box" hidden>
      <h3>A photo of the phone</h3>
      <p class="small">For what the virtual phone cannot show: photograph the real phone's screen and add it here with a few words.</p>
      <div class="row">
        <input type="file" id="photo" accept="image/*">
        <input type="text" id="photo-note" placeholder="What is wrong in the photo" maxlength="300">
        <button type="button" id="photo-send">Add photo</button>
        <span class="saved" id="photo-saved" aria-live="polite"></span>
      </div>
      <div class="photos" id="photos"></div>
    </div>
  </section>
</div>

<script>
const RUN = {{DATA}};
const stamp = () => new Date().toISOString();
function say(el, text) { if (el) { el.textContent = text; } }
const WORD = { pass: "passed", fail: "failed", blind: "could not judge" };
const LABELS = ["Run", "Result", "Checks passed", "Tor connected after", "After the firewall went on (to Tor)", "Leaks"];
function cellsOf(r) {
  // tor_bootstrap_s is stored in whole seconds; older rows may hold tenths.
  const n = (x) => (typeof x === "number" ? x.toLocaleString("en") : "–");
  const result = r.verdict ? (WORD[r.verdict] || String(r.verdict)) : (r.track ? "–" : "Debian VM");
  const after = r.packets_after_arm == null ? "–" : n(r.packets_after_arm) + (r.packets_to_tor == null ? "" : " (" + n(r.packets_to_tor) + ")");
  return [r.run ?? "–", result, (r.passed ?? "–") + "/" + (r.total ?? "–"),
          typeof r.tor_bootstrap_s === "number" ? Math.round(r.tor_bootstrap_s) + " s" : "–",
          after, r.leaks == null ? "–" : n(r.leaks), r.subject || ""];
}
function when(at) {
  const d = new Date(at);
  return isNaN(d) ? "" : d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}
async function boot() {
  const db = window.claude ? await window.claude.use("db") : null;
  if (!db) return;

  // Run history, written by the routine (shown to every reader).
  db.collection("metrics").orderBy("run", "desc").limit(10).onSnapshot(qs => {
    if (qs.empty) return;
    const body = document.getElementById("history-rows");
    body.textContent = "";
    for (const d of qs.docs) {
      const cells = cellsOf(d.data() || {}), subject = cells.pop();
      const tr = document.createElement("tr");
      cells.forEach((c, i) => {
        const td = document.createElement("td");
        td.textContent = String(c);
        td.dataset.label = LABELS[i];
        tr.appendChild(td);
      });
      body.appendChild(tr);
      if (subject) {
        tr.className = "has-subj";
        const sr = document.createElement("tr"), td = document.createElement("td");
        sr.className = "subj";
        td.colSpan = cells.length;
        td.textContent = subject;
        sr.appendChild(td);
        body.appendChild(sr);
      }
    }
    document.getElementById("history").hidden = false;
  }, () => {});

  // Whether the routine is paused or stopped, in words, for every reader.
  // controls/state may hold more than the page writes (a "reason" from the
  // planning session): it is shown and kept.
  const ctlRef = db.doc("controls/state");
  let ctl = {};
  const stateLine = document.getElementById("ctl-state");
  ctlRef.onSnapshot(s => {
    ctl = s.exists ? Object.assign({}, s.data()) : {};
    document.getElementById("pause").setAttribute("aria-pressed", String(!!ctl.pause));
    document.getElementById("stop").setAttribute("aria-pressed", String(!!ctl.stop));
    const parts = [];
    if (ctl.stop) parts.push("The morning routine is stopped.");
    if (ctl.pause) parts.push("Changes are paused" + (typeof ctl.reason === "string" && ctl.reason.trim() ? ": " + ctl.reason.trim() : "") + (/[.!?]$/.test(String(ctl.reason || "").trim()) ? "" : "."));
    const at = ctl.at ? when(ctl.at) : "";
    stateLine.textContent = parts.join(" ") + (parts.length && at ? " (Last changed " + at + ".)" : "");
    stateLine.hidden = !parts.length;
  }, () => {});

  const user = await window.claude.use("user");
  if (user && user.can && (await user.can("data.write")) === false) return;
  document.getElementById("ctl-off").hidden = true;
  document.getElementById("ctl-row").hidden = false;

  // Verdicts on the screens.
  for (const sec of document.querySelectorAll("section.screen")) {
    const name = sec.dataset.screen, box = sec.querySelector(".verdict");
    const ref = db.doc("feedback/" + RUN.run + "_" + name);
    const note = box.querySelector("input"), saved = box.querySelector(".saved");
    box.hidden = false;
    let current = {};
    ref.onSnapshot(s => {
      current = s.exists ? Object.assign({}, s.data()) : {};
      for (const b of box.querySelectorAll("button")) b.setAttribute("aria-pressed", String(current.verdict === b.dataset.v));
      if (document.activeElement !== note) note.value = current.note || "";
    }, () => {});
    const write = async (patch) => {
      try {
        const doc = Object.assign({ run: RUN.run, screen: name, verdict: current.verdict || null, note: note.value.trim() }, patch, { at: stamp() });
        await ref.set(doc);
        current = doc;
        say(saved, "Saved");
      } catch (e) { say(saved, "Not saved: " + (e && e.code || "error")); }
    };
    for (const b of box.querySelectorAll("button")) b.addEventListener("click", () => write({ verdict: b.dataset.v }));
    note.addEventListener("change", () => write({}));
  }

  // Undo, Pause, Stop.
  const saved = document.getElementById("ctl-saved");
  const undo = document.getElementById("undo");
  if (RUN.sha) {
    const undoRef = db.doc("undo/" + RUN.sha);
    undoRef.onSnapshot(s => undo.setAttribute("aria-pressed", String(s.exists)), () => {});
    undo.addEventListener("click", async () => {
      try {
        if (undo.getAttribute("aria-pressed") === "true") { await undoRef.delete(); say(saved, "Undo cancelled"); }
        else { await undoRef.set({ sha: RUN.sha, subject: RUN.subject, run: RUN.run, at: stamp() }); say(saved, "This change will be undone tomorrow morning"); }
      } catch (e) { say(saved, "Not saved: " + (e && e.code || "error")); }
    });
  } else {
    undo.hidden = true;
    document.getElementById("undo-off").hidden = false;
  }
  for (const key of ["pause", "stop"]) {
    document.getElementById(key).addEventListener("click", async () => {
      try {
        await ctlRef.set(Object.assign({}, ctl, { pause: !!ctl.pause, stop: !!ctl.stop, [key]: !ctl[key], at: stamp() }));
        say(saved, key === "pause" ? (!ctl.pause ? "Changes paused" : "Changes resumed") : (!ctl.stop ? "Morning routine stopped" : "Morning routine on again"));
      } catch (e) { say(saved, "Not saved: " + (e && e.code || "error")); }
    });
  }

  // Today's question.
  const q = document.getElementById("question");
  if (q && RUN.question && RUN.question.id) {
    const ref = db.doc("answers/" + RUN.question.id), out = q.querySelector(".saved");
    ref.onSnapshot(s => {
      const c = s.exists ? s.data().choice : null;
      for (const b of q.querySelectorAll("button")) b.setAttribute("aria-pressed", String(b.dataset.choice === c));
    }, () => {});
    for (const b of q.querySelectorAll("button")) b.addEventListener("click", async () => {
      try { await ref.set({ choice: b.dataset.choice, at: stamp() }); say(out, "Saved"); }
      catch (e) { say(out, "Not saved: " + (e && e.code || "error")); }
    });
  }

  // Photos of the phone.
  const assets = await window.claude.use("assets");
  if (!assets) return;
  document.getElementById("photo-box").hidden = false;
  const grid = document.getElementById("photos"), psaved = document.getElementById("photo-saved");
  db.collection("photos").orderBy("at", "desc").limit(12).onSnapshot(qs => {
    grid.textContent = "";
    for (const d of qs.docs) {
      const r = d.data(), fig = document.createElement("figure"), img = document.createElement("img"), cap = document.createElement("figcaption");
      img.src = "/_blob/" + r.asset; img.alt = r.note || "Photo of the phone"; cap.textContent = r.note || "";
      fig.append(img, cap); grid.appendChild(fig);
    }
  }, () => {});
  document.getElementById("photo-send").addEventListener("click", async () => {
    const file = document.getElementById("photo").files[0];
    if (!file) { say(psaved, "Choose a photo first"); return; }
    say(psaved, "Uploading…");
    try {
      const up = await assets.upload(file);
      await db.collection("photos").doc(up.id).set({ asset: up.id, note: document.getElementById("photo-note").value.trim(), run: RUN.run, at: stamp() });
      document.getElementById("photo").value = ""; document.getElementById("photo-note").value = "";
      say(psaved, "Added");
    } catch (e) { say(psaved, "Not added: " + (e && e.code || "error")); }
  });
}
boot();
</script>
"""


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", required=True, help="the newest run's unpacked artifact (antumbra-android-<n>)")
    ap.add_argument("--prev", help="the run before it, to compare with")
    ap.add_argument("--question", help="JSON {id, text, options: [{id, label, recommended}]}")
    ap.add_argument("--out", required=True, help="the page to write")
    ap.add_argument("--run-number", type=int, help="the run's number (default: from its DNS filter's version)")
    ap.add_argument("--prev-run-number", type=int, help="the previous run's number (default: the same way)")
    ap.add_argument("--sha", type=sha_arg, help="the commit the run tested (without it, Undo is off)")
    ap.add_argument("--subject", help="that commit's subject line")
    ap.add_argument("--run-url", help="the run's page on GitHub")
    ap.add_argument("--date", type=parse_date, default=None, help="YYYY-MM-DD or an ISO time, UTC (default: now)")
    ap.add_argument("--metrics-out", help="also write this run's metrics/<run> document here")
    args = ap.parse_args(argv)
    if args.date is None:
        args.date = parse_date(None)
    if not os.path.isdir(args.run):
        ap.error("%s: not a directory" % args.run)
    build(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
