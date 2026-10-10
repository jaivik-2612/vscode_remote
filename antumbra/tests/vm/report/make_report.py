#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the Antumbra QEMU test-run page from a smoke-test run.

usage: make_report.py RUN_DIR OUT.html --shot FILE.png "caption" [--shot ...]
       [--bundle NAME SIZE SHA256] [--host "description"] [--commit SHA]
       [--packages N] [--doc docs/vm-testing.md]
RUN_DIR is a run directory of tests/vm/antumbra_vm.py (serial.log, smoke/report.json).
"""
import argparse
import base64
import html
import json
import os
import re

ap = argparse.ArgumentParser()
ap.add_argument("run_dir")
ap.add_argument("out")
ap.add_argument("--shot", nargs=2, action="append", default=[], metavar=("PNG", "CAPTION"))
ap.add_argument("--bundle", nargs=3, metavar=("NAME", "SIZE", "SHA256"))
ap.add_argument("--host", default="")
ap.add_argument("--commit", default="")
ap.add_argument("--packages", type=int, default=0)
ap.add_argument("--doc", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                             "..", "..", "..", "docs", "vm-testing.md"))
a = ap.parse_args()

rep = json.load(open(os.path.join(a.run_dir, "smoke", "report.json")))
serial = open(os.path.join(a.run_dir, "serial.log"), "rb").read().decode("utf-8", "replace")
serial = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", serial).replace("\r", "")
E = html.escape

# --- boot timeline from the serial log (kernel timestamps) -------------------------------
MILESTONES = [
    (r"Linux version (\S+)", "Kernel starts", lambda m: m.group(1)),
    (r"Run /init as init process", "Initramfs starts", None),
    (r"antumbra: locating the system partition", "Antumbra looks for the userdata partition", None),
    (r"loop0: p1 p2", "Nested GPT found: live + Persistent Storage partitions", None),
    (r"EXT4-fs \(loop0p1\): mounted filesystem (\S+)", "Live partition mounted by UUID", lambda m: m.group(1)),
    (r"device-mapper: verity", "dm-verity checks the root filesystem", None),
    (r"Reached target (?:basic\.target - )?Basic System", "systemd: basic system", None),
    (r"Started nftables\.service", "Firewall loaded", None),
    (r"Started tor@default\.service", "Tor running", None),
    (r"Started greetd\.service", "Greeter (Welcome screen) starts", None),
    (r"Reached target (?:multi-user\.target - )?Multi-User System", "systemd: multi-user", None),
    (r"welcome settings applied", "Welcome screen: settings applied", None),
    (r"session opened for user amnesia", "User session (Phosh) starts", None),
    (r"virtio_net virtio\d+ (\S+): renamed from", "Network driver loaded only now", lambda m: m.group(1)),
    (r"Successfully spoofed MAC address of NIC (\S+)", "MAC address spoofed", lambda m: m.group(1)),
    (r"Powering off", "Powered off", None),
]
ts_rx = re.compile(r"^\[\s*(\d+\.\d+)\]")
timeline = []
lines = serial.split("\n")
for rx, label, extra in MILESTONES:
    crx = re.compile(rx)
    for i, line in enumerate(lines):
        m = crx.search(line)
        if not m:
            continue
        t = None
        for j in range(i, max(-1, i - 40), -1):
            tm = ts_rx.match(lines[j])
            if tm:
                t = float(tm.group(1))
                break
            tm = re.search(r"\[\s*(\d+\.\d+)\]", lines[j])
            if tm:
                t = float(tm.group(1))
                break
        timeline.append((t, label, extra(m) if extra else "", line.strip()[:160]))
        break
timeline.sort(key=lambda x: (x[0] is None, x[0] or 0))

# the shutdown sequence (return to the initramfs)
shutdown = []
for line in lines:
    s = line.strip()
    if re.match(r"^\+ (/usr/bin/umount|/sbin/dmsetup remove_all|/sbin/losetup -D|echo 3|/usr/bin/mount --move)", s) or "drop_caches" in s or "Powering off" in s:
        shutdown.append(s[:120])

# --- checks grouped by phase ------------------------------------------------------------
GROUPS = [
    ("Boot", ("initramfs:", "systemd:", "boot ", "QEMU")),
    ("Inside the running system", ("debug console:", "guest:")),
    ("Before the Welcome decision", ("display:", "network:")),
    ("After pressing Start", ("welcome:", "after Welcome:", "packet capture:", "tour:")),
    ("Power", ("power key:", "shutdown")),
]
grouped = {g: [] for g, _ in GROUPS}
for c in rep["checks"]:
    for g, prefixes in GROUPS:
        if c["name"].startswith(prefixes):
            grouped[g].append(c)
            break
    else:
        grouped["Inside the running system"].append(c)
n_ok = sum(1 for c in rep["checks"] if c["ok"])
n_all = len(rep["checks"])

def strip_prefix(name):
    return re.sub(r"^(initramfs|systemd|guest|display|network|power key|shutdown|debug console|welcome|after Welcome|packet capture|tour): ", "", name)

def img_uri(path):
    return "data:image/png;base64," + base64.b64encode(open(path, "rb").read()).decode()

roothash = ""
m = re.search(r"dm-verity-root-hash=filesystem\.squashfs:([0-9a-f]{64})", rep.get("cmdline", ""))
if m:
    roothash = m.group(1)

# --- page ---------------------------------------------------------------------------------
P = []
w = P.append
w("""<title>Antumbra QEMU Test Run</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,500;12..96,700&family=IBM+Plex+Sans:ital,wght@0,400;0,500;0,600;1,400&family=JetBrains+Mono:wght@400;500&display=swap">
<style>
/* Layout: a lab record of one boot. Screens in phone frames on the left (sticky on wide
   screens), the run record on the right: verdict, checks by phase, boot timeline, how to run it. */
