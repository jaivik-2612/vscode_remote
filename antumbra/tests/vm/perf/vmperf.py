#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Boot the existing qemu-virt debug image (read-only use of the build
outputs; all run files go to RUN_DIR), take performance baselines on the debug
console at the Welcome screen and after login, then quit QEMU.

usage: vmperf.py [--out DIR] RUN_DIR [MEMORY_MIB]
  --out       the qemu-virt build outputs (default: build/out/qemu-virt of this checkout)
  MEMORY_MIB  the guest's memory (default 8192)
The measurements are appended to RUN_DIR/measurements.txt."""
import argparse, os, subprocess, sys, time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "tests", "vm"))
import antumbra_vm as h  # noqa: E402  (the repo's harness, imported read-only)

ap = argparse.ArgumentParser(description="Performance baselines of the qemu-virt debug image.")
ap.add_argument("run_dir")
ap.add_argument("memory", nargs="?", default="8192")
ap.add_argument("--out", default=os.path.join(REPO, "build", "out", "qemu-virt"))
a = ap.parse_args()
RUN = os.path.abspath(a.run_dir)
MEM = a.memory
OUTQ = os.path.abspath(a.out)
os.makedirs(RUN, exist_ok=True)
LOG = open(os.path.join(RUN, "measurements.txt"), "a")


def log(title, text):
    s = f"\n===== {title} ({time.strftime('%H:%M:%S')}) =====\n{text}\n"
    LOG.write(s)
    LOG.flush()
    print(s, flush=True)


cmdline = open(os.path.join(REPO, "device/qemu-virt/cmdline.txt")).read().replace("\n", "").strip()
roothash = open(os.path.join(OUTQ, "rootfs/filesystem.squashfs.roothash")).read().strip()
cmdline += (f" dm-verity-root-hash=filesystem.squashfs:{roothash} dm-verity-oncorruption=panic"
            " antumbra.debug=1 panic=10")
overlay = os.path.join(RUN, "overlay.qcow2")
if os.path.exists(overlay):
    os.unlink(overlay)
subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-b", os.path.join(OUTQ, "vm-disk.img"), "-F", "raw", overlay], check=True)
for f in ("serial.log", "hvc0.log"):
    open(os.path.join(RUN, f), "w").close()
args = ["qemu-system-aarch64", "-M", "virt,gic-version=3", "-cpu", "cortex-a72", "-smp", "3", "-m", MEM,
        "-accel", "tcg,thread=multi",
        "-kernel", os.path.join(OUTQ, "kernel/Image"), "-initrd", os.path.join(OUTQ, "rootfs/initrd.img"),
        "-append", cmdline,
        "-drive", f"if=none,id=userdata,file={overlay},format=qcow2,cache=writeback,discard=unmap",
        "-device", "virtio-blk-pci,drive=userdata,logical_block_size=4096,physical_block_size=4096",
        "-device", "virtio-rng-pci",
        "-device", "virtio-gpu-pci,xres=720,yres=1440", "-device", "virtio-keyboard-pci", "-device", "virtio-tablet-pci",
        "-device", "virtio-serial-pci",
        "-chardev", f"socket,id=hvc0,path={RUN}/hvc0.sock,server=on,wait=off,logfile={RUN}/hvc0.log",
        "-device", "virtconsole,chardev=hvc0",
        "-qmp", f"unix:{RUN}/qmp.sock,server=on,wait=off", "-no-reboot",
        "-netdev", "user,id=net0", "-device", "virtio-net-pci,netdev=net0,mac=52:54:00:a1:7b:01",
        "-display", "none",
        "-chardev", f"socket,id=ser0,path={RUN}/serial.sock,server=on,wait=off,logfile={RUN}/serial.log",
        "-serial", "chardev:ser0", "-daemonize", "-pidfile", f"{RUN}/qemu.pid"]
t_start = time.monotonic()
subprocess.run(args, check=True)
vm = h.VM(RUN)
vm.console.wait_ready(900)
log("debug console ready", f"{time.monotonic() - t_start:.0f} s after QEMU start (TCG, 3 vCPU, {MEM} MiB)")


def sh(cmd, timeout=300):
    rc, out = vm.console.run(cmd, timeout=timeout)
    return out


PSS = r"""python3 - <<'EOF'
import os,re
rows=[]
for p in os.listdir('/proc'):
    if not p.isdigit(): continue
    try:
        t=open(f'/proc/{p}/smaps_rollup').read()
        comm=open(f'/proc/{p}/comm').read().strip()
        u=open(f'/proc/{p}/status').read()
    except Exception: continue
    pss=int(re.search(r'^Pss:\s+(\d+)',t,re.M).group(1)) if 'Pss:' in t else 0
    rss=int(re.search(r'^Rss:\s+(\d+)',t,re.M).group(1)) if 'Rss:' in t else 0
    uid=re.search(r'^Uid:\s+(\d+)',u,re.M).group(1)
    rows.append((pss,rss,p,uid,comm))
