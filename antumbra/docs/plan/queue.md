# Work queue

The plan's tasks for Mon 12 Oct 2026 to mid-February 2027, one row each,
in the order they are due. The daily routine reads this file to choose the
day's change and writes the status back; sessions that settle a decision
record it under "Gates and decisions". It holds tasks and decisions only:
nothing about anyone's devices, notes, photos or times, which stay on the
private Daily page. The research behind it is in `research-2026-10/`.

## Format and rules

- **One row per item:** ID, what, size, status, and "Done when", one line
  of acceptance. IDs: **T** tests and tooling, **P** performance, **A**
  Android-likeness, **R** readiness for the install, **alpha.N** releases.
  A letter or number after an ID (A8a, T7b, T12.2) marks one part of an
  item.
- **Size:** S, one session; M, 2 to 4 sessions, built over several
  mornings with each step committed switched off until the item is done;
  L, out of scope for this window.
- **Status:** `todo`, `doing`, `done` (with the commit's short hash once
  it is pushed), `blocked: <reason>`.
- **One item per change.** Each change is its own commit on
  `claude/tails-mobile-privacy-os-c71ate`, names its item ID, passes lint
  and the unit tests (waited for at most 30 minutes) and gets its own VM
  run. A newer push cancels a run still going; commits that touch only
  documents start none.
- **Undo** on the Daily page reverts that change's commit the next
  morning, before anything else, and puts the item back to `todo` (or
  `blocked` with the reason). A change whose run fails, changes a screen
  unexpectedly by more than about 2%, or raises memory by more than 5% is
  reverted the same way before anything else.
- **Pause** (report but change nothing) and **Stop** (end at once, for
  holidays) are switches on the private Daily page, not here.
- **Behaviour items** (keyboard, gestures, Settings) are switched on in
  the VM and preview test builds; whether they ship in a release is a
  decision below, with a default.
- **Releases** are drafts, built by GitHub from a commit that bumps
  `VERSION`. A release Friday commits only the version bump, on top of
  Thursday's change that passed; Friday's fixes then wait until Monday.