:root {
  --ground: #eceef3;      /* cool paper with an indigo bias */
  --panel: #f7f8fb;
  --ink: #161a2c;
  --muted: #586079;
  --rule: #d3d8e4;
  --corona: #b8731a;      /* the bright ring around an antumbra */
  --corona-soft: #f3e3c8;
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
    --corona: #e5a24a; --corona-soft: #3a2c17; --pass: #5cc28c; --pass-soft: #173126;
    --fail: #e8735f; --fail-soft: #3b1d18; --frame: #05060a; color-scheme: dark;
  }
}
:root[data-theme="dark"] {
  --ground: #0f111a; --panel: #171a27; --ink: #e6e8f1; --muted: #98a0b9; --rule: #272b3d;
  --corona: #e5a24a; --corona-soft: #3a2c17; --pass: #5cc28c; --pass-soft: #173126;
  --fail: #e8735f; --fail-soft: #3b1d18; --frame: #05060a; color-scheme: dark;
}
* { box-sizing: border-box; }
body { background: var(--ground); color: var(--ink); font: 400 15px/1.55 var(--body); }
.wrap { max-width: 1180px; margin: 0 auto; padding-inline: 20px; padding-block: 28px 64px; }
header { display: grid; gap: 10px; margin-bottom: 28px; }
.mark { display: flex; align-items: center; gap: 14px; }
.ring { width: 34px; height: 34px; border-radius: 50%; flex: none;
  background: radial-gradient(circle at 50% 50%, var(--frame) 0 58%, var(--corona) 60% 72%, transparent 74%); }
h1 { font: 700 clamp(28px, 4.2vw, 44px)/1.05 var(--display); letter-spacing: -0.01em; margin: 0; text-wrap: balance; }
.sub { color: var(--muted); max-width: 68ch; margin: 0; }
.verdict { display: flex; flex-wrap: wrap; gap: 10px 22px; align-items: baseline; padding-block: 14px;
  border-block: 1px solid var(--rule); margin-top: 8px; }
.verdict b { font: 700 26px/1 var(--display); font-variant-numeric: tabular-nums; }
.verdict span { color: var(--muted); }
.grid { display: grid; grid-template-columns: minmax(0, 380px) minmax(0, 1fr); gap: 36px; align-items: start; }
@media (max-width: 860px) { .grid { grid-template-columns: minmax(0, 1fr); } }
.shots { display: grid; gap: 22px; position: sticky; top: calc(env(safe-area-inset-top, 0px) + 16px); }
@media (max-width: 860px) { .shots { position: static; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); } }
figure { margin: 0; display: grid; gap: 8px; justify-items: center; }
.phone { background: var(--frame); border-radius: 30px; padding: 12px 10px 16px; max-width: 300px; width: 100%;
  box-shadow: 0 1px 0 var(--rule), 0 18px 40px -24px rgba(10, 12, 30, .55); }