rows.sort(reverse=True)
print('total PSS MiB %.0f over %d processes'%(sum(r[0] for r in rows)/1024,len(rows)))
for pss,rss,p,uid,comm in rows[:30]:
    print('%7.1f %7.1f %6s %6s %s'%(pss/1024,rss/1024,p,uid,comm))
EOF"""

WAKE = r"""python3 - <<'EOF'
import os,re,time
def snap():
    d={}
    for p in os.listdir('/proc'):
        if not p.isdigit(): continue
        try:
            for t in os.listdir(f'/proc/{p}/task'):
                s=open(f'/proc/{p}/task/{t}/status').read()
                v=int(re.search(r'voluntary_ctxt_switches:\s+(\d+)',s).group(1))
                n=int(re.search(r'nonvoluntary_ctxt_switches:\s+(\d+)',s).group(1))
                c=open(f'/proc/{p}/comm').read().strip()
                k=(p,c); d[k]=d.get(k,0)+v+n
        except Exception: pass
    return d
def irqs():
    tot=0
    for l in open('/proc/interrupts').read().split('\n')[1:]:
        f=l.split()
        if len(f)>1:
            tot+=sum(int(x) for x in f[1:] if x.isdigit())
    return tot
a=snap(); ia=irqs(); t0=time.monotonic()
time.sleep(60)
b=snap(); ib=irqs(); dt=time.monotonic()-t0
rows=sorted(((b[k]-a.get(k,0))/dt,k) for k in b if k in a)
rows.reverse()
print('interrupts/s %.1f, context switches/s (user+kernel threads) %.1f over %.0f s'%((ib-ia)/dt,sum(r[0] for r in rows),dt))
for r,(p,c) in rows[:20]:
    print('%8.2f/s %6s %s'%(r,p,c))
EOF"""

MEMINFO = ("free -m; grep -E '^(MemTotal|MemAvailable|Cached|Shmem|AnonPages|AnonHugePages|Slab|SUnreclaim|KernelStack|PageTables|SwapTotal|SwapFree):' /proc/meminfo;"
           " zramctl; df -m /run/live/overlay 2>/dev/null || findmnt -no SOURCE,SIZE,USED,AVAIL /run/live/overlay;"
           " cat /proc/pressure/memory; cat /sys/kernel/mm/transparent_hugepage/enabled; sysctl vm.swappiness vm.page-cluster")


def phase(label):
    log(f"{label}: systemd-analyze", sh("systemd-analyze 2>&1; systemd-analyze critical-chain --no-pager 2>&1 | head -40"))
    log(f"{label}: blame (top 30)", sh("systemd-analyze blame --no-pager 2>&1 | head -30"))
    log(f"{label}: memory", sh(MEMINFO))
    log(f"{label}: PSS by process (MiB: PSS RSS pid uid comm)", sh(PSS))
    log(f"{label}: idle wakeups over 60 s", sh(WAKE, timeout=400))
    log(f"{label}: running units", sh("systemctl list-units --type=service --state=running --no-legend --no-pager | awk '{print $1}' | tr '\\n' ' '; echo; "
                                      "for u in $(loginctl list-users --no-legend | awk '{print $2}'); do echo \"user $u:\"; "
                                      "systemctl --user -M $u@ list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}' | tr '\\n' ' '; echo; done"))


# Wait for the Welcome screen to be on the display.
deadline = time.monotonic() + 900
target = None
while time.monotonic() < deadline:
    target = vm.find_color(h.WELCOME_ACCENT, tol=30, region=(0, 1100, 720, 1440))
    if target:
        break
    time.sleep(10)
log("welcome screen", f"Start button {target} at {time.monotonic() - t_start:.0f} s")
vm.screenshot(os.path.join(RUN, "welcome.png"))
time.sleep(60)
phase("WELCOME")
if target:
    t_tap = time.monotonic()
    vm.tap(*target)
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        o = sh("pgrep -xc phosh; ls /run/user 2>/dev/null | tr '\\n' ' '", timeout=60)
        if o.split("\n")[0].strip().isdigit() and int(o.split("\n")[0]) > 0:
            break
        time.sleep(5)
    log("session", f"phosh running {time.monotonic() - t_tap:.0f} s after tapping Start")
    time.sleep(180)
    vm.screenshot(os.path.join(RUN, "session.png"))
    phase("SESSION (3 min after phosh started)")
    log("journal: Tor bootstrap lines", sh("journalctl -o short-monotonic --no-pager -t Tor 2>/dev/null | grep -E 'Bootstrapped|clock|skew' | tail -15"))
log("done", f"total {time.monotonic() - t_start:.0f} s")
try:
    vm.qmp("quit")
except Exception as e:  # noqa: BLE001
    log("quit failed", str(e))
