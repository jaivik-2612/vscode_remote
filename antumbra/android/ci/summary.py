#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra CI: the emulator job's summary and its final verdict.

  summary.py REPORT_DIR [--run N]
      Writes REPORT_DIR/summary.md and prints it (for $GITHUB_STEP_SUMMARY).
  summary.py REPORT_DIR --verdict [--no-fail]
      Writes REPORT_DIR/verdict.json and exits 1 unless both scenarios ran
      to the end with no failed check, the baseline capture saw the phone,
      and the ANTUMBRA scenario's leak analysis passed. With --no-fail it
      exits 0 either way (the workflow writes verdict.json before the
      artifact is uploaded, and fails the job afterwards with --check).
  summary.py REPORT_DIR --check
      Reads REPORT_DIR/verdict.json, prints its problems and exits 1 unless
      it says ok (also when it is missing or unreadable).

REPORT_DIR is the artifact's root: <scenario>/{result,checks.tsv,
events.tsv,analysis.json,...}, leak-report.json, screenshots/, build/.
"""

import argparse
import glob
import json
import os
import sys

sys.dont_write_bytecode = True

SCENARIOS = ("baseline", "antumbra")
WORD = {"pass": "PASS", "fail": "FAIL", "blind": "BLIND (capture incomplete)", "error": "ERROR",
        "info": "INFORMATION"}


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def read_json(path):
    t = read_text(path)
    if t is None:
        return None
    try:
        return json.loads(t)
    except ValueError:
        return None


def checks(sdir):
    out = []
    t = read_text(os.path.join(sdir, "checks.tsv")) or ""
    for line in t.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            out.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))
    return out


def events(sdir):
    out = {}
    t = read_text(os.path.join(sdir, "events.tsv")) or ""
    for line in t.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            try:
                out.setdefault(parts[0], (float(parts[1]), parts[2] if len(parts) > 2 else ""))
            except ValueError:
                pass
    return out


def judge(root):
    """(ok, problems, per-scenario facts)."""
    problems = []
    facts = {}
    for s in SCENARIOS:
        sdir = os.path.join(root, s)
        f = facts[s] = {"ran": os.path.isdir(sdir), "result": None, "checks": checks(sdir),
                        "analysis": read_json(os.path.join(sdir, "analysis.json"))}
        r = read_text(os.path.join(sdir, "result"))
        f["result"] = r.strip() if r else None
        if not f["ran"] or f["result"] is None:
            problems.append("the %s scenario did not run to the end (did the emulator start?)" % s)
        elif f["result"] != "0":
            failed = [c for c in f["checks"] if c[1] == "fail"]
            problems.append("the %s scenario failed: %s" % (
                s, "; ".join("%s (%s)" % (c[0], c[2]) for c in failed) or "exit status %s" % f["result"]))
        a = f["analysis"]
        if a is None:
            problems.append("no leak analysis for the %s scenario (no capture?)" % s)
            continue
        v = a.get("verdict")
        if s == "baseline" and v not in ("info", "pass"):
            problems.append("baseline capture: %s: %s" % (WORD.get(v, v), "; ".join(a.get("verdict_reasons", []))))
        if s == "antumbra" and v != "pass":
            problems.append("leak test: %s: %s" % (WORD.get(v, v), "; ".join(a.get("verdict_reasons", []))))
    return not problems, problems, facts


def warnings(facts):
    """What is worth a look but does not fail the run: warning checks, and
    names or destinations through Tor that are not on the expected list
    while that list is being learned."""
    out = []
    for s in SCENARIOS:
        for c in facts[s]["checks"]:
            if c[1] == "warn":
                out.append("%s: %s: %s" % (s, c[0], c[2]))
    a = facts["antumbra"]["analysis"] or {}
    d = a.get("destinations") or {}
    if d.get("mode") != "strict":
        for u in d.get("unexpected", []):
            out.append("through Tor, not on the expected list: " + u)
        if d and not (d.get("sources") or {}).get("tor_streams"):
            out.append("tor's STREAM events were not recorded: destinations through Tor are unknown")
    return out


def esc(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def dest(r):
    d = r.get("dst") or "?"
    if r.get("l3") == "ipv6":
        d = "[%s]" % d
    if r.get("dport") is not None:
        d += ":%s" % r["dport"]
    return d


def summary(root, run):
    ok, problems, facts = judge(root)
    L = ["# Antumbra on Android: CI run %s: %s" % (run or "?", "PASS" if ok else "FAIL"), ""]
    L.append("| Scenario | Ran to the end | Checks | Leak analysis |")
    L.append("|---|---|---|---|")
    for s in SCENARIOS:
        f = facts[s]
        cs = f["checks"]
        counts = ", ".join("%d %s" % (sum(1 for c in cs if c[1] == k), k) for k in ("ok", "warn", "fail")
                           if any(c[1] == k for c in cs)) or "none"
        a = f["analysis"]
        if a:
            ana = "%s: %s" % (WORD.get(a.get("verdict"), a.get("verdict")), "; ".join(a.get("verdict_reasons", [])))
        else:
            ana = "not run"
        ran = "yes" if f["result"] == "0" else ("no (exit %s)" % f["result"] if f["result"] else "no")
        L.append("| %s | %s | %s | %s |" % (s, ran, counts, esc(ana)))
    L.append("")
    if problems:
        L.append("**Problems:**")
        L.append("")
        for p in problems:
            L.append("- " + esc(p))
        L.append("")

    # The ANTUMBRA scenario in a few lines.
    adir = os.path.join(root, "antumbra")
    ev = events(adir)
    a = facts["antumbra"]["analysis"]
    L.append("## Antumbra scenario")
    L.append("")
    if "module_live" in ev:
        L.append("- Module: %s." % (ev["module_live"][1] or "live"))
    if "welcome_start" in ev and "tor_bootstrapped" in ev:
        L.append("- Tor bootstrapped %.0f s after Start Antumbra (%s)." % (
            ev["tor_bootstrapped"][0] - ev["welcome_start"][0], ev["tor_bootstrapped"][1]))
    st = read_json(os.path.join(adir, "filter-status.json"))
    if st:
        lst = st.get("list") or {}
        L.append("- DNS filter: %s queries, %s blocked, %s forwarded, %s SERVFAIL; list version %s, %s domains." % (
            st.get("queries"), st.get("blocked"), st.get("forwarded"), st.get("servfail"),
            lst.get("version"), lst.get("size")))
    tt = read_json(os.path.join(adir, "tracker-test.json"))
    if tt:
        for t in tt.get("tests", []):
            if t.get("method") == "filter":
                r = t.get("result") or {}
                L.append("- Filter, `%s`%s: %s%s." % (
                    r.get("name") or t.get("name"), " (control)" if t.get("control") else "",
                    r.get("rcode") or r.get("error"),
                    ", blocked" if r.get("blocked") else (" " + ", ".join(r.get("answers", [])) if r.get("answers") else "")))
    if "wifi_default" in ev:
        L.append("- Network: Wi-Fi (%s), mobile data off." % (ev["wifi_default"][1] or "default"))
    if a:
        L.append("- Leak analysis: %d packets after arm, %d of them to the Tor network; %d LEAK flow(s)." % (
            sum((a.get("phases", {}).get("post-arm") or {}).values()), a.get("post_arm_tor_packets", 0),
            len(a.get("leaks", []))))
        cov = a.get("coverage", {})
        if cov.get("expected"):
            L.append("- Capture coverage: tor reported %d connection(s), the capture saw %d." % (
                len(cov["expected"]), len(cov.get("seen", []))))
        if cov.get("addresses"):
            L.append("- The device's addresses: %s; all seen sending in the capture: %s." % (
                ", ".join(cov["addresses"]), "no, missing " + ", ".join(cov["addresses_missing"])
                if cov.get("addresses_missing") else "yes"))
        aw = a.get("armed_window") or {}
        if aw.get("status") not in (None, "not-asked"):
            L.append("- Armed state with the network up: **%s** (%s s, %d packet(s) from the phone, %d of them "
                     "ARP or DHCP, %d LEAK)." % (aw.get("status"), aw.get("seconds", "?"), aw.get("packets", 0),
                                                aw.get("allowed", 0), aw.get("leaks", 0)))
        d = a.get("destinations")
        if d:
            L.append("- Through Tor: %d name(s) looked up, %d destination(s) asked of the TransPort; %d not on "
                     "the expected list (%s mode%s)." % (
                         len(d.get("names", [])), len(d.get("targets", [])), len(d.get("unexpected", [])),
                         d.get("mode"), "" if (d.get("sources") or {}).get("tor_streams")
                         else "; tor's STREAM events were not recorded"))
        leaks = a.get("leaks", [])
        if leaks:
            L.append("")
            L.append("| First (t+s) | Kind | Destination | Name | Packets after arm | Why |")
            L.append("|---|---|---|---|---|---|")
            for f in leaks[:30]:
                L.append("| %s | %s | `%s` | %s | %s | %s |" % (
                    f.get("first"), f.get("kind"), dest(f), esc(", ".join(f.get("names", [])[:2])),
                    f.get("phases", {}).get("post-arm", 0), esc(f.get("reason"))))
    L.append("")
    warns = warnings(facts)
    if warns:
        L.append("**Warnings (not judged):**")
        L.append("")
        for w in warns[:60]:
            L.append("- " + esc(w))
        L.append("")
    cs = facts["antumbra"]["checks"]
    if cs:
        L.append("| Check | Result | Detail |")
        L.append("|---|---|---|")
        for c in cs:
            L.append("| %s | %s | %s |" % (esc(c[0]), c[1], esc(c[2][:200])))
        L.append("")

    # The baseline: what plain Android contacted.
    b = facts["baseline"]["analysis"]
    L.append("## Baseline: plain Android 16 on its own")
    L.append("")
    if b:
        rows = {}
        for f in b.get("flows", []):
            if f.get("class") == "ci-marker":
                continue
            k = (f.get("proto"), f.get("dst"), f.get("dport"))
            r = rows.setdefault(k, {"l3": f.get("l3"), "dst": f.get("dst"), "dport": f.get("dport"),
                                    "proto": f.get("proto"), "packets": 0, "names": set(),
                                    "class": f.get("class"), "kind": f.get("kind")})
            r["packets"] += f.get("packets", 0)
            r["names"].update(f.get("names", []))
        L.append("%d destination(s) in %d packets. Under Antumbra, each would be:" % (
            len(rows), b.get("totals", {}).get("outbound", 0)))
        L.append("")
        L.append("| Proto | Destination | Names | Packets | Under Antumbra |")
        L.append("|---|---|---|---|---|")
        for r in sorted(rows.values(), key=lambda r: -r["packets"])[:40]:
            L.append("| %s | `%s` | %s | %d | %s |" % (r["proto"], dest(r), esc(", ".join(sorted(r["names"])[:3])),
                                                      r["packets"], r["class"] + (" (%s)" % r["kind"] if r["kind"] else "")))
        names = sorted({d["name"] for d in b.get("dns_names", [])})
        if names:
            L.append("")
            L.append("Names looked up: " + ", ".join("`%s`" % n for n in names[:60]) + ".")
    else:
        L.append("No analysis.")
    L.append("")

    shots = sorted(os.path.relpath(p, root) for p in glob.glob(os.path.join(root, "screenshots", "*.png")))
    L.append("## In the artifact")
    L.append("")
    L.append("- Screenshots: " + (", ".join("`%s`" % s for s in shots) if shots else "none") + ".")
    L.append("- `verdict.json`, `leak-report.md` and `leak-report.json` (both scenarios, every flow, the armed "
             "window, the names and destinations through Tor), `capture/` (the captures, cut to 256 bytes per "
             "frame, and the full ones if they fit), `antumbra/` (tor's STREAM events, the filter's query log, "
             "the probes), `logs/`.")
    L.append("")
    builds = sorted(glob.glob(os.path.join(root, "build", "*.md")))
    if builds:
        L.append("## Builds")
        L.append("")
        for p in builds:
            L.append((read_text(p) or "").strip())
            L.append("")
    text = "\n".join(L) + "\n"
    with open(os.path.join(root, "summary.md"), "w", encoding="utf-8") as f:
        f.write(text)
    return text


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("root")
    ap.add_argument("--run")
    ap.add_argument("--verdict", action="store_true")
    ap.add_argument("--no-fail", action="store_true")
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args(argv)
    if a.check:
        v = read_json(os.path.join(a.root, "verdict.json"))
        if not isinstance(v, dict) or not isinstance(v.get("problems"), list):
            print("::error::no readable verdict.json in %s" % a.root)
            return 1
        for p in v["problems"]:
            print("::error::" + str(p).replace("\n", " "))
        print("verdict: %s" % ("PASS" if v.get("ok") is True else "FAIL"))
        return 0 if v.get("ok") is True else 1
    if a.verdict:
        ok, problems, facts = judge(a.root)
        with open(os.path.join(a.root, "verdict.json"), "w", encoding="utf-8") as f:
            json.dump({"ok": ok, "problems": problems, "warnings": warnings(facts)}, f, indent=1)
            f.write("\n")
        for p in problems:
            print("::error::" + p.replace("\n", " "))
        print("verdict: %s" % ("PASS" if ok else "FAIL"))
        return 0 if ok or a.no_fail else 1
    sys.stdout.write(summary(a.root, a.run))
    return 0


if __name__ == "__main__":
    sys.exit(main())
