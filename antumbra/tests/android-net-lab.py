#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Android's network in a namespace lab: the real firewall, the real
start-host hook, and the VM harness's own probes and judge, without a VM.

The lab is a network namespace laid out like the phone with Android apps
on: the waydroid-tor bridge (10.200.2.1/30, forwarding off, ip_forward on),
an uplink with a LAN address and a public one, a confined application's
veth (10.200.1.1), config/rootfs/etc/nftables.conf loaded, and stand-ins
for Tor's two listeners for Android: a TCP acceptor on 10.200.2.1:9041, and
a DNS server on 10.200.2.1:5354 that, like Tor's AutomapHostsOnResolve,
answers a .onion name with an address in 127.192.0.0/10. A second
namespace on the bridge stands in for the container. The start-host hook
runs for it as LXC runs it (LXC_PID one of its processes), then it runs
android_probe_list of tests/vm/antumbra_vm.py, and judge_android_probes
decides, as in the VM's --android-net run.

Run by tests/lint.sh. Needs unprivileged user namespaces, or root; without
them, or without nftables in the kernel, it says so and exits 0. --nft and
--hook take other versions of the two files.
"""
import argparse
import importlib.util
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
UPLINK = "192.168.1.37"
SKIP = 3
# The image's system users, numeric here (as in lint's nft -c).
USERS = {"debian-tor": 9001, "htp": 1101, "clearnet": 1102, "_apt": 9002, "proxy": 13, "nobody": 65534, "root": 0}


def run(*cmd, check=True):
    return subprocess.run(cmd, check=check, text=True, capture_output=True, env=dict(os.environ, PATH=PATH))


def write(path, value):
    with open(path, "w") as f:
        f.write(value)


def tor_stand_ins(onion_answer):
    """Tor's TransPort and DNSPort for Android, as far as the probes see them."""
    tp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    tp.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    tp.bind(("10.200.2.1", 9041))
    tp.listen(64)
    held = []

    def accept():
        while True:
            held.append(tp.accept()[0])

    dp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dp.bind(("10.200.2.1", 5354))

    def answer():
        while True:
            q, peer = dp.recvfrom(2048)
            p, labels = 12, []
            while q[p]:
                labels.append(q[p + 1:p + 1 + q[p]].decode("ascii", "replace"))
                p += q[p] + 1
            question = q[12:p + 5]
            if ".".join(labels).endswith(".onion"):
                rr = b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton(onion_answer)
                dp.sendto(q[:2] + struct.pack("!HHHHH", 0x8180, 1, 1, 0, 0) + question + rr, peer)
            else:
                dp.sendto(q[:2] + struct.pack("!HHHHH", 0x8183, 1, 0, 0, 0) + question, peer)

    for target in (accept, answer):
        threading.Thread(target=target, daemon=True).start()


