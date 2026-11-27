#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the Antumbra QEMU test page for the second round (interface,
camera, Android apps): several VM runs on one image, the pop-up motor's
sleep test, what review and the VM found, what only the phone can show.

usage: make_report2.py SPEC.json OUT.html
SPEC: {"commit", "image", "runs": [{"id", "title", "what", "report", "note"?}],
       "genpd_log", "unit": {...}, "shots": [[png, caption]], "findings": [...],
       "vm_found": [...], "caveats": [...], "bundle": {...}?}
"""
import base64
import html
import json
import re
import sys

if len(sys.argv) != 2:
    sys.exit("usage: make_report2.py SPEC.json")
spec = json.load(open(sys.argv[1]))
E = html.escape


def img_uri(path):
    return "data:image/png;base64," + base64.b64encode(open(path, "rb").read()).decode()


def load_run(r):
    rep = json.load(open(r["report"]))
    checks = rep["checks"]
    return rep, checks, sum(1 for c in checks if c["ok"])


PHASES = [  # (label, test on the check name)
    ("Boot and the image", lambda n: n.startswith(("initramfs", "systemd", "debug console", "guest:", "display"))),
    ("Before the Welcome decision", lambda n: n.startswith(("network: no frame", "welcome: Start", "harness:"))),
    ("Android apps", lambda n: n.startswith(("android", "android-net"))),
    ("Persistent Storage", lambda n: n.startswith("persistence")),
    ("After Welcome: network and Tor", lambda n: n.startswith(("welcome:", "after Welcome", "packet capture", "Tor:", "with Android"))),
    ("Session", lambda n: n.startswith("tour")),
    ("Camera", lambda n: n.startswith("camera")),
    ("Power-off and amnesia", lambda n: n.startswith(("power key", "shutdown", "storage"))),
    ("Console", lambda n: n.startswith("console")),
]


def phase_of(name):
    for label, test in PHASES:
        if test(name):
            return label
    return "Other"


def genpd_cases(path):
    cases, cur = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.match(r"\[genpd-sleep-vm\.sh\] case (\d+): (.*)$", line.strip())
        if m:
            cur = {"n": m.group(1), "title": m.group(2), "checks": []}
            cases.append(cur)
            continue
        m = re.match(r"(PASS|FAIL)\s+(.*)$", line.strip())
        if m and cur is not None:
            cur["checks"].append((m.group(1) == "PASS", m.group(2)))
    return cases


runs = []
for r in spec["runs"]:
    rep, checks, ok = load_run(r)
    runs.append((r, rep, checks, ok))
cases = genpd_cases(spec["genpd_log"])
g_all = sum(len(c["checks"]) for c in cases)
g_ok = sum(1 for c in cases for ok, _ in c["checks"] if ok)

P = []
w = P.append
w("""<title>Antumbra QEMU Test Run</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&family=JetBrains+Mono:wght@400;500&display=swap">
<style>
/* Layout: a lab record of one image, several runs. The screens first, in phone
   frames; then what changed, the run ledger, each run's checks by phase, the
   motor's sleep test, what review and the VM caught, and what needs the phone. */
:root {
  --ground: #eceef3;      /* cool paper with an indigo bias */
  --panel: #f7f8fb;
  --ink: #161a2c;
  --muted: #586079;
  --rule: #d3d8e4;
  --corona: #b8731a;      /* the bright ring around an antumbra */
  --corona-soft: #f3e3c8;
  --violet: #5b4a9a;      /* the system's own accent, deepened for paper */
  --violet-soft: #e6e1f4;
  --pass: #2a7a52;
  --pass-soft: #dcefe4;
  --fail: #b23c2c;
  --fail-soft: #f6dcd6;
  --frame: #1d2132;
  --display: "Bricolage Grotesque", "Avenir Next", "Segoe UI", system-ui, sans-serif;
  --body: "IBM Plex Sans", "Segoe UI", system-ui, sans-serif;
  --mono: "JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #0f111a; --panel: #171a27; --ink: #e6e8f1; --muted: #98a0b9; --rule: #272b3d;
    --corona: #e5a24a; --corona-soft: #3a2c17; --violet: #cebdfe; --violet-soft: #2a2442;
    --pass: #5cc28c; --pass-soft: #173126; --fail: #e8735f; --fail-soft: #3b1d18; --frame: #05060a; color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --ground: #0f111a; --panel: #171a27; --ink: #e6e8f1; --muted: #98a0b9; --rule: #272b3d;
  --corona: #e5a24a; --corona-soft: #3a2c17; --violet: #cebdfe; --violet-soft: #2a2442;
  --pass: #5cc28c; --pass-soft: #173126; --fail: #e8735f; --fail-soft: #3b1d18; --frame: #05060a; color-scheme: dark;
}
* { box-sizing: border-box; }
body { background: var(--ground); color: var(--ink); font: 400 15px/1.55 var(--body); }
.wrap { max-width: 1120px; margin: 0 auto; padding-inline: 20px; padding-block: 28px 64px; }
header { display: grid; gap: 10px; margin-bottom: 26px; }
.mark { display: flex; align-items: center; gap: 14px; }
.ring { width: 34px; height: 34px; border-radius: 50%; flex: none;
  background: radial-gradient(circle at 50% 50%, var(--frame) 0 58%, var(--corona) 60% 72%, transparent 74%); }
