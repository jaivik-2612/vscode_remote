#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Cold-cache read benchmark of a mounted squashfs.
usage: readbench.py MOUNTPOINT MODE [N]
MODE seq: read every file once, sequentially (1 MiB reads), single thread.
MODE rand: N random 4 KiB reads spread over all files (seeded), single thread.
Caches must be dropped by the caller before each run."""
import os, random, sys, time

root, mode = sys.argv[1], sys.argv[2]
n = int(sys.argv[3]) if len(sys.argv) > 3 else 2000
files = []
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f)
        if os.path.isfile(p) and not os.path.islink(p):
            files.append((p, os.path.getsize(p)))
files.sort()
t0 = time.monotonic()
total = 0
if mode == "seq":
    for p, _ in files:
        with open(p, "rb", buffering=0) as fh:
            while True:
                b = fh.read(1 << 20)
                if not b:
                    break
                total += len(b)
else:
    rng = random.Random(42)
    big = [(p, s) for p, s in files if s >= 1 << 20]
    if not big:
        sys.exit(f"rand reads files of 1 MiB or more; there are none under {root}")
    weights = [s for _, s in big]
    picks = rng.choices(big, weights=weights, k=n)
    fds = {}
    for p, s in picks:
        fd = fds.get(p)
        if fd is None:
            fd = fds[p] = os.open(p, os.O_RDONLY)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_RANDOM)
        off = rng.randrange(0, s // 4096) * 4096
        total += len(os.pread(fd, 4096, off))
    for fd in fds.values():
        os.close(fd)
dt = time.monotonic() - t0
print(f"{mode} bytes={total} seconds={dt:.3f} MiB/s={total/dt/1048576:.1f}" + (f" ms/read={dt*1000/n:.3f}" if mode != "seq" else ""))
