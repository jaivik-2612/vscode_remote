# Research, October 2026

The evidence behind the plan whose tasks are in `../queue.md`: six research
strands and one experiment, run on 9 Oct 2026 against the qemu-virt debug
image of 6 Oct (0.1.0-alpha.1, with Android apps), the alpha.2 phone
release of 8 Oct, the repository of that day and public sources.

| File | What it is |
|---|---|
| `research.md` | the findings, what they imply and the open questions, strand by strand: the interface today, testing without the phone, a Termux preview on the phone, unlocking and flashing without a computer, closer to Android, performance, and the nested-Phosh experiment |
| `vm-baseline-2026-10-09.txt` | the VM performance run of 9 Oct (`tests/vm/perf/vmperf.py`, 8192 MiB, TCG): boot steps, memory, PSS per process, idle wake-ups and running services at the Welcome screen and after login |

The tools the research used or produced are in the tree:

| Path | What |
|---|---|
| `tests/vm/perf/` | `vmperf.py` (the VM baseline) and `readbench.py` (the squashfs read benchmark) |
| `tests/vm/report/` | the generator of the "Antumbra QEMU Test Run" page |
| `tools/simulator/` | the Antumbra Simulator, an HTML mock of the interface |
| `tools/termux-preview/experiment/` | the nested-Phosh experiment: its scripts, the launcher without gnome-session, the record of the runs |

`research.md` is a cleaned copy of the research digest: the build host's
paths are replaced by repository paths, and nothing in it is about anyone's
own devices or circumstances. The full record (each claim with its sources
and a confidence) was not copied.

## Corrections made later

Reviewing the plan against the repository and the runs changed these
points. Where they disagree with `research.md`, these win.

1. **phoc does not log** which configuration file it read, nor the scale:
   the session logs show only "Output X11-1 added". Check the phone's mode
   and scale with `wlr-randr` and `dmesg | grep 'initializing panel at'`;
   whether `journalctl -t phoc` shows them is unverified. The VM can check
   that phoc's command line holds `-C /etc/phosh/phoc.ini` and that the
   session log has no "Failed to initialize Xwayland".
2. **"10 to 30 times slower than the phone"** is an estimate: no timing
   from the phone exists.
3. **The 9 Oct baseline** used a different setup (8192 MiB, an image with
   Android apps) from `build/vm.sh`'s default 4096 MiB. Later runs are
   compared with the daily VM run's first result; 9 Oct is context only.
4. **The daily VM run starts from pushes** to the Antumbra branch (the
   existing workflows already run on branch pushes), not from a schedule
   on `main`: nothing changes on `main`, no time zone goes into a public
   file, and GitHub's 60-day pause of idle schedules does not apply.
5. **Artifact storage is not limiting:** about 3.7 GB of unexpired
   artifacts were stored without error on 9 Oct.
6. **The existing CI jobs have no time limit;** one hung for 6 hours on
   8 Oct (run 37789103300).
7. **The images cannot be told apart:** `95-base-release.sh` records no
   commit.
8. **A phone-size VM run** at 960x2080, scale 2 (the phone's 480x1040
   logical size with fewer pixels than 1440x3120) needs a test-only scale
   setting and scaled tap coordinates.
9. **The AppArmor cache** must be compiled for the AppArmor features of
   Antumbra's own kernel (captured from the VM, which uses the same kernel
   sources), not the build host's; a cache for another kernel is ignored
   and rebuilt at boot.
10. **The patched-Phosh package** cannot simply copy `build/libcamera.sh`'s
    route: that build is local-only (the release workflow leaves
    `ANTUMBRA_LIBCAMERA_LOCAL` empty), and the pattern has never run on
    GitHub.
11. **The kernel has tracing (FTRACE) off,** so powertop shows only
    counters; `DEBUG_FS` is on.
12. **GTK 4.18** has no `prefers-color-scheme` for custom colours, so
    Android-dark app surfaces mean dark only.
13. **Android 12's phantom-process limit** is 32 child processes in total
    across all apps. The fix depends on the API level: 30 (Android 11)
    needs none; 31 (Android 12) needs the `device_config` command over
    wireless debugging; 32 (12L) has a feature-flag setting instead.
14. **phosh-osk-stub's learned words** are likely kept in memory only and
    forgotten at shutdown unless Persistent Storage keeps the home
    folder's settings; this is to be checked in the VM, not assumed.
15. **"Restart into Android" is one-way** (`docs/flashing.md`): Android
    then formats the shared data area or asks for a factory reset, which
    erases Antumbra and its Persistent Storage.
16. **`flash.sh` trusts `--android-slot`** on a first run
    (`build/flash.sh`, lines 158-165): a first install uses
    `--first-install`, and Android's slot is read again just before
    writing, after any OxygenOS update has finished merging.
17. **The OnePlus US Community's closure** in August 2026 is unverified;
    only the package links' availability matters.
18. **A minimal image exists:** `ANTUMBRA_MINIMAL=1` (`docs/building.md`)
    builds one without Phosh or apps, useful to tell a start-up failure
    from a session failure on a first boot.
