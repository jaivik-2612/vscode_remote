# VM performance baselines

Two scripts from the October 2026 performance research
(`docs/plan/research-2026-10/`). Neither is part of `make vm-test`; both
use only Python's standard library.

## vmperf.py: memory, wake-ups, boot steps and running services

Boots the existing qemu-virt debug image, waits for the Welcome screen,
measures, taps Start, waits for the Phosh session and measures again, then
quits QEMU. It reads the build outputs and writes nothing next to them:
the disk is a qcow2 overlay in the run directory, so nothing copies the
4 GB `vm-disk.img`.

```sh
make vm-build                                  # once: a debug qemu-virt image (ANTUMBRA_DEBUG=1)
PYTHONDONTWRITEBYTECODE=1 tests/vm/perf/vmperf.py /tmp/vmperf-run 8192
less /tmp/vmperf-run/measurements.txt
```

`vmperf.py [--out DIR] RUN_DIR [MEMORY_MIB]`: `RUN_DIR` holds the run's
files (overlay, sockets, serial and console logs, `welcome.png`,
`session.png`, `measurements.txt`, which each run appends to); `--out` names
the build outputs (default `build/out/qemu-virt`); the guest gets 8192 MiB
unless told otherwise (`build/vm.sh` defaults to 4096). It starts QEMU
itself, like `build/vm.sh` but with the overlay instead of a disk copy,
under TCG with 3 CPUs, and drives the guest through the debug console with
the harness in `tests/vm/antumbra_vm.py`. Under emulation a run takes about
15 minutes.

At the Welcome screen and again 3 minutes after phosh starts it records:

- `systemd-analyze` and the critical chain (both print nothing until Tor
  has bootstrapped, so in a VM without a route to Tor they never do), and
  `systemd-analyze blame`, top 30, which works before boot finishes;
- `/proc/meminfo`, `zramctl`, the RAM overlay's use, memory pressure,
  transparent huge pages, `vm.swappiness` and `vm.page-cluster`;
- proportional set size (PSS) per process, top 30, from `smaps_rollup`;
- interrupts and context switches per second over 60 s at idle, per task;
- the running system and user services;

and, at the end, Tor's bootstrap lines from the journal. Absolute times are
inflated by emulation (roughly 10 to 30 times slower than the phone is
expected to be): compare rankings, memory and wake-ups between builds, not
seconds. GPU, display, 90 Hz, frame pacing, battery, suspend, the modem and
Wi-Fi power cannot be measured in a VM.

The run of 9 Oct 2026 (the 6 Oct image with Android apps, 8192 MiB, x86-64
host, 3 vCPUs, TCG) is kept as
`docs/plan/research-2026-10/vm-baseline-2026-10-09.txt`. It is context
only: the daily VM run's first result is the baseline that later changes
are compared with.

## readbench.py: squashfs read speed

A cold-cache read benchmark of a mounted squashfs, single-threaded:

```sh
readbench.py MOUNTPOINT seq        # every file once, 1 MiB reads
readbench.py MOUNTPOINT rand [N]   # N (default 2000) seeded random 4 KiB reads in files of 1 MiB or more
```

The caller drops the page cache before each run. The October comparison
built squashfs images of the same 493 MiB subset of the root filesystem
(Tor Browser, libLLVM, libgallium, GTK 4, libadwaita) with different
compression, mounted each read-only and ran both modes on it. In outline
(the exact commands were not kept):

```sh
mksquashfs SUBSET/ xz-1M.sqfs -comp xz -Xbcj arm -Xdict-size 1M -b 1M   # as build/squashfs.sh
mksquashfs SUBSET/ zstd-1M.sqfs -comp zstd -Xcompression-level 19 -b 1M
mount -o ro,loop xz-1M.sqfs /mnt/sq
sync; echo 3 > /proc/sys/vm/drop_caches; readbench.py /mnt/sq seq
sync; echo 3 > /proc/sys/vm/drop_caches; readbench.py /mnt/sq rand
```

The results (zstd reads about 11 times faster sequentially and 13 times
faster at random, for 10 to 17% more space) are in
`docs/plan/research-2026-10/research.md`. The host's x86 numbers are not
the phone's, but the ratio comes from decompression cost and should carry
over. On a running image, the same question in one line:
`sync; echo 3 > /proc/sys/vm/drop_caches; time cat /usr/local/lib/tor-browser/libxul.so >/dev/null`.
