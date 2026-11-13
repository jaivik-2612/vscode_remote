#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Metrics and job summary of a daily VM run (.github/workflows/antumbra-vm.yml).

Reads what the run left in OUT (phases.tsv from phase.sh; vm/ from
run-smoke.sh) and in the qemu-virt build directory, copies the build's small
records to OUT/build/ (build-flags, packages.txt, the kernel's release and
configuration), and writes OUT/metrics.json and a Markdown summary for the
job summary page. Any input may be missing (a run that failed early): its
entries are then null, and the summary says what is missing.

usage: metrics.py --out DIR [--build-out DIR] [--summary FILE] [--max-artifact-mib N]

metrics.json (schema 1):
  run      run number, attempt, URL, event, commit (hash, subject, time), Android or not,
           smoke options, timeout scale, whether this is the workflow's first run
  runner   runner image, CPUs, memory, /dev/kvm, QEMU version and accelerator
  phases   [{name, seconds, status}] wall time of each phase (phase.sh), kernel cache hit,
           the job's wall time up to this script
  build    version, build-flags, kernel release, sizes in bytes (kernel Image, modules,
           initramfs, squashfs, its verity tree, VM disk and the disk's allocated part),
           package count
  harness  exit status, timed out, checks passed/failed/total, failed check names, the
           harness's wall time, and every check as {name, ok, t} (t: seconds since the
           harness started the VM)
  boot     guest milestones in seconds of guest uptime, from the serial log's kernel
           timestamps; output without a timestamp of its own (the initramfs's, the
           shutdown hook's) takes the next timestamp, and milestone_bounds gives
           [last timestamp before, next] for those; Phosh's own "ready after"
           figure; systemd's "Startup finished" line
  tor      every bootstrap step Tor logged ({percent, tag, t}, first time each), the
           highest percentage, and when it reached 100% if it did
  artifact bytes and files of OUT (before metrics.json and the summary, a few KiB),
           and what was dropped to keep it under the limit

Times measured under full emulation (TCG) are many times slower than the phone;
compare them between runs, not with the phone. Standard library only.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
SCHEMA = 1

# Terminal control sequences in the serial log (systemd's colours and status line).
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")
# A kernel timestamp: [%5lu.%06lu].
KTIME = re.compile(r"\[\s*(\d+\.\d{6})\]")

# Guest milestones: the first segment of the serial log matching each.
MILESTONES = (
    ("kernel_init", r"Run /init as init process"),
    ("initramfs_medium_search", r"antumbra: locating the system partition"),
    ("initramfs_live_bottom", r"Begin: Running /scripts/live-bottom"),
    ("systemd_start", r"systemd\[1\]: systemd \S+ running in system mode"),
    ("basic_target", r"systemd\[1\]: Reached target basic\.target"),
    ("greetd_started", r"systemd\[1\]: Started greetd\.service"),
    ("multi_user_target", r"systemd\[1\]: Reached target multi-user\.target"),
    ("graphical_target", r"systemd\[1\]: Reached target graphical\.target"),
    ("welcome_settings_applied", r"antumbra-welcome\[\d+\]: welcome settings applied"),
    ("session_opened", r"greetd\[\d+\]: pam_unix\(greetd:session\): session opened for user amnesia\("),
    ("phosh_ready", r"phosh\[\d+\]: Phosh ready after"),
    ("powering_down", r"systemd-logind\[\d+\]: System is powering down"),
    ("poweroff_target", r"systemd\[1\]: Reached target poweroff\.target"),
    ("shutdown_caches_dropped", r"^antumbra-shutdown: caches dropped"),
    ("power_down", r"reboot: Power down"),
)
TOR_STEP = re.compile(r"Tor\[\d+\]: Bootstrapped (\d+)% \(([^)]*)\)")
PHOSH_READY = re.compile(r"Phosh ready after ([\d.]+)s")
SYSTEM_STARTUP = re.compile(r"systemd\[1\]: Startup finished in (.*)")
# vm.sh's start line: "qemu-virt: 4096 MiB, 3 CPUs, tcg,thread=multi, ..."
VM_START = re.compile(r"qemu-virt: (\d+) MiB, (\d+) CPUs, ([a-z]+)")
# The harness's "[PASS] name: detail" lines. Names contain ": " too, so a
# line read back is kept whole.
CHECK_LINE = re.compile(r"^\[(PASS|FAIL)\] (.*)$")


def read_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return None


def size(path, allocated=False):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return st.st_blocks * 512 if allocated else st.st_size


def serial_segments(text):
    """(seconds, own, text) for every piece of the serial log, a piece being
    what follows a kernel timestamp (own: the time is its own), or what
    precedes the first timestamp of a line (initramfs and shutdown-hook
    output, which has none: the time is the last timestamp before it)."""
    last = None
    for raw in text.split("\n"):
        line = ANSI.sub("", raw).replace("\r", "")
        pos = 0
        own = False
        for m in KTIME.finditer(line):
            piece = line[pos:m.start()].strip()
            if piece:
                yield last, own, piece
            last = float(m.group(1))
            pos = m.end()
            own = True
        piece = line[pos:].strip()
        if piece:
            yield last, own, piece


def boot_metrics(text):
    if text is None:
        return None, None
    boot = {"milestones": {name: None for name, _ in MILESTONES}, "milestone_bounds": {},
            "phosh_ready_after_seconds": None, "systemd_startup_finished": None}
    tor = {"steps": [], "max_percent": None, "done_at": None}
    patterns = [(name, re.compile(rx)) for name, rx in MILESTONES]
    seen = set()
    pending = []   # milestones seen on a piece without a timestamp, waiting for the next one
    for t, own, piece in serial_segments(text):
        if own and pending:
            for name in pending:
                boot["milestones"][name] = t
                boot["milestone_bounds"][name][1] = t
            pending = []
        for name, rx in patterns:
            if boot["milestones"][name] is None and name not in boot["milestone_bounds"] and rx.search(piece):
                if own:
                    boot["milestones"][name] = t
                else:
                    # Between the last timestamp and the next: the next one
                    # is the milestone's time ("reached by").
                    boot["milestone_bounds"][name] = [t, None]
                    pending.append(name)
        m = PHOSH_READY.search(piece)
        if m and boot["phosh_ready_after_seconds"] is None:
            boot["phosh_ready_after_seconds"] = float(m.group(1))
        m = SYSTEM_STARTUP.search(piece)
        if m and boot["systemd_startup_finished"] is None:
            boot["systemd_startup_finished"] = m.group(1).strip()
        m = TOR_STEP.search(piece)
        if m and int(m.group(1)) not in seen:
            seen.add(int(m.group(1)))
            tor["steps"].append({"percent": int(m.group(1)), "tag": m.group(2), "t": t})
    for name in pending:   # no timestamp after it: the last one before it
        boot["milestones"][name] = boot["milestone_bounds"][name][0]
    if tor["steps"]:
        tor["max_percent"] = max(s["percent"] for s in tor["steps"])
        done = [s["t"] for s in tor["steps"] if s["percent"] == 100]
        tor["done_at"] = done[0] if done else None
    return boot, tor


def harness_metrics(vm_dir):
    """The checks from report.json, or, when the harness did not get to write
    it (stopped at the time limit), from its PASS/FAIL lines."""
    info = read_json(os.path.join(vm_dir, "harness.json")) or {}
    report = read_json(os.path.join(vm_dir, "smoke", "report.json"))
    checks, source = [], None
    if report and isinstance(report.get("checks"), list):
        checks = [{"name": c.get("name"), "ok": bool(c.get("ok")), "t": c.get("t"), "detail": c.get("detail", "")}
                  for c in report["checks"]]
        source = "report.json"
    else:
        log = read_text(os.path.join(vm_dir, "smoke.log"))
        if log is not None:
            for line in log.split("\n"):
                m = CHECK_LINE.match(line)
                if m:
                    checks.append({"name": m.group(2), "ok": m.group(1) == "PASS", "t": None, "detail": ""})
            source = "smoke.log"
    failed = [c for c in checks if not c["ok"]]
    times = [c["t"] for c in checks if isinstance(c["t"], (int, float))]
    return {
        "exit_status": info.get("exit_status"),
        "timed_out": info.get("timed_out"),
        "limit_seconds": info.get("limit_seconds"),
        "seconds": info.get("seconds"),
        "smoke_args": info.get("smoke_args"),
        "timeout_scale": info.get("timeout_scale"),
        "checks_source": source,
        "checks_total": len(checks) if source else None,
        "checks_passed": len(checks) - len(failed) if source else None,
        "checks_failed": len(failed) if source else None,
        "failed": [c["name"] for c in failed],
        "last_check_t": max(times) if times else None,
        "checks": [{"name": c["name"], "ok": c["ok"], "t": c["t"]} for c in checks],
    }, failed, info


def vm_start_line(vm_dir):
    log = read_text(os.path.join(vm_dir, "smoke.log")) or ""
    m = VM_START.search(log)
    return {"memory_mib": int(m.group(1)), "cpus": int(m.group(2)), "accel": m.group(3)} if m else {}


def phases_metrics(out):
    phases = {}
    try:
        with open(os.path.join(out, "phases.tsv")) as f:
            lines = f.read().split("\n")
    except OSError:
        lines = []
    for line in lines:
        f = line.split("\t")
        if len(f) != 4 or not all(x.lstrip("-").isdigit() for x in f[1:]):
            continue
        p = phases.setdefault(f[0], {"name": f[0], "seconds": 0, "status": 0})
        p["seconds"] += int(f[2]) - int(f[1])
        if p["status"] == 0:
            p["status"] = int(f[3])
    return list(phases.values())


def build_metrics(build_out, out):
    """Sizes and records of the qemu-virt build; the small records are copied to OUT/build/."""
    k, r = os.path.join(build_out, "kernel"), os.path.join(build_out, "rootfs")
    dest = os.path.join(out, "build")
    os.makedirs(dest, exist_ok=True)
    for src, name in ((os.path.join(r, "build-flags"), "build-flags"), (os.path.join(r, "packages.txt"), "packages.txt"),
                      (os.path.join(k, "kernel.release"), "kernel.release"), (os.path.join(k, "config"), "kernel-config")):
        try:
            shutil.copyfile(src, os.path.join(dest, name))
        except OSError:
            pass
    flags = {}
    for line in (read_text(os.path.join(r, "build-flags")) or "").split("\n"):
        if "=" in line:
            key, value = line.split("=", 1)
            flags[key] = value
    packages = read_text(os.path.join(r, "packages.txt"))
    release = read_text(os.path.join(k, "kernel.release"))
    return {
        "version": (read_text(os.path.join(ROOT, "VERSION")) or "").strip() or None,
        "build_flags": flags or None,
        "kernel_release": release.strip() if release else None,
        "sizes": {
            "kernel_image": size(os.path.join(k, "Image")),
            "kernel_modules": size(os.path.join(k, "modules.tar.zst")),
            "initrd": size(os.path.join(r, "initrd.img")),
            "squashfs": size(os.path.join(r, "filesystem.squashfs")),
            "squashfs_verity": size(os.path.join(r, "filesystem.squashfs.verity")),
            "vm_disk": size(os.path.join(build_out, "vm-disk.img")),
            "vm_disk_allocated": size(os.path.join(build_out, "vm-disk.img"), allocated=True),
        },
        "packages": len([x for x in packages.split("\n") if x.strip()]) if packages is not None else None,
    }


def git(*args):
    try:
        return subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def run_metrics(info):
    env = os.environ
    log = git("log", "-1", "--format=%H%n%ct%n%s")
    commit = dict(zip(("hash", "time", "subject"), log.split("\n", 2))) if log else {}
    if "time" in commit:
        commit["time"] = int(commit["time"])
    number = env.get("GITHUB_RUN_NUMBER")
    url = None
    if env.get("GITHUB_SERVER_URL") and env.get("GITHUB_REPOSITORY") and env.get("GITHUB_RUN_ID"):
        url = f"{env['GITHUB_SERVER_URL']}/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
    return {
        "number": int(number) if number and number.isdigit() else None,
        "attempt": int(env["GITHUB_RUN_ATTEMPT"]) if env.get("GITHUB_RUN_ATTEMPT", "").isdigit() else None,
        "url": url,
        "event": env.get("GITHUB_EVENT_NAME"),
        "ref": env.get("GITHUB_REF_NAME"),
        "commit": commit.get("hash") or env.get("GITHUB_SHA"),
        "commit_short": (commit.get("hash") or env.get("GITHUB_SHA") or "")[:7] or None,
        "commit_subject": commit.get("subject"),
        "commit_time": commit.get("time"),
        "android": env.get("ANTUMBRA_ANDROID") == "1",
        "smoke_args": info.get("smoke_args"),
        "timeout_scale": info.get("timeout_scale"),
        "first_run": number == "1",
    }


def runner_metrics(info, vm_dir):
    env = os.environ
    mem = None
    for line in (read_text("/proc/meminfo") or "").split("\n"):
        if line.startswith("MemTotal:"):
            mem = int(line.split()[1]) // 1024
    start = vm_start_line(vm_dir)
    return {
        "os": env.get("RUNNER_OS"), "arch": env.get("RUNNER_ARCH"),
        "image": env.get("ImageOS"), "image_version": env.get("ImageVersion"),
        "cpus": os.cpu_count(), "memory_mib": mem,
        "kvm": info.get("kvm", os.path.exists("/dev/kvm")),
        "qemu_version": info.get("qemu_version"),
        "accel": start.get("accel"), "vm_memory_mib": start.get("memory_mib"), "vm_cpus": start.get("cpus"),
    }


def tree_size(path):
    total = files = 0
    for d, _, names in os.walk(path):
        for n in names:
            total += size(os.path.join(d, n)) or 0
            files += 1
    return total, files


def duration(s):
    if s is None:
        return "-"
    s = int(round(s))
    if s < 60:
        return f"{s} s"
    if s < 3600:
        return f"{s // 60} min {s % 60:02d} s"
    return f"{s // 3600} h {s % 3600 // 60:02d} min"


def mib(n):
    return "-" if n is None else f"{n / 1048576:.1f} MiB"


def one_line(s, n=240):
    s = " ".join(str(s).split()).replace("|", "/")
    return s if len(s) <= n else s[:n - 3] + "..."


def summary(m, failed):
    run, h, b, boot, tor = m["run"], m["harness"], m["build"], m["boot"], m["tor"]
    if h["checks_source"] is None and h["exit_status"] is None:
        verdict = "NO RESULT (the smoke test did not run)"
    elif h["timed_out"]:
        verdict = f"STOPPED AT THE TIME LIMIT ({h['checks_passed'] or 0}/{h['checks_total'] or 0} checks passed before)"
    elif not h["checks_total"]:
        verdict = "NO RESULT (no check reported)"
    elif h["checks_failed"] == 0 and h["exit_status"] in (0, None):
        verdict = f"PASSED ({h['checks_passed']}/{h['checks_total']} checks)"
    else:
        verdict = f"FAILED ({h['checks_passed']}/{h['checks_total']} checks passed)"
    lines = [f"## Antumbra VM run{' #' + str(run['number']) if run['number'] else ''}: {verdict}", ""]
    mode = " ".join(h["smoke_args"] or []) or "-"
    flags = b["build_flags"] or {}
    android = flags["ANTUMBRA_ANDROID"] == "1" if "ANTUMBRA_ANDROID" in flags else run["android"]
    lines.append(f"Build {b['version'] or '?'} from `{run['commit_short'] or '?'}`"
                 + (f" ({one_line(run['commit_subject'], 100)})" if run["commit_subject"] else "")
                 + f"; qemu-virt debug image {'with' if android else 'without'} Android apps;"
                 + (f" smoke test `{mode}`, timeout scale {h['timeout_scale']}" if h["smoke_args"] is not None else " no smoke test")
                 + (f"; QEMU with {m['runner']['accel']}{' (no KVM)' if not m['runner']['kvm'] else ''}" if m["runner"]["accel"] else "")
                 + f"; {m['runner']['cpus']} host CPUs.")
    if run["first_run"]:
        lines += ["", "This is the workflow's first run: baseline 0."]
    lines += ["", "| Phase | Wall time | Exit status |", "|---|---|---|"]
    for p in m["phases"]["list"]:
        lines.append(f"| {p['name']} | {duration(p['seconds'])} | {p['status']} |")
    if m["phases"]["kernel_cache_hit"]:
        lines.append("| kernel | cached | - |")
    lines.append(f"| **job so far** | **{duration(m['phases']['job_seconds'])}** | |")
    if failed:
        lines += ["", f"### Failed checks ({len(failed)})", ""]
        lines += [f"- {one_line(c['name'], 160)}" + (f": {one_line(c['detail'])}" if c.get("detail") else "") for c in failed[:40]]
        if len(failed) > 40:
            lines.append(f"- ... and {len(failed) - 40} more (vm/smoke.log)")
    if boot:
        lines += ["", "### Boot (seconds of guest uptime, serial log)", "", "| Milestone | Guest time |", "|---|---|"]
        for name, t in sorted(((n, t) for n, t in boot["milestones"].items() if t is not None), key=lambda x: x[1]):
            bounds = boot["milestone_bounds"].get(name)
            after = f" (after {bounds[0]:.1f} s)" if bounds and bounds[0] is not None and bounds[1] is not None else ""
            lines.append(f"| {name.replace('_', ' ')} | {'by ' if after else ''}{t:.1f} s{after} |")
        missing = [n.replace("_", " ") for n, t in boot["milestones"].items() if t is None]
        if missing:
            lines += ["", "Not seen: " + ", ".join(missing) + "."]
        if boot["phosh_ready_after_seconds"] is not None:
            lines += ["", f"Phosh reports itself ready after {boot['phosh_ready_after_seconds']:.1f} s."]
    if tor and tor["steps"]:
        last = max(tor["steps"], key=lambda s: s["percent"])
        lines += ["", f"Tor bootstrap: highest {tor['max_percent']}% ({last['tag']}) at {last['t'] or 0:.1f} s"
                  + ("." if tor["done_at"] is not None else "; it did not reach 100% during the run.")]
    elif boot is not None:
        lines += ["", "Tor bootstrap: no step logged."]
    if h["seconds"] is not None:
        lines += ["", f"Smoke test wall time {duration(h['seconds'])}"
                  + (f", last check at {duration(h['last_check_t'])} after the VM started." if h["last_check_t"] else ".")]
    s = b["sizes"]
    lines += ["", "### Image", "", "| | Size |", "|---|---|",
              f"| kernel Image | {mib(s['kernel_image'])} |", f"| kernel modules | {mib(s['kernel_modules'])} |",
              f"| initramfs | {mib(s['initrd'])} |", f"| squashfs | {mib(s['squashfs'])} |",
              f"| VM disk (allocated) | {mib(s['vm_disk_allocated'])} |",
              f"| packages | {b['packages'] if b['packages'] is not None else '-'} |",
              "", f"Artifact: {m['artifact']['files']} files, {mib(m['artifact']['bytes'])}"
              + (f" (dropped to stay under the limit: {', '.join(m['artifact']['dropped'])})" if m["artifact"]["dropped"] else "") + "."]
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description="Metrics and job summary of a daily VM run.")
    ap.add_argument("--out", required=True, help="the run's output directory (ANTUMBRA_CI_OUT)")
    ap.add_argument("--build-out", default=None, help="the qemu-virt build outputs (default: ANTUMBRA_OUT or build/out, /qemu-virt)")
    ap.add_argument("--summary", default=None, help="write the Markdown summary here (default: standard output)")
    ap.add_argument("--max-artifact-mib", type=float, default=29.0, help="above this, drop the packet capture, then cut the logs")
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    vm_dir = os.path.join(out, "vm")
    build_out = a.build_out or os.path.join(os.environ.get("ANTUMBRA_OUT") or os.path.join(ROOT, "build", "out"), "qemu-virt")
    os.makedirs(out, exist_ok=True)

    harness, failed, info = harness_metrics(vm_dir)
    boot, tor = boot_metrics(read_text(os.path.join(vm_dir, "serial.log")))
    job_start = os.environ.get("JOB_START", "")
    m = {
        "schema": SCHEMA,
        "generated": int(time.time()),
        "run": run_metrics(info),
        "runner": runner_metrics(info, vm_dir),
        "phases": {"list": phases_metrics(out), "kernel_cache_hit": os.environ.get("KERNEL_CACHE_HIT") == "true",
                   "job_seconds": int(time.time()) - int(job_start) if job_start.isdigit() else None},
        "build": build_metrics(build_out, out),
        "harness": harness,
        "boot": boot,
        "tor": tor,
    }
    # The artifact limit: the packet capture goes first (pcap-summary.txt
    # stays), then the serial log is cut to its last 2 MiB.
    limit = int(a.max_artifact_mib * 1048576)
    dropped = []
    total, files = tree_size(out)
    if total > limit and os.path.exists(os.path.join(vm_dir, "net.pcap")):
        os.unlink(os.path.join(vm_dir, "net.pcap"))
        dropped.append("vm/net.pcap")
        total, files = tree_size(out)
    serial = os.path.join(vm_dir, "serial.log")
    if total > limit and (size(serial) or 0) > 2 * 1048576:
        with open(serial, "rb") as f:
            f.seek(-2 * 1048576, os.SEEK_END)
            tail = f.read()
        with open(serial, "wb") as f:
            f.write(b"[... metrics.py: cut to the last 2 MiB to keep the artifact small ...]\n" + tail)
        dropped.append("vm/serial.log (all but its last 2 MiB)")
        total, files = tree_size(out)
    m["artifact"] = {"bytes": total, "files": files, "limit_bytes": limit, "dropped": dropped}
    text = summary(m, failed)
    with open(os.path.join(out, "metrics.json"), "w") as f:
        json.dump(m, f, indent=1)
        f.write("\n")
    if a.summary:
        with open(a.summary, "w") as f:
            f.write(text)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