.phone img { display: block; width: 100%; height: auto; border-radius: 18px; background: #000; }
figcaption { font-size: 13px; color: var(--muted); text-align: center; max-width: 32ch; }
section { margin-bottom: 34px; min-width: 0; }
h2 { font: 700 20px/1.2 var(--display); margin: 0 0 12px; text-wrap: balance; }
h3 { font: 600 12px/1.2 var(--body); text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin: 18px 0 8px; }
.checks { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.checks li { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 4px 10px; padding: 8px 12px;
  background: var(--panel); border: 1px solid var(--rule); border-radius: 8px; }
.chip { font: 600 11px/1 var(--mono); letter-spacing: .06em; padding: 5px 7px; border-radius: 5px; align-self: start; margin-top: 2px; }
.chip.ok { color: var(--pass); background: var(--pass-soft); }
.chip.no { color: var(--fail); background: var(--fail-soft); }
.checks .name { font-weight: 500; }
.checks .detail { grid-column: 2; font: 12px/1.45 var(--mono); color: var(--muted); overflow-wrap: anywhere; }
.timeline { list-style: none; margin: 0; padding: 0; border-left: 2px solid var(--rule); }
.timeline li { position: relative; padding: 0 0 12px 18px; display: grid; gap: 2px; }
.timeline li::before { content: ""; position: absolute; left: -6px; top: 6px; width: 10px; height: 10px; border-radius: 50%;
  background: var(--ground); border: 2px solid var(--corona); }
.timeline .t { font: 500 12px/1.3 var(--mono); color: var(--corona); font-variant-numeric: tabular-nums; }
.timeline .x { font: 12px/1.4 var(--mono); color: var(--muted); overflow-wrap: anywhere; }
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
.tablewrap { overflow-x: auto; border: 1px solid var(--rule); border-radius: 8px; background: var(--panel); }
table { border-collapse: collapse; width: 100%; min-width: 560px; font-size: 13.5px; }
th, td { text-align: left; vertical-align: top; padding: 8px 12px; border-bottom: 1px solid var(--rule); }
th { font: 600 11.5px/1.3 var(--body); text-transform: uppercase; letter-spacing: .07em; color: var(--muted); }
tr:last-child td { border-bottom: 0; }
code { font: 12px/1.4 var(--mono); }
.note { background: var(--corona-soft); border-radius: 8px; padding: 10px 14px; max-width: 75ch; }
ul.plain { margin: 0; padding-left: 20px; max-width: 72ch; }
ul.plain li { margin-bottom: 4px; }
p { max-width: 72ch; }
@media (prefers-reduced-motion: no-preference) { .copy { transition: border-color .15s; } }
</style>
""")
w('<div class="wrap">')
w('<header><div class="mark"><div class="ring" aria-hidden="true"></div><h1>Antumbra in QEMU</h1></div>')
w(f'<p class="sub">One boot of Antumbra {E(rep["version"])} on QEMU\'s arm64 <code>virt</code> machine, built from the same kernel sources, '
  'root filesystem hooks, squashfs and dm-verity tree as the phone image. The smoke test drove it from boot to power-off.</p>')
w(f'<div class="verdict"><b>{n_ok}/{n_all}</b><span>checks passed</span>')
if a.host:
    w(f'<span>{E(a.host)}</span>')
w('</div></header>')
w('<div class="grid"><div class="shots">')
for path, caption in a.shot:
    w(f'<figure><div class="phone"><img src="{img_uri(path)}" alt="{E(caption)}" width="720" height="1440"></div><figcaption>{E(caption)}</figcaption></figure>')
w('</div><div>')

w('<section><h2>Smoke test</h2>')
for g, _ in GROUPS:
    items = grouped[g]
    if not items:
        continue
    w(f'<h3>{E(g)}</h3><ul class="checks">')
    for c in items:
        chip = '<span class="chip ok">PASS</span>' if c["ok"] else '<span class="chip no">FAIL</span>'
        w(f'<li>{chip}<span class="name">{E(strip_prefix(c["name"]))}</span>')
        if c.get("detail"):
            detail = re.sub(r"\s*->\s*/\S+", "", c["detail"])   # no build-host paths
            w(f'<span class="detail">{E(detail[:400])}</span>')
        w('</li>')
    w('</ul>')
w('</section>')

w('<section><h2>Boot timeline</h2><p class="sub">Seconds since the kernel started, from the serial console. '
  'QEMU emulates the ARM CPU on an x86-64 build host here, so these times are many times slower than on the phone.</p><ol class="timeline">')
for t, label, extra, raw in timeline:
    ts = f"{t:8.1f} s" if t is not None else "     — "
    w(f'<li><span class="t">{E(ts)}</span><span>{E(label)}{(" · " + E(extra)) if extra else ""}</span></li>')
w('</ol>')
if shutdown:
    w('<h3>Shutdown: back into the initramfs</h3><pre>' + E("\n".join(shutdown[-14:])) + '</pre>')
w('</section>')

w('<section><h2>What was booted</h2><dl class="kv">')
w(f'<dt>Version</dt><dd>{E(rep["version"])}{(" · commit " + E(a.commit)) if a.commit else ""}</dd>')
if a.packages:
    w(f'<dt>Packages</dt><dd>{a.packages} Debian trixie arm64 packages</dd>')
if roothash:
    w(f'<dt>dm-verity root hash</dt><dd>{E(roothash)}</dd>')
w(f'<dt>Kernel command line</dt><dd>{E(rep.get("cmdline", ""))}</dd>')
if a.bundle:
    w(f'<dt>Test bundle</dt><dd>{E(a.bundle[0])} · {E(a.bundle[1])}<br>sha256 {E(a.bundle[2])}</dd>')
w('</dl></section>')

# Defects the VM found, from docs/vm-testing.md (kept in one place)
doc = open(a.doc).read()
rows = []
in_table = False
for line in doc.split("\n"):
    if line.startswith("## What the first VM runs found"):
        in_table = True; continue
    if in_table and line.startswith("## "):
        break
    if in_table and line.startswith("| ") and not line.startswith("| Symptom") and not line.startswith("|---"):
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) == 3:
            rows.append(cells)
def md(t):
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", E(t))
if rows:
    w('<section><h2>What the VM caught</h2><p class="sub">Booting the full image and pressing Start exposed these defects. '
      'All are fixed in the configuration, and all but the interface rename would have hit the phone the same way.</p>'
      '<div class="tablewrap"><table><thead><tr><th>What went wrong</th><th>Cause</th><th>Fix</th></tr></thead><tbody>')
    for sym, cause, fix in rows:
        w(f'<tr><td>{md(sym)}</td><td>{md(cause)}</td><td>{md(fix)}</td></tr>')
    w('</tbody></table></div></section>')

w('<section id="run"><h2>Run it yourself</h2>')
w('<p>The test bundle holds the kernel, the initramfs, the compressed disk image and a run script. You need QEMU and zstd:</p>')
CMDS = [
    ("Debian or Ubuntu", "sudo apt install qemu-system-arm qemu-utils ipxe-qemu zstd"),
    ("Fedora", "sudo dnf install qemu-system-aarch64 qemu-img zstd"),
    ("macOS", "brew install qemu zstd"),
]
w('<dl class="kv">' + "".join(f'<dt>{E(k)}</dt><dd>{E(v)}</dd>' for k, v in CMDS) + '</dl>')
name = a.bundle[0] if a.bundle else "antumbra-qemu-virt.tar"
base = name[:-4] if name.endswith(".tar") else name
run_cmd = f"tar -xf {name}\ncd {base}\n./run.sh              # display window + serial console here\n./run.sh --headless   # serial console only (Ctrl-A X quits)\n./run.sh --debug      # adds a root shell on the virtio console"
w(f'<h3>Boot</h3><div class="cmd"><pre id="cmd-run">{E(run_cmd)}</pre><button class="copy" type="button" data-target="cmd-run">Copy</button></div>')
w('<p class="note">On an Apple-silicon Mac or an arm64 Linux machine with KVM the run script uses hardware acceleration and the Welcome screen '
  'appears within a minute. On an ordinary x86-64 PC QEMU emulates the CPU: allow several minutes. Each run starts from the unmodified image '
  'unless you keep the overlay; <code>--fresh</code> discards it. Until you press Start, the console shows systemd waiting for '
  '&ldquo;Tor to have bootstrapped&rdquo;: Tor stays offline until you decide how to connect, as in Tails.</p>')
w('<h3>From the repository</h3>')
repo_cmd = "make vm-build    # build the qemu-virt profile (debug build)\nmake vm-test     # boot it and run the smoke test\nmake vm-run      # boot it on this terminal\nmake vm-bundle   # package the test bundle"
w(f'<div class="cmd"><pre id="cmd-repo">{E(repo_cmd)}</pre><button class="copy" type="button" data-target="cmd-repo">Copy</button></div>')
w('</section>')

w('<section><h2>What a VM cannot show</h2><ul class="plain">'
  '<li>The phone\'s display panel, touch screen, Wi-Fi driver and firmware, modem policy, audio routing, battery and thermal behaviour.</li>'
  '<li>The bootloader path: slot B, the Android boot image and its verification.</li>'
  '<li>Tor reaching the network: the build host sits behind an HTTP proxy, so the VM proves that nothing but Tor tries to connect, not that Tor bootstraps.</li>'
  '<li>Speed: emulated boots are far slower than the phone.</li>'
  '</ul><p class="sub">The hardware checklist for the first boot on a OnePlus 7T Pro is <code>docs/hardware-validation.md</code> in the repository.</p></section>')
w('</div></div></div>')
w("""<script>
document.querySelectorAll('.copy').forEach(function (b) {
  b.addEventListener('click', function () {
    var el = document.getElementById(b.dataset.target);
    var text = el.textContent;
    function select() { var r = document.createRange(); r.selectNodeContents(el); var s = window.getSelection(); s.removeAllRanges(); s.addRange(r); }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { b.textContent = 'Copied'; setTimeout(function () { b.textContent = 'Copy'; }, 1500); }, function () { select(); b.textContent = 'Selected'; });
    } else { select(); b.textContent = 'Selected'; }
  });
});
</script>""")
open(a.out, "w").write("\n".join(P))
print(f"{a.out}: {os.path.getsize(a.out)} bytes, {n_ok}/{n_all} checks, {len(a.shot)} screenshots, {len(timeline)} timeline events")
