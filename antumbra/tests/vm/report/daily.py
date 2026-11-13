#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the "Antumbra Daily" page from one VM run's artifact.

The daily VM workflow (.github/workflows/antumbra-vm.yml) uploads an artifact
per run: metrics.json, the harness's output and its screenshots (see
tests/vm/ci/metrics.py). This script turns the newest run, compared with the
one before it, into one self-contained HTML page: the result, the change it
tested, each screen before and after, the checks, and the numbers that can
be compared between runs (boot milestones, sizes, packages). Screenshots
are embedded as small JPEGs (ImageMagick's convert and compare).

The page is published as a private Claude artifact with the db, user and
assets capabilities. Its buttons write small documents to the artifact's
database, which the next morning's routine reads:

  feedback/<run>_<screen>   {run, screen, verdict: right|off, note, at}
  controls/state            {pause, stop, at}: no change / no routine
  undo/<commit>             {sha, subject, at}: revert that change
  answers/<question id>     {choice, at}
  photos/<asset id>         {asset, note, at}: a photo of the phone
  metrics/<run>             written by the routine (one row per run), read
                            by the page for the history table

usage: daily.py --run DIR [--prev DIR] [--question FILE.json] --out PAGE.html
"""
import argparse
import base64
import glob
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time

E = html.escape
# Screens shown first, in this order; any other screenshot follows by name.
ORDER = ("display", "session", "tour-apps", "tour-quick-settings", "tour-tor-browser",
         "welcome-android", "android-session", "android-full-ui", "android-fdroid")
TITLES = {"display": "Welcome screen", "session": "After login", "tour-apps": "App grid",
          "tour-quick-settings": "Quick settings", "tour-tor-browser": "Tor Browser",
          "welcome-android": "Welcome, Android apps on", "android-session": "Session with Android",
          "android-full-ui": "Android", "android-fdroid": "F-Droid"}
# A screen counts as changed above this share of differing pixels, the
# status bar (clock, battery) left out.
CHANGED = 0.02


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def screens(run):
    """{screen name: png path} of a run directory."""
    found = {}
    for p in sorted(glob.glob(os.path.join(run, "**", "*.png"), recursive=True)):
        found.setdefault(os.path.splitext(os.path.basename(p))[0], p)
    return found


def order_key(name):
    return (ORDER.index(name), name) if name in ORDER else (len(ORDER), name)


def jpeg(png, tmp, width=360):
    """The screenshot as a data: URI, width px wide."""
    out = os.path.join(tmp, os.path.basename(png) + ".jpg")
    subprocess.run(["convert", png, "-resize", f"{width}x", "-strip", "-quality", "70", out],
                   check=True, capture_output=True)
    with open(out, "rb") as f:
        return "data:image/jpeg;base64," + base64.b64encode(f.read()).decode()


def changed_fraction(a, b, tmp):
    """Share of pixels that differ between two screenshots, the top 6% (the
    status bar) cropped off and both scaled to 180 px wide; None if they
    cannot be compared."""
    norm = []
    for i, p in enumerate((a, b)):
        out = os.path.join(tmp, f"cmp{i}.png")
        r = subprocess.run(["convert", p, "-gravity", "south", "-crop", "100%x94%+0+0", "+repage",
                            "-resize", "180x", "-colorspace", "gray", out], capture_output=True)
        if r.returncode:
            return None
        norm.append(out)
    size = [subprocess.run(["identify", "-format", "%w %h", p], capture_output=True, text=True).stdout
            for p in norm]
    if size[0] != size[1] or not size[0]:
        return 1.0
    r = subprocess.run(["compare", "-metric", "AE", "-fuzz", "8%", norm[0], norm[1], "null:"],
                       capture_output=True, text=True)
    m = re.match(r"\s*([\d.e+]+)", r.stderr)
    if not m:
        return None
    w, h = (int(x) for x in size[0].split())
    return float(m.group(1)) / (w * h)


def get(d, *keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def fmt_bytes(n):
    if n is None:
        return "–"
    for unit in ("B", "KiB", "MiB", "GiB"):
        if abs(n) < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024.0
    return str(n)


def fmt_s(x):
    return "–" if x is None else f"{x:.0f} s"


def delta(cur, prev, kind):
    """Text and class of the change from prev to cur."""
    if cur is None or prev is None:
        return "", ""
    d = cur - prev
    if kind == "bytes":
        if abs(d) < 1024:
            return "same", "same"
        text = ("+" if d > 0 else "−") + fmt_bytes(abs(d))
    elif kind == "count":
        if d == 0:
            return "same", "same"
        text = f"{d:+d}".replace("-", "−")
    else:  # seconds, emulated: only a change above 20% counts
        if prev and abs(d) / prev < 0.2:
            return "within noise", "same"
        text = f"{d:+.0f} s".replace("-", "−")
    return text, ("up" if d > 0 else "down")


def numbers(m):
    """The comparable numbers of a run: (key, label, value, kind)."""
    boot = get(m, "boot") or {}
    ms = boot.get("milestones") if isinstance(boot.get("milestones"), dict) else boot
    sizes = get(m, "build", "sizes") or {}
    return [
        ("greetd", "Welcome screen started (guest time)", get(ms, "greetd_started"), "s"),
        ("phosh", "Phosh ready after login (guest time)", get(ms, "phosh_ready"), "s"),
        ("squashfs", "System file (squashfs)", sizes.get("squashfs"), "bytes"),
        ("initramfs", "Initramfs", sizes.get("initrd"), "bytes"),
        ("packages", "Debian packages", get(m, "build", "packages"), "count"),
        ("harness", "Test run, wall time (emulated)", get(m, "harness", "seconds"), "s"),
    ]


def build(args):
    m = load(os.path.join(args.run, "metrics.json")) or {}
    pm = load(os.path.join(args.prev, "metrics.json")) if args.prev else None
    question = load(args.question) if args.question else None
    run_no = get(m, "run", "number") or 0
    sha = (get(m, "run", "commit") or "")[:12]
    subject = get(m, "run", "commit_subject") or ""
    passed, total = get(m, "harness", "checks_passed"), get(m, "harness", "checks_total")
    failed = get(m, "harness", "failed") or []
    checks = get(m, "harness", "checks") or []
    url = get(m, "run", "url") or ""
    first = bool(get(m, "run", "first_run"))

    cur, prev = screens(args.run), screens(args.prev) if args.prev else {}
    shots = []
    with tempfile.TemporaryDirectory() as tmp:
        for name in sorted(cur, key=order_key):
            frac = changed_fraction(prev[name], cur[name], tmp) if name in prev else None
            shots.append({
                "name": re.sub(r"[^A-Za-z0-9_-]", "-", name),
                "title": TITLES.get(name, name.replace("-", " ").capitalize()),
                "now": jpeg(cur[name], tmp),
                "before": jpeg(prev[name], tmp) if name in prev else None,
                "frac": frac,
                "changed": frac is None or frac > CHANGED,
            })

    if total:
        result = f"{passed}/{total} checks passed"
        state = "ok" if passed == total else "bad"
    else:
        result, state = "the test run did not finish", "bad"
    when = time.strftime("%a %d %b %Y, %H:%M UTC", time.gmtime())
    prev_run = get(pm, "run", "number")

    rows = []
    for (key, label, value, kind), (_, _, before, _) in zip(numbers(m), numbers(pm) if pm else [(None,) * 4] * 6):
        text = fmt_bytes(value) if kind == "bytes" else (fmt_s(value) if kind == "s" else ("–" if value is None else str(value)))
        d, cls = delta(value, before, kind)
        rows.append(f'<tr><th scope="row">{E(label)}</th><td class="num">{E(text)}</td>'
                    f'<td class="delta {cls}">{E(d)}</td></tr>')

    cards = []
    for s in shots:
        if s["before"] and s["changed"]:
            pair = (f'<figure><img src="{s["before"]}" alt="{E(s["title"])} in run {prev_run}" width="360">'
                    f'<figcaption>Before (run {E(str(prev_run))})</figcaption></figure>'
                    f'<figure><img src="{s["now"]}" alt="{E(s["title"])} now" width="360">'
                    f'<figcaption>Now</figcaption></figure>')
            note = f'{s["frac"] * 100:.1f}% of the screen changed' if s["frac"] is not None else "changed"
        else:
            pair = (f'<figure><img src="{s["now"]}" alt="{E(s["title"])}" width="360">'
                    f'<figcaption>{"Unchanged since run " + E(str(prev_run)) if s["before"] else "Now"}</figcaption></figure>')
            note = "unchanged" if s["before"] else "first time shown"
        cards.append(f'''<section class="screen{' changed' if s['before'] and s['changed'] else ''}" data-screen="{s['name']}">
  <header><h3>{E(s['title'])}</h3><span class="tag">{E(note)}</span></header>
  <div class="pair">{pair}</div>
  <div class="verdict" hidden>
    <button type="button" data-v="right">Looks right</button>
    <button type="button" data-v="off">Looks off</button>
    <input type="text" id="note-{s['name']}" placeholder="A few words, if it looks off" maxlength="300">
    <span class="saved" aria-live="polite"></span>
  </div>
</section>''')

    failed_html = "".join(f"<li>{E(n)}</li>" for n in failed) or "<li>none</li>"
    checks_html = "".join(
        f'<li class="{"ok" if c.get("ok") else "bad"}">{E(c.get("name", ""))}</li>' for c in checks)
    data = {"run": run_no, "sha": sha, "subject": subject, "screens": [s["name"] for s in shots],
            "question": question}
    q_html = ""
    if question:
        opts = "".join(f'<button type="button" data-choice="{E(o["id"])}">{E(o["label"])}'
                       f'{" (recommended)" if o.get("recommended") else ""}</button>'
                       for o in question.get("options", []))
        q_html = f'''<section class="card" id="question">
  <h2>Today's question</h2>
  <p>{E(question.get("text", ""))}</p>
  <div class="choices">{opts}</div>
  <p class="small">No answer in 48 hours means the recommended option.</p>
  <span class="saved" aria-live="polite"></span>
</section>'''

    page = TEMPLATE
    for k, v in {
        "{{RESULT}}": E(result), "{{STATE}}": state, "{{WHEN}}": E(when),
        "{{RUN}}": E(str(run_no)), "{{SHA}}": E(sha), "{{SUBJECT}}": E(subject),
        "{{URL}}": E(url), "{{FIRST}}": ('<p class="note">Baseline: the first run of the daily test, on the '
                                         'unchanged system. Later runs are compared with the run before them.</p>'
                                         if first else ""),
        "{{PREV}}": f"Compared with run {E(str(prev_run))}." if prev_run else "No earlier run to compare with.",
        "{{QUESTION}}": q_html, "{{SCREENS}}": "\n".join(cards) or "<p>No screenshots in this run.</p>",
        "{{NUMBERS}}": "\n".join(rows), "{{FAILED}}": failed_html, "{{CHECKS}}": checks_html,
        "{{DATA}}": json.dumps(data).replace("</", "<\\/"),
    }.items():
        page = page.replace(k, v)
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(page)
    print(f"{args.out}: run {run_no}, {result}, {len(shots)} screens, "
          f"{sum(1 for s in shots if s['before'] and s['changed'])} changed, {len(page)} bytes")


TEMPLATE = r"""<title>Antumbra Daily</title>
<style>
/* One column of cards: the result, the screens (before and after), the
   numbers, the controls. Palette: Antumbra's own Material 3 tones. */
:root {
  --bg: #fdf8ff; --surface: #f4eef9; --surface-2: #ebe4f2; --fg: #1d1a22; --muted: #4d4757;
  --line: #d5cde0; --accent: #5a3ea6; --accent-soft: #e9ddff; --on-accent-soft: #23005c;
  --ok: #1f6b3a; --ok-bg: #dcf3e2; --bad: #9b2c1f; --bad-bg: #fbe0dc;
  --sans: "Roboto Flex", Roboto, "Segoe UI", system-ui, -apple-system, sans-serif;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #141218; --surface: #1d1a22; --surface-2: #29252f; --fg: #e8e0ee; --muted: #c9c1d4;
    --line: #3d3747; --accent: #cfbcff; --accent-soft: #3d2a73; --on-accent-soft: #eaddff;
    --ok: #9fdcb0; --ok-bg: #173323; --bad: #f6b0a5; --bad-bg: #431a14; color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --bg: #141218; --surface: #1d1a22; --surface-2: #29252f; --fg: #e8e0ee; --muted: #c9c1d4;
  --line: #3d3747; --accent: #cfbcff; --accent-soft: #3d2a73; --on-accent-soft: #eaddff;
  --ok: #9fdcb0; --ok-bg: #173323; --bad: #f6b0a5; --bad-bg: #431a14; color-scheme: dark;
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body { margin: 0; background: var(--bg); color: var(--fg); font-family: var(--sans); font-size: 1rem; line-height: 1.5; }
.wrap { max-width: 44rem; margin: 0 auto; padding-inline: 16px; padding-block: 20px 48px; display: grid; gap: 18px; }
h1 { font-size: 1.6rem; line-height: 1.2; margin: 0; font-weight: 650; }
h2 { font-size: 1.15rem; margin: 0 0 8px; }
h3 { font-size: 1rem; margin: 0; }
p { margin: 0 0 8px; max-width: 65ch; }
.eyebrow { font-size: 0.8rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); margin: 0; }
.result { display: inline-block; font-weight: 650; padding: 4px 12px; border-radius: 999px; }
.result.ok { color: var(--ok); background: var(--ok-bg); }
.result.bad { color: var(--bad); background: var(--bad-bg); }
.small, .note { font-size: 0.875rem; color: var(--muted); }
.card { background: var(--surface); border-radius: 18px; padding: 16px; }
.screen { background: var(--surface); border-radius: 18px; padding: 14px; display: grid; gap: 10px; }
.screen.changed { outline: 2px solid var(--accent); }
.screen header { display: flex; flex-wrap: wrap; align-items: baseline; justify-content: space-between; gap: 6px; }
.tag { font-size: 0.8rem; color: var(--muted); }
.pair { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 10px; }
figure { margin: 0; min-width: 0; }
figure img { width: 100%; height: auto; display: block; border-radius: 12px; border: 1px solid var(--line); }
figcaption { font-size: 0.8rem; color: var(--muted); margin-top: 4px; }
.verdict { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
button { font: inherit; font-size: 0.9rem; padding: 7px 14px; border-radius: 999px; border: 1px solid var(--line);
  background: var(--bg); color: var(--fg); cursor: pointer; }
button[aria-pressed="true"] { background: var(--accent-soft); color: var(--on-accent-soft); border-color: transparent; font-weight: 600; }
button:focus-visible, input:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
input[type="text"] { font: inherit; font-size: 0.9rem; flex: 1 1 12rem; min-width: 0; padding: 7px 10px;
  border-radius: 10px; border: 1px solid var(--line); background: var(--bg); color: var(--fg); }
.saved { font-size: 0.8rem; color: var(--muted); }
.table-wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; font-size: 0.9rem; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 7px 8px; border-bottom: 1px solid var(--line); vertical-align: top; }
th[scope="row"] { font-weight: 500; }
td.num { white-space: nowrap; }
.delta { white-space: nowrap; color: var(--muted); }
.delta.up, .delta.down { color: var(--fg); font-weight: 600; }
ul.checks { margin: 0; padding-left: 1.2rem; font-size: 0.875rem; }
ul.checks li.bad { color: var(--bad); font-weight: 600; }
details summary { cursor: pointer; font-weight: 600; }
.controls { display: grid; gap: 10px; }
.row { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; }
.photos { display: grid; grid-template-columns: repeat(auto-fill, minmax(96px, 1fr)); gap: 8px; }
.photos img { width: 100%; height: auto; border-radius: 10px; border: 1px solid var(--line); }
.choices { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 8px; }
a { color: var(--accent); }
</style>

<div class="wrap">
  <header>
    <p class="eyebrow">Antumbra Daily · {{WHEN}}</p>
    <h1>Test run {{RUN}}</h1>
    <p><span class="result {{STATE}}">{{RESULT}}</span></p>
    <p>Change tested: <strong>{{SUBJECT}}</strong> <span class="small">({{SHA}})</span></p>
    {{FIRST}}
    <p class="small">The system built from this change and started in a virtual machine on GitHub (no phone hardware, full emulation: times are only comparable between runs). {{PREV}} <a href="{{URL}}">The run on GitHub</a>.</p>
  </header>

  {{QUESTION}}

  <section aria-labelledby="screens-h">
    <h2 id="screens-h">Screens</h2>
    <p class="small">A screen with a coloured border changed since the run before. Tap a verdict; "Looks off" means it is undone or adjusted the next morning.</p>
    <div class="wrap" style="padding:0">{{SCREENS}}</div>
  </section>

  <section class="card" aria-labelledby="num-h">
    <h2 id="num-h">Numbers</h2>
    <div class="table-wrap"><table>
      <thead><tr><th scope="col">What</th><th scope="col">This run</th><th scope="col">Change</th></tr></thead>
      <tbody>{{NUMBERS}}</tbody>
    </table></div>
    <p class="small">Times are measured under full emulation on GitHub, many times slower than the phone; a change below 20% is noise.</p>
    <div id="history" hidden>
      <h3>Recent runs</h3>
      <div class="table-wrap"><table><thead><tr><th scope="col">Run</th><th scope="col">Checks</th><th scope="col">Phosh ready</th><th scope="col">System file</th><th scope="col">Change</th></tr></thead><tbody id="history-rows"></tbody></table></div>
    </div>
  </section>

  <section class="card" aria-labelledby="checks-h">
    <h2 id="checks-h">Checks</h2>
    <p>Failed:</p>
    <ul class="checks">{{FAILED}}</ul>
    <details><summary>All checks</summary><ul class="checks">{{CHECKS}}</ul></details>
  </section>

  <section class="card controls" aria-labelledby="ctl-h">
    <h2 id="ctl-h">Controls</h2>
    <p class="small" id="ctl-off">The buttons work when you open this page signed in to Claude.</p>
    <div class="row" id="ctl-row" hidden>
      <button type="button" id="undo" aria-pressed="false">Undo this change</button>
      <button type="button" id="pause" aria-pressed="false">Pause changes</button>
      <button type="button" id="stop" aria-pressed="false">Stop the morning routine</button>
      <span class="saved" id="ctl-saved" aria-live="polite"></span>
    </div>
    <p class="small">Undo reverts this change tomorrow morning. Pause: the routine still reports but changes nothing. Stop: it ends at once (for holidays).</p>
    <div id="photo-box" hidden>
      <h3>A photo of the phone</h3>
      <p class="small">For the preview on the OnePlus: photograph its screen with your iPhone and add it here with a few words.</p>
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
async function boot() {
  const db = window.claude ? await window.claude.use("db") : null;
  if (!db) return;
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
        await ref.set(Object.assign({ run: RUN.run, screen: name, verdict: current.verdict || null, note: note.value.trim() }, patch, { at: stamp() }));
        say(saved, "Saved");
      } catch (e) { say(saved, "Not saved: " + (e && e.code || "error")); }
    };
    for (const b of box.querySelectorAll("button")) b.addEventListener("click", () => write({ verdict: b.dataset.v }));
    note.addEventListener("change", () => write({}));
  }

  // Undo, Pause, Stop.
  const saved = document.getElementById("ctl-saved");
  const undoRef = db.doc("undo/" + (RUN.sha || "none"));
  const undo = document.getElementById("undo");
  undoRef.onSnapshot(s => undo.setAttribute("aria-pressed", String(s.exists)), () => {});
  undo.addEventListener("click", async () => {
    try {
      if (undo.getAttribute("aria-pressed") === "true") { await undoRef.delete(); say(saved, "Undo cancelled"); }
      else { await undoRef.set({ sha: RUN.sha, subject: RUN.subject, run: RUN.run, at: stamp() }); say(saved, "This change will be undone tomorrow morning"); }
    } catch (e) { say(saved, "Not saved: " + (e && e.code || "error")); }
  });
  const ctlRef = db.doc("controls/state");
  let ctl = {};
  ctlRef.onSnapshot(s => {
    ctl = s.exists ? Object.assign({}, s.data()) : {};
    document.getElementById("pause").setAttribute("aria-pressed", String(!!ctl.pause));
    document.getElementById("stop").setAttribute("aria-pressed", String(!!ctl.stop));
  }, () => {});
  for (const key of ["pause", "stop"]) {
    document.getElementById(key).addEventListener("click", async () => {
      try {
        await ctlRef.set({ pause: !!ctl.pause, stop: !!ctl.stop, [key]: !ctl[key], at: stamp() });
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

  // Run history, written by the routine.
  db.collection("metrics").orderBy("run", "desc").limit(10).onSnapshot(qs => {
    if (qs.empty) return;
    const body = document.getElementById("history-rows");
    body.textContent = "";
    for (const d of qs.docs) {
      const r = d.data(), tr = document.createElement("tr");
      const cells = [r.run, (r.passed ?? "–") + "/" + (r.total ?? "–"), r.phosh_ready == null ? "–" : Math.round(r.phosh_ready) + " s",
                     r.squashfs_mib == null ? "–" : r.squashfs_mib.toFixed(1) + " MiB", r.subject || ""];
      for (const c of cells) { const td = document.createElement("td"); td.textContent = String(c); tr.appendChild(td); }
      body.appendChild(tr);
    }
    document.getElementById("history").hidden = false;
  }, () => {});

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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--run", required=True, help="the newest run's unpacked artifact")
    ap.add_argument("--prev", help="the run before it, to compare with")
    ap.add_argument("--question", help="JSON {id, text, options: [{id, label, recommended}]}")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    if not os.path.isfile(os.path.join(args.run, "metrics.json")):
        sys.exit(f"{args.run}: no metrics.json")
    build(args)


if __name__ == "__main__":
    main()