h1 { font: 700 clamp(28px, 4.2vw, 44px)/1.05 var(--display); letter-spacing: -0.01em; margin: 0; text-wrap: balance; }
.sub { color: var(--muted); max-width: 72ch; margin: 0; }
.ledger { display: grid; grid-template-columns: repeat(auto-fit, minmax(138px, 1fr)); gap: 10px; margin-top: 10px; }
.tally { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; padding: 10px 12px; display: grid; gap: 2px; min-width: 0; }
.tally b { font: 700 24px/1.1 var(--display); font-variant-numeric: tabular-nums; }
.tally b.part { color: var(--corona); }
.tally span { font-size: 13px; color: var(--muted); }
.tally .k { font: 600 11px/1.2 var(--body); text-transform: uppercase; letter-spacing: .08em; color: var(--muted); }
.screens { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 22px 18px; margin: 8px 0 38px; }
figure { margin: 0; display: grid; gap: 8px; justify-items: center; align-content: start; }
.phone { background: var(--frame); border-radius: 26px; padding: 10px 8px 14px; max-width: 250px; width: 100%;
  box-shadow: 0 1px 0 var(--rule), 0 18px 40px -24px rgba(10, 12, 30, .55); }
.phone img { display: block; width: 100%; height: auto; border-radius: 16px; background: #000; }
figcaption { font-size: 13px; color: var(--muted); text-align: center; max-width: 30ch; }
.cols { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 16px; }
.feature { border-top: 3px solid var(--violet); padding-top: 10px; min-width: 0; }
.feature h3 { margin-top: 0; color: var(--ink); font: 700 17px/1.25 var(--display); text-transform: none; letter-spacing: 0; }
.feature ul { margin: 0; padding-left: 18px; }
.feature li { margin-bottom: 4px; }
section { margin-bottom: 38px; min-width: 0; }
h2 { font: 700 22px/1.2 var(--display); margin: 0 0 6px; text-wrap: balance; }
h2 + .sub { margin-bottom: 14px; }
h3 { font: 600 12px/1.2 var(--body); text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin: 18px 0 8px; }
details.run { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; margin-bottom: 10px; }
details.run > summary { list-style: none; cursor: pointer; padding: 12px 14px; display: grid;
  grid-template-columns: auto minmax(0, 1fr) auto; gap: 4px 12px; align-items: baseline; }
details.run > summary::-webkit-details-marker { display: none; }
details.run > summary:focus-visible { outline: 2px solid var(--corona); outline-offset: 2px; border-radius: 10px; }
.rid { font: 500 12px/1 var(--mono); color: var(--muted); }
.rtitle { font-weight: 600; }
.rwhat { grid-column: 2 / 4; color: var(--muted); font-size: 13.5px; }
.score { font: 700 15px/1 var(--display); font-variant-numeric: tabular-nums; }
.score.ok { color: var(--pass); } .score.part { color: var(--corona); }
.runbody { padding: 0 14px 14px; }
.rnote { background: var(--corona-soft); border-radius: 8px; padding: 9px 12px; margin: 0 0 10px; max-width: 80ch; font-size: 14px; }
.checks { list-style: none; margin: 0; padding: 0; display: grid; gap: 5px; }
.checks li { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 3px 10px; padding: 7px 10px;
  background: var(--ground); border-radius: 7px; }
.chip { font: 600 11px/1 var(--mono); letter-spacing: .06em; padding: 5px 7px; border-radius: 5px; align-self: start; margin-top: 2px; }
.chip.ok { color: var(--pass); background: var(--pass-soft); }
.chip.no { color: var(--fail); background: var(--fail-soft); }
.checks .name { font-weight: 500; font-size: 14px; }
.checks .detail { grid-column: 2; font: 11.5px/1.45 var(--mono); color: var(--muted); overflow-wrap: anywhere; }
.tablewrap { overflow-x: auto; border: 1px solid var(--rule); border-radius: 10px; background: var(--panel); }
table { border-collapse: collapse; width: 100%; min-width: 640px; font-size: 14px; }
th, td { text-align: left; vertical-align: top; padding: 9px 12px; border-bottom: 1px solid var(--rule); }
th { font: 600 11.5px/1.3 var(--body); text-transform: uppercase; letter-spacing: .07em; color: var(--muted); }
tr:last-child td { border-bottom: 0; }
.sev { font: 600 11px/1 var(--mono); letter-spacing: .05em; padding: 4px 6px; border-radius: 5px; white-space: nowrap; }
.sev.high { color: var(--fail); background: var(--fail-soft); }
.sev.medium { color: var(--corona); background: var(--corona-soft); }
.sev.low { color: var(--muted); background: var(--ground); }
.where { font: 12px/1.4 var(--mono); color: var(--muted); }
.cases { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 10px; }
.case { background: var(--panel); border: 1px solid var(--rule); border-radius: 10px; padding: 10px 12px; min-width: 0; }
.case h4 { margin: 0 0 6px; font: 600 14px/1.35 var(--body); }
.case h4 span { font: 500 12px/1 var(--mono); color: var(--corona); margin-right: 6px; }
.case ul { margin: 0; padding: 0; list-style: none; display: grid; gap: 3px; }
.case li { font-size: 13px; display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 8px; }
pre { margin: 0; background: var(--panel); border: 1px solid var(--rule); border-radius: 8px; padding: 12px 14px;
  font: 12.5px/1.55 var(--mono); overflow-x: auto; }
.cmd { position: relative; }
.copy { position: absolute; top: 8px; right: 8px; font: 500 12px/1 var(--body); color: var(--ink); background: var(--ground);
  border: 1px solid var(--rule); border-radius: 6px; padding: 6px 9px; cursor: pointer; }
.copy:hover { border-color: var(--corona); }
.copy:focus-visible, a:focus-visible { outline: 2px solid var(--corona); outline-offset: 2px; }
.kv { display: grid; grid-template-columns: max-content minmax(0, 1fr); gap: 6px 16px; margin: 0; }
.kv dt { color: var(--muted); }
.kv dd { margin: 0; font: 12.5px/1.5 var(--mono); overflow-wrap: anywhere; }
code { font: 12.5px/1.4 var(--mono); }
.callout { border-left: 3px solid var(--corona); background: var(--panel); border-radius: 0 10px 10px 0; padding: 12px 16px; max-width: 80ch; }
.callout p { margin: 0 0 8px; } .callout p:last-child { margin: 0; }
ul.plain { margin: 0; padding-left: 20px; max-width: 80ch; }
ul.plain li { margin-bottom: 6px; }
p { max-width: 75ch; }
@media (prefers-reduced-motion: no-preference) { .copy { transition: border-color .15s; } }
</style>
""")

ok_all = sum(ok for _, _, _, ok in runs)
n_all = sum(len(c) for _, _, c, _ in runs)
w('<div class="wrap">')
w('<header><div class="mark"><div class="ring" aria-hidden="true"></div><h1>Antumbra in QEMU</h1></div>')
w(f'<p class="sub">{E(spec["intro"])}</p>')
w('<div class="ledger">')
for r, rep, checks, ok in runs:
    part = " part" if ok < len(checks) else ""
    w(f'<div class="tally"><span class="k">{E(r["short"])}</span><b class="{part.strip()}">{ok}/{len(checks)}</b><span>{E(r["title"])}</span></div>')
w(f'<div class="tally"><span class="k">Motor sleep test</span><b class="{"part" if g_ok < g_all else ""}">{g_ok}/{g_all}</b><span>7 suspend cases in the VM</span></div>')
u = spec["unit"]
w(f'<div class="tally"><span class="k">Unit tests and lint</span><b>{u["root"]}</b><span>{E(u["text"])}</span></div>')
w('</div></header>')

w('<section aria-label="Screens"><div class="screens">')
for path, caption in spec["shots"]:
    w(f'<figure><div class="phone"><img src="{img_uri(path)}" alt="{E(caption)}" width="720" height="1440" loading="lazy"></div><figcaption>{E(caption)}</figcaption></figure>')
w('</div></section>')

w('<section><h2>What this round added</h2>')
w(f'<p class="sub">{E(spec["added_intro"])}</p><div class="cols">')
for f in spec["features"]:
    w(f'<div class="feature"><h3>{E(f["title"])}</h3><ul>' + "".join(f"<li>{E(x)}</li>" for x in f["items"]) + '</ul></div>')
w('</div></section>')

w('<section><h2>About the OnePlus camera app</h2><div class="callout">')
for para in spec["oneplus"]:
    w(f'<p>{E(para)}</p>')
w('</div></section>')

w('<section><h2>The runs</h2>')
w(f'<p class="sub">{E(spec["runs_intro"])}</p>')
for r, rep, checks, ok in runs:
    cls = "ok" if ok == len(checks) else "part"
    w(f'<details class="run"{" open" if ok < len(checks) else ""}><summary><span class="rid">{E(r["id"])}</span>'
      f'<span class="rtitle">{E(r["title"])}</span><span class="score {cls}">{ok}/{len(checks)}</span>'
      f'<span class="rwhat">{E(r["what"])}</span></summary><div class="runbody">')
    if r.get("note"):
        w(f'<p class="rnote">{E(r["note"])}</p>')
    groups = {}
    for c in checks:
        groups.setdefault(phase_of(c["name"]), []).append(c)
    for label, _ in PHASES + [("Other", None)]:
        if label not in groups:
            continue
        w(f'<h3>{E(label)}</h3><ul class="checks">')
        for c in groups[label]:
            chip = '<span class="chip ok">PASS</span>' if c["ok"] else '<span class="chip no">FAIL</span>'
            det = c["detail"] if len(c["detail"]) < 320 else c["detail"][:317] + "..."
            w(f'<li>{chip}<span class="name">{E(c["name"])}</span>' + (f'<span class="detail">{E(det)}</span>' if det else "") + '</li>')
        w('</ul>')
    w('</div></details>')
w('</section>')

w('<section><h2>The pop-up camera across sleep</h2>')
w(f'<p class="sub">{E(spec["genpd_intro"])}</p><div class="cases">')
for c in cases:
    w(f'<div class="case"><h4><span>case {E(c["n"])}</span>{E(c["title"])}</h4><ul>')
    for ok, name in c["checks"]:
        w(f'<li><span class="chip {"ok" if ok else "no"}">{"PASS" if ok else "FAIL"}</span><span>{E(name)}</span></li>')
    w('</ul></div>')
w('</div></section>')

w('<section><h2>What review caught</h2>')
w(f'<p class="sub">{E(spec["findings_intro"])}</p>')
w('<div class="tablewrap"><table><thead><tr><th>Severity</th><th>Problem</th><th>Fix</th><th>Where</th></tr></thead><tbody>')
for f in spec["findings"]:
    w(f'<tr><td><span class="sev {E(f["sev"])}">{E(f["sev"].upper())}</span></td><td>{E(f["problem"])}</td><td>{E(f["fix"])}</td><td class="where">{E(f["where"])}</td></tr>')
w('</tbody></table></div></section>')

w('<section><h2>What the VM caught</h2>')
w(f'<p class="sub">{E(spec["vm_found_intro"])}</p>')
w('<div class="tablewrap"><table><thead><tr><th>Found by</th><th>Problem</th><th>Fix</th><th>In</th></tr></thead><tbody>')
for f in spec["vm_found"]:
    w(f'<tr><td class="where">{E(f["run"])}</td><td>{E(f["problem"])}</td><td>{E(f["fix"])}</td><td>{E(f["kind"])}</td></tr>')
w('</tbody></table></div></section>')

w('<section><h2>Before you rely on it</h2>')
w(f'<p class="sub">{E(spec["caveats_intro"])}</p><ul class="plain">')
for c in spec["caveats"]:
    w(f'<li>{E(c)}</li>')
w('</ul></section>')

w('<section id="run"><h2>Run it yourself</h2>')
for para in spec["run_intro"]:
    w(f'<p>{E(para)}</p>')
for i, (label, cmd) in enumerate(spec["commands"]):
    w(f'<h3>{E(label)}</h3><div class="cmd"><pre id="cmd{i}">{E(cmd)}</pre>'
      f'<button class="copy" type="button" data-for="cmd{i}">Copy</button></div>')
w('<h3>What was built</h3><dl class="kv">')
for k, v in spec["built"]:
    w(f'<dt>{E(k)}</dt><dd>{E(v)}</dd>')
w('</dl></section>')
w('</div>')
w("""<script>
document.querySelectorAll('.copy').forEach(function (b) {
  b.addEventListener('click', function () {
    var pre = document.getElementById(b.dataset.for);
    var done = function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); };
    var select = function () { var r = document.createRange(); r.selectNodeContents(pre); var s = getSelection(); s.removeAllRanges(); s.addRange(r); b.textContent = 'Selected'; };
    try { navigator.clipboard.writeText(pre.textContent).then(done, select); } catch (e) { select(); }
  });
});
</script>""")
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(P))
print(f"wrote {sys.argv[2]}: {ok_all}/{n_all} run checks, motor {g_ok}/{g_all}")