- **Paths:** commits touch only `antumbra/**` and
  `.github/workflows/antumbra*.yml` (a push touching `web/`, `src/`,
  `data/` or `docs/store/` at the repository root redeploys another
  project's live site).
- **Never:** push to `main`, merge PR #8, publish a release, or do
  anything that touches the phone.
- **Release gate** (each release Friday): the daily runs of the last 3
  changes passed; the week's extended run passed, on the release commit
  itself; the phone-image content check (T10) passed; no "looks off" is
  open; no regression against the previous release in the same setup
  (memory +5%, image size +5%, an unexplained new package; times only
  above 20%); Tor Browser is the newest alpha or the gap is explained.

Weeks run Monday to Sunday; W1 starts Mon 12 Oct 2026. Fridays add the
extended run (Android, Persistent Storage, camera; from W3 a debug phone
image, from W4 its content check, from W5 the phone-size run, from W7 a
memory-pressure run).

## W1 · 12 to 18 Oct · Rescue the tools, fix the defect, start the loop

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| T0 | Rescue the tools that lived only in the planning session's scratch space: the Simulator (`tools/simulator/`), the report generator (`tests/vm/report/`), `vmperf.py` and `readbench.py` (`tests/vm/perf/`), the nested-Phosh experiment (`tools/termux-preview/experiment/`), the research and the 9 Oct baseline (`docs/plan/research-2026-10/`), this queue | S | done | All in the tree with relative paths and lint passing; the Simulator builds byte-identical to the published page and its tests pass |
| P1 | Session at 60 Hz, scale 3, no Xwayland attempt: ship Antumbra's phoc settings as `/etc/phosh/phoc.ini`; a lint test that fails if the session and the Welcome screen read different settings; a VM check; alpha.2's draft notes get "do not flash; install guide superseded" | S | doing | In the VM, phoc's command line holds `-C /etc/phosh/phoc.ini` and the session log has no "Failed to initialize Xwayland"; the lint test passes |
| T4a | The public setup README (`tools/termux-preview/README.md`): the official download links, the phone-facts command (never the serial number), the Termux:X11 check; later the background-process fix and the preview installer | S | doing | It opens without signing in, and its commands are copy-ready |
| T1 | Daily VM workflow `.github/workflows/antumbra-vm.yml` on GitHub's arm64 runners, on pushes to the branch that change `antumbra/**` (not documents only): kernel cache, 180-minute limit, a newer push cancels a running one; 20-minute limits on the existing lint and boot-image jobs; nothing on `main` | S/M | doing | The first run builds the unchanged alpha.2 version: baseline 0, the runner's emulation speed and how far Tor bootstraps are recorded |
| R1 | Install-guide order (R1 is this plus P1): unlock first, then install F.22 twice; the warning that OxygenOS 12 may refuse the unlock "for technical reason"; the PDF rebuilt, shipped with alpha.3 | S | doing | The guide and the rebuilt PDF give that order and the warning |
| T2 | The Daily page and the routines: GitHub prepares each day's page in the run's files (screens, before/after JPEGs, changes in the numbers); the morning routine publishes it to its fixed private address with buttons, notes, photo uploads and comments, then makes the day's change; it checks again 45 minutes later if the run has not finished; the Sunday review | M | todo | Two full routine runs, started by hand and left unattended, finish with no approval prompt, from start to a published page and a pushed commit, each reading a tap, a comment and an uploaded photo |
| A1 | Status-bar clock without the date (one shell setting): the first visible change through the whole loop | S | todo | The VM's top bar shows the time only; the page shows it before and after |

## W2 · 19 to 25 Oct · The preview kit, the daily tour

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| T11 | Build identity: a version such as `0.1.0-alpha.3-dev` plus the commit, in `/etc/antumbra-release`, in small text on the Welcome screen, in the performance snapshot and in the preview's Start message; `antumbra/CHANGELOG.md`, one plain line per change | S | todo | A built image names its version and commit in all four places; each change adds a CHANGELOG line |
| T4 | Termux preview kit: 960x2080 at scale 2, a second setting 822x1782 at scale 2 and a fallback 720x1560 at scale 1.5; the idle lock off; the launcher without gnome-session (`tools/termux-preview/experiment/`); `proot-distro login --isolated`; Start (updates first, shows the build), Stop and Welcome-demo shortcuts; an installer that can be run again, each step once, with a short log. Fixes in W3 as needed | M | todo | The Debian side runs in a cloud session; the Termux side starts on the phone (gate G3) |
| T3 | Daily mode of the VM run: 9 named screens (Welcome, lock screen, notifications, quick settings, app grid, Files, Mobile Settings, keyboard, power menu); "wait until the screen is still"; `metrics.json` (boot steps, memory and the top 15 processes, 60 s of idle wake-ups, launch time of 3 or 4 apps, Tor progress, sizes, package count); comparison with the last run with clock, battery and pointer masked; a 30 to 60 s time-lapse; one history row per run; the 6 key screens saved weekly in `tests/vm/history/` | M | todo | A run yields the 9 screens, `metrics.json`, the comparison and the time-lapse in under 30 MB |
| P2 | Daily metrics and baseline 0 (part of T1 and T3) | — | todo | Baseline 0 recorded; every run adds a row of numbers |

## W3 · 26 Oct to 1 Nov · Quick wins, the size, alpha.3

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A2 | App grid: no "Show All Apps" button, short app names, Console out of the dock | S | todo | None of the three in the VM's app grid |
| A3 | Material icons for menu (⋮), back (←) and search in header bars, and Material versions of every remaining status icon; a VM check of whether header bars show a close × | S | todo | VM screenshots of Files show them; the close × question answered |
| T5 | A virtual multitouch screen in the VM (`virtio-multitouch-pci`), so gestures and the keyboard are tested as touches | S | todo | The tour's swipes and key taps are touch events |
| R2 | Debug phone image: built weekly in the Friday run, kept as an Actions artifact for 14 to 30 days, attached to the draft on release Fridays; check whether it can be packaged so `flash.sh` accepts it (otherwise R8 gives by-hand steps) | S | todo | The Friday run uploads it with checksums; the `flash.sh` question answered |
| alpha.3 | Release, Fri 30 Oct: the screen-settings fix, quick wins, the first debug phone image, the corrected install-guide PDF | S | todo | The release gate passes |
| T6 | Optional experiment, one session, dropped if it fails: Antumbra's session directly on GitHub's arm64 runner with no VM, for screenshots minutes after a push | S | todo | Screenshots from a native run, or the experiment dropped |
| R9 | Branch B only: a `fastboot` wrapper for termux-fastboot, dry-run tested on GitHub | M | blocked: Branch B only (G2) | `flash.sh --dry-run` through the wrapper passes in CI |

## W4 · 2 to 8 Nov · Font, work repeated at every boot

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A4 | Android-style font: Roboto Flex (OFL, no Google brand name), bundled, with settings and a font rule | S | todo | VM screenshots in Roboto Flex; the Noto fallback still covers CJK |
| P3 | Pre-built AppArmor cache, compiled for the AppArmor features of Antumbra's own kernel (captured from the VM) | S | todo | The VM's boot list shows the cache used and AppArmor off the top of the list |
| P4 | Pre-built font cache (font directory times normalised before `fc-cache`) | S | todo | `time fc-list` as a fresh user is fast and writes no cache |
| P5 | zstd compression for the system squashfs | S/M | todo | Read speed, image size (+10 to 17%) and Android start time reported before and after |
| P6 | Find the unknown `sh` process that wakes 2 times a second | S | todo | The process named, and fixed or explained |
| T10 | Phone-image content check, on every Friday debug phone build and each release: `/etc/phosh/phoc.ini` matches Antumbra's settings (DSI-1, 60 Hz, scale 3); the AppArmor and font caches present and valid; zstd compression; debug tools in the debug image and absent from the release; `/etc/antumbra-release` names the commit | S | todo | The check runs in the Friday run and fails on any of these |
| T12.1 | Update pinned versions #1: Tor Browser alpha, Waydroid images, F-Droid | S | todo | New pins with their hashes; the Friday run passes |
| T7 | Simulator honesty: a Real / Modelled / Acted out badge on every screen; a phone-size mode and a squeekboard-like keyboard mode; republished at the same address; the "Antumbra QEMU Test Run" page gets a banner saying it is an early-October snapshot and pointing to the Daily page | S/M | todo | Every screen badged, both modes work, same address |

## W5 · 9 to 15 Nov · Dark apps, a quieter idle phone

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A5 | Android-dark surfaces in apps: windows, cards, menus, dialogs; the Dark-mode tile renamed or removed (needs the dark-only decision) | S | todo | Files, Text Editor and Calculator look Android-dark in the VM |
| P7 | Tor's "connected yet?" check reacts to an event instead of asking every second; the network rules load in one batch per network namespace | S/M | todo | Its 26 wake-ups a second gone at idle; `antumbra-create-netns` faster in the boot list |
| P8 | Turn off apt-daily, dpkg backups, e2scrub, fstrim and the unused device monitors (AFC, GOA, gphoto2, MTP); start udisks2 only when needed | S | todo | Fewer running services in the metrics; the Friday Persistent Storage run passes |
| T8 | Phone-size VM run at 960x2080, scale 2 (the phone's 480x1040 logical size), with a test-only scale setting and scaled tap positions; joins the Friday run from 13 Nov | M | todo | The Friday run includes phone-size screenshots of the 9 screens |

## W6 · 16 to 22 Nov · Colours, Settings review, January research

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A6 | "Material You lite": 4 to 6 ready-made palettes; a Colour row on the Welcome screen (one added setting, the flow unchanged); the palette applied at login with the nearest app accent; a preview shortcut to switch palettes; the Android part comes with A11 | M | todo | Each palette visible in the VM, and a VM check shows a palette loaded after the shell's CSS overrides its colours |
| A8a | Settings review: check in the VM that tile long-press and the Wi-Fi/Sound "Settings" buttons do nothing today; a privacy review of GNOME Settings' pages and dependencies | S | todo | Both answered in writing, so the Settings route can be decided |
| R4 | "Restart into Android": make Android's slot active (`qbootctl -s`). One-way: Android then formats the shared data area or asks for a factory reset | S | todo | The action exists and says it is one-way; tried on the phone only on the last day of phone week 2 |
| R5 | Research: the OxygenOS 11 rollback package and the F.22 full package for the HD1913, with checksums (Branch B: W3) | S | todo | Download sources and SHA-256 sums recorded |

## W7 · 23 to 29 Nov · Keyboard with suggestions, alpha.4

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A7 | phosh-osk-stub: a word-suggestion strip, emoji, PIN and number layouts, swipe down to close; Gboard-like Material keys (about +36 MB); learned words never saved by default; the Welcome screen keeps squeekboard unless VM taps prove osk-stub works there | M | todo | The VM types by touch in the session and on the Welcome screen; no learned words on disk after a reboot with Persistent Storage on |
| P9a | Memory test, report only: transparent huge pages "always" against "madvise" in the Friday memory-pressure run (Tor Browser plus Android) | S | todo | PSS, PSI, zram and `MemAvailable` reported for both |
| alpha.4 | Release, Fri 27 Nov: font, icons, dark apps, palettes, boot and idle fixes; the new keyboard as the default if kept, otherwise an opt-in switch | S | todo | The release gate passes |

## W8 · 30 Nov to 6 Dec · A real Settings app

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A8b | Build the chosen Settings route; tile long-press and the "Settings" buttons start working | M | todo | A VM network capture shows no new connections, and the AppArmor review passes |
| P9b | Swap behaviour (swappiness, page-cluster), measured before and after | S | todo | Reported; a setting changes only with a measured gain |
| P10 | Measure the cost of `slub_debug`; add `hash_pointers=always` to keep pointer hashing on (removing `slub_debug` is decided on the phone) | S | todo | Cost reported; the command line still fits |
| R3 | Install-guide additions: the OxygenOS 11 detour if the unlock is refused; the second-Android route; the warning that generic web flashers write Android's slot; restoring Android before a borrowed computer goes back; the first-boot photo checklist (Branch B: the detour part in W3) | S | todo | All five in the guide |
| T12.2 | Update pinned versions #2 | S | todo | New pins with their hashes; the Friday run passes |

## W9 · 7 to 13 Dec · Android status bar, fewer background helpers

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| T9 | Patched-Phosh package: Debian's phosh 0.46 plus Antumbra's small patches, built in a new GitHub job (mmdebstrap plus dpkg-buildpackage, as `build/libcamera.sh` does locally; its first run on GitHub is part of the size); warns when Debian publishes a newer phosh | M | todo | The job builds the package and the image installs it |
| A9 | Clock on the left, icons on the right: a one-file patch carried by T9; time-boxed to one session if it needs the phone's panel description | S on T9 | todo | The VM's top bar shows the layout, or the item goes to the backlog |
| P12 | Turn off unneeded GNOME helper plugins (Wacom, Smartcard, printing, sharing, mobile data, colour), never one the Phosh session lists as required | M | todo | The session starts 5 times out of 5 in the VM; memory down |

## W10 · 14 to 20 Dec · Themed icons, measuring kit, alpha.5

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A10 | Themed app icons: Android-13-style one-colour symbols on tonal circles for about 15 apps and the Android folder; two styles shown first; Tor Browser keeps its own logo if its trademark rules require | M | todo | The VM's app grid in the chosen style |
| P11 | Phone measuring kit, debug builds only: linux-perf, mesa-utils, vulkan-tools, smem, qrencode, wlr-randr, powertop (counters only while FTRACE is off; decide whether the debug kernel turns tracing on); the live user may read the system log; `antumbra-perf-snapshot` shows the day's numbers on one screen and as QR codes | S/M | todo | The snapshot and its QR codes render in the VM |
| A9b | Optional: the lock screen opens the keyboard directly (a passphrase, not a PIN), only if the VM confirms the extra PIN-pad tap | S | todo | One tap fewer to type the passphrase in the VM |
| alpha.5 | Release, Fri 18 Dec: Settings app, Android status bar, themed icons, measuring kit | S | todo | The release gate passes |

## W11 · 21 to 27 Dec · Holiday (routine Mon and Wed only; nothing visible changes)

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| A12 | Edge-swipe Back helper, off by default: thin invisible strips at the left and right edges; an inward swipe sends Alt+Left to Tor Browser and GNOME apps, Escape to Android apps | M | todo | A VM test with simulated touch passes, and the key-sending does not disturb the on-screen keyboard |
| R6 | Wrong clock: start the VM with its clock in 2020, record what Tor does, make sure there is a manual way to set the time | S/M | todo | Tor's behaviour recorded; the manual time setting works in the VM |

## W12 · 28 Dec to 3 Jan · Holiday (routine Mon and Wed only)

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| P13 | An image variant with Mesa 26.1.6 from trixie-backports, built and parked for a phone test | S | todo | The variant builds and boots in the VM |
| P14 | Optional: sleep-depth statistics in debug builds (`qcom,rpmh-stats`; its address taken from sister chips, unverified) | S | todo | Readable in a debug build on the phone |
| T7b | Each run compares the Simulator's screens with the VM screenshots; a "differs from the real OS since…" banner where they disagree | S/M | todo | The comparison runs and the banner shows on a changed screen |

## W13 · 4 to 10 Jan · After the holidays, Android apps, freeze on Sun 10 Jan

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| T12.3 | Update pinned versions #3 (more in W15 if needed) | S | todo | New pins with their hashes; the Friday run passes |
| A11 | Android apps polish, 2 or 3 steps: Android notifications in Phosh's drawer; Android windows opening full size; the palette colour sent into Android's theme settings (the effect in Waydroid unverified) | S×2-3 | todo | Each step checked in the Friday Android run |

## W14 · 11 to 17 Jan · Install candidate

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| R7 | Full regression run on the candidate: tour, Android, Persistent Storage, camera, phone-size layout, wrong clock, phone-image content check | S/M | todo | All pass on the candidate commit |
| R8 | Install sheet for the install host named at gate G5, a first-boot checklist page and the install-guide update: by-hand steps for the debug image (any system), `flash.sh` for release images (Linux only), and near-native VM steps on an Apple-silicon Mac or arm64 Linux before flashing | S | todo | The sheet matches that host's system and carries alpha.6's checksums |
| R11 | A minimal debug image (no Phosh, no apps; `ANTUMBRA_MINIMAL=1`), built and parked for gate G9 | S | todo | It builds and reaches a console in the VM |
| alpha.6 | Install candidate, Fri 15 Jan: release and debug images from one commit with checksums, plus the parked Mesa variant. Frozen: fixes only after it; security rebuilds become alpha.6.1, alpha.6.2 | S | todo | The release gate, R7 and T10 pass |

W15 (18 to 24 Jan) holds fixes only; W16 (25 to 31 Jan) is the install
or a buffer week (G8).

## Phone weeks (default 1 to 14 Feb)

| ID | What | Size | Status | Done when |
|---|---|---|---|---|
| R10 | Partition backup on the first day (Administration on): a read-only script copies persist, modemst1, modemst2 and fsg, which hold the IMEI and calibration data, to encrypted removable storage and to the install host, with checksums | S | todo | Both copies made and their checksums verified |
| alpha.7 | The first fixes learned on the phone (default Fri 12 Feb), then a new plan | S | todo | The release gate passes |

Phone week 1 checks and measures without changing anything; phone week 2
changes one thing a day against that baseline: GTK's renderer (Vulkan or
GL), Mesa 25 against the parked Mesa 26, automatic sleep and WoWLAN, the
modem check every 5 or 30 minutes, touch checks (the keyboard, the Back
helper, legibility, Tor Browser at 480 px, the status bar at the corners,
Android windows), 90 Hz only as an opt-in test, Tor Browser's GPU use and
the 2.96 GHz CPU step, and R4 tried once on the last day.

## Other planned work without an ID

- W5: performance scorecard #1 (baseline 0 against W5).
- W12: a performance report, alpha.2 against alpha.5; a "Welcome as pages"
  design as a Simulator mock-up only (built after the first boot).
- W13, Monday: a short page on what changed over the holidays; the
  "looks off" backlog.
- Every Sunday: the weekly review with next week's menu.
- After the phone: Welcome as pages; Tor Browser's mobile toolbar (after a
  fingerprinting review); colour from the wallpaper; custom tiles ("New Tor
  circuit", "Android on/off"); animation speed.

**Lean mode** (if gate G4 says so): the routine runs Mon, Wed and Fri.
Always kept: P1, T0 to T3, T10, T11, R2 to R8, R10, P11. Dropped first, in
this order: A12, P12, T7b, A9b, P14, then A10.

**Not in this window:** Plasma Mobile or a newer Phosh; L-size Phosh work
(Back in the window manager, a home screen with widgets, separate recents
and app drawer, a two-stage shade, reordering built-in tiles, swipe
typing); changes to the Welcome flow (beyond A6's Colour row), the
start-up chain, the storage layout or the in-phone updater before the
first boot; tuning smoothness, animations, 90 Hz, graphics settings or
kernel hardening without phone data; the repository's GitHub Pages, a
WebUSB flasher; Google services; restyling Tor Browser without a
fingerprinting review.

## Gates and decisions

No answer within 48 hours means the default. A settled decision is
recorded here as `decided: <choice>` with the date.

| Gate or decision | When | Question | Default | Status |
|---|---|---|---|---|
| Autonomy | Mon 12 Oct | One ticked S item ships per weekday; behaviour items on in test builds only, releases decided separately | on | open |
| Preview | Mon 12 Oct | Build the Termux preview (not private; erased by the unlock) | on | open |
| G0 | Wed 14 Oct | Phone facts collected (kept on the private page)? | — | open |
| G1 | Sun 25 Oct | Is a warm daily run 90 minutes or less, and reliable? If not: a shorter weekday tour (90 to 180 min) or the full run on Fridays only | — | open |
| G2 | Sun 25 Oct | Branch A (the install waits for the install host) or Branch B (an early install with a second Android device as the fastboot host)? | A | open |
| G4 | Sun 25 Oct | Standard or Lean mode? Is the daily run reliable (2 or fewer failures in 5)? | Standard | open |
| G3 | Sun 1 Nov | Does the preview start, take taps and swipes, and last 15 minutes? Green, amber (taps, no swipes) or red | — | open |
| Size | Sun 1 Nov | 480 logical, about 411, or 480 with text 15% larger | 480 with larger text | open |
| Font | W3 to W4 | Roboto (now), Roboto Flex or Google Sans Flex | Roboto Flex | open |
| Dark only | Sun 8 Nov | Commit to dark only (needed for A5) | yes | open |
| Palettes | W6 | Which palettes ship, and the default | — | open |
| Settings route | W6 | GNOME Settings without Online Accounts, Sharing and Users, or a small Antumbra Settings app | GNOME Settings, pruned, if the review finds nothing blocking | open |
| Keyboard | Sun 29 Nov (phone week 2 if G3 is red) | Keep phosh-osk-stub, or go back to squeekboard | — | open |
| Learned words | W7 | Never saved, even with Persistent Storage on | yes | open |
| Preview packages | W9 | Publish the patched-Phosh package as a public "preview packages" pre-release | yes | open |
| Icon style, clock left | W10 | Which icon style; keep the clock on the left | — | open |
| G5 | Wed 13 Jan | Install host chosen (model and system)? | — | open |
| G6 | Install day 1 | Does `fastboot oem unlock` work? If not: the OxygenOS 11 detour | — | open |
| G7 | Install day 3 | Does it reach the Welcome screen? If not: photos, fix, reflash, at most 3 tries a day | — | open |
| G8 | Sun 31 Jan, Sun 14 Feb | No install host yet? Then the candidate stays frozen with security rebuilds, the routine runs on Sundays only | — | open |
| G9 | After 2 failing days | It never boots: the full debug image, then the minimal image (R11), then a test image from the port, then an issue to the port; at most 3 weekends or until Sun 28 Feb | — | open |
| Back helper | Phone week 2 | On by default? | — | open |
| Simulator | Phone week 2 | Keep it for design proposals, or retire it | — | open |