def lab(args):
    spec = importlib.util.spec_from_file_location("antumbra_vm", os.path.join(ROOT, "tests", "vm", "antumbra_vm.py"))
    vm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(vm)
    tmp = tempfile.mkdtemp(prefix="antumbra-android-lab-")
    container = None
    try:
        # The host.
        run("ip", "link", "set", "lo", "up")
        write("/proc/sys/net/ipv4/ip_forward", "1")
        run("ip", "link", "add", "waydroid-tor", "type", "bridge")
        run("ip", "addr", "add", "10.200.2.1/30", "dev", "waydroid-tor")
        run("ip", "link", "set", "waydroid-tor", "up")
        write("/proc/sys/net/ipv4/conf/waydroid-tor/forwarding", "0")
        for link, peer, addrs in (("wlan0", "wlan0-lan", (UPLINK + "/24", vm.HOST_PUBLIC + "/32")),
                                  ("veth-tbb", "veth-tbb-ns", ("10.200.1.1/30",))):
            run("ip", "link", "add", link, "type", "veth", "peer", "name", peer)
            for a in addrs:
                run("ip", "addr", "add", a, "dev", link)
            run("ip", "link", "set", link, "up")
            run("ip", "link", "set", peer, "up")
        run("ip", "route", "add", "default", "via", "192.168.1.1", "dev", "wlan0")
        with open(args.nft) as f:
            ruleset = f.read()
        for user, uid in USERS.items():
            ruleset = ruleset.replace(f'"{user}"', str(uid))
        r = subprocess.run(["nft", "-f", "-"], input=ruleset, text=True, capture_output=True, env=dict(os.environ, PATH=PATH))
        if r.returncode != 0:
            print(f"skipped: nftables.conf does not load in this namespace (kernel modules?): {r.stderr.strip()[:300]}")
            return SKIP
        tor_stand_ins("127.198.154.224")
        # The container: a process in a network namespace of its own on the bridge.
        container = subprocess.Popen(["unshare", "-n", "sleep", "600"], env=dict(os.environ, PATH=PATH))
        own = os.readlink("/proc/self/ns/net")
        for _ in range(250):
            try:
                if os.readlink(f"/proc/{container.pid}/ns/net") != own:
                    break
            except OSError:
                pass
            time.sleep(0.02)
        else:
            raise RuntimeError("the container's namespace did not appear")
        ct = ("nsenter", "--target", str(container.pid), "--net")
        run("ip", "link", "add", "vethct", "type", "veth", "peer", "name", "eth0", "netns", str(container.pid))
        run("ip", "link", "set", "vethct", "master", "waydroid-tor")
        run("ip", "link", "set", "vethct", "up")
        run(*ct, "ip", "link", "set", "lo", "up")
        run(*ct, "ip", "link", "set", "eth0", "address", vm.ANDROID_MAC)
        run(*ct, "ip", "addr", "add", "10.200.2.2/30", "dev", "eth0")
        run(*ct, "ip", "link", "set", "eth0", "up")
        run(*ct, "ip", "route", "add", "default", "via", "10.200.2.1")
        # The start-host hook, as LXC runs it.
        conf = os.path.join(tmp, "config")
        write(conf, "lxc.net.0.type = veth\nlxc.net.0.link = waydroid-tor\n")
        hook = subprocess.run(["sh", args.hook, "waydroid", "lxc", "start-host"], text=True, capture_output=True,
                              env=dict(os.environ, PATH=PATH, LXC_NAME="waydroid", LXC_PID=str(container.pid), LXC_CONFIG_FILE=conf))
        results = [("lab: the start-host hook passes for the stand-in container", hook.returncode == 0,
                    f"exit {hook.returncode} " + " ".join(l for l in hook.stderr.splitlines() if "refused" in l))]
        # The harness's probes, each in a process of its own, all at once.
        probe = os.path.join(tmp, "probe.py")
        write(probe, vm.ANDROID_PROBE_PY)
        procs = [subprocess.Popen([*ct, sys.executable, probe, "run", json.dumps([p])], text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, PATH=PATH))
                 for p in vm.android_probe_list(UPLINK)]
        res = {}
        for p in procs:
            out, err = p.communicate(timeout=120)
            m = re.search(r"^PROBES (\{.*\})$", out, re.M)
            if p.returncode != 0 or not m:
                results.append(("lab: probe ran", False, (out + err).strip()[-300:]))
                continue
            res.update(json.loads(m.group(1)))
        results += vm.judge_android_probes(res, UPLINK)
        # The .onion probe as the --android run uses it in Android's
        # namespace, its DNS bound to eth0.
        onion = [p for p in vm.android_probe_list(UPLINK) if p[0] == "onion"]
        r = subprocess.run([*ct, sys.executable, probe, "run", json.dumps(onion)], text=True, capture_output=True,
                           env=dict(os.environ, PATH=PATH, ANTUMBRA_PROBE_DNS_DEVICE="eth0"))
        results.append(("lab: the .onion probe with its DNS bound to eth0 (as in --android) is refused too",
                        r.returncode == 0 and r.stdout.strip().endswith('": "refused loopback=connected"}'), (r.stdout + r.stderr).strip()[-200:]))
        if args.verbose:
            print(json.dumps(res, indent=1, sort_keys=True))
        for name, ok, detail in results:
            print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""), flush=True)
        return 0 if all(ok for _, ok, _ in results) else 1
    finally:
        if container is not None:
            container.kill()
            container.wait()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    sys.dont_write_bytecode = True   # no __pycache__ left in tests/vm
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--nft", default=os.path.join(ROOT, "config", "rootfs", "etc", "nftables.conf"))
    ap.add_argument("--hook", default=os.path.join(ROOT, "config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host"))
    ap.add_argument("--verbose", action="store_true", help="print every probe's result")
    ap.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()
    args.nft, args.hook = os.path.abspath(args.nft), os.path.abspath(args.hook)
    if args.inside:
        return lab(args)
    env = dict(os.environ, PATH=PATH)
    missing = [t for t in ("unshare", "nsenter", "ip", "nft") if shutil.which(t, path=PATH) is None]
    if missing:
        print(f"skipped: {', '.join(missing)} not installed")
        return 0
    # Root gets a plain network namespace (the kernel may load nftables
    # modules for it); anyone else a user namespace with one.
    unshare = ["unshare", "-n"] if os.geteuid() == 0 else ["unshare", "-Urn"]
    if subprocess.run(unshare + ["true"], env=env, capture_output=True).returncode != 0:
        print(f"skipped: cannot create a network namespace ({' '.join(unshare)})")
        return 0
    rc = subprocess.run(unshare + [sys.executable, os.path.abspath(__file__), "--inside", "--nft", args.nft, "--hook", args.hook]
                        + (["--verbose"] if args.verbose else []), env=env).returncode
    return 0 if rc == SKIP else rc


if __name__ == "__main__":
    sys.exit(main())
