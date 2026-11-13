# Research behind the October 2026 plan

Six research strands and one experiment, all run on 9 Oct 2026, for the
16-week plan whose tasks are in `docs/plan/queue.md`. The question behind
them: how can Antumbra be made more Android-like and faster, and be tested
every day, before it can be installed on a OnePlus 7T Pro?

The images examined are the qemu-virt debug image of 6 Oct 2026
(0.1.0-alpha.1, built with Android apps) and the 0.1.0-alpha.2 phone
release of 8 Oct. Paths are relative to `antumbra/` unless they start with
`image:` (the built root filesystem) or are URLs; line numbers refer to
the tree of 9 Oct 2026. Each strand ends with what it implies and what it
left open. Labels as the strands used them: *verified* (seen in the files,
a VM or experiment run, or GitHub's own records), *inferred*,
*unverified*. Corrections the plan made later are in `README.md`.

Contents:

1. [The interface today](#1-the-interface-today)
2. [Testing without the phone](#2-testing-without-the-phone)
3. [A Termux preview on the phone](#3-a-termux-preview-on-the-phone)
4. [Unlocking and flashing without a computer](#4-unlocking-and-flashing-without-a-computer)
5. [Closer to Android](#5-closer-to-android)
6. [Performance](#6-performance)
7. [The nested-Phosh experiment](#7-the-nested-phosh-experiment)

---

## 1. The interface today

Antumbra's "Android-14-class" interface is a reskin: it changes colours and
shapes, and the way you navigate is still Phosh's. Phosh 0.46 is restyled
through GTK 3 CSS (a Material 3 tonal-spot palette from the seed `#4d2c9e`,
28 px quick-setting tiles filled when on, thick sliders, 24 px cards, a
108x4 gesture pill, a scrim behind the app drawer, the lock clock, dialogs,
squeekboard's keys), through vendor GSettings (prefer-dark, a purple
accent, Roboto 11, battery percentage, a Material Symbols status-icon
theme, wallpapers) and through libadwaita's accent variable. phosh, phoc
and squeekboard carry no patches, and that limit is documented.

The theme ships in phosh 0.46.0-3+deb13u1, phoc 0.46.0-1, squeekboard
1.43.1-1, libadwaita 1.7.6, GTK 4.18.6 and 3.24.49, Mesa 25.0.7 and
Waydroid 1.6.3 (alpha.2's MANIFEST). There is no phosh-osk-stevia,
gnome-control-center or phosh-mobile-tweaks.

What still reads as "Linux on a phone" is mostly structural and needs code:

- no system Back gesture;
- no home screen (bare wallpaper);
- one overview that merges recent apps, favourites and the full app grid,
  with a Linux-specific "Show All Apps" button;
- a single-stage drawer that pushes notifications to the bottom half;
- a fixed set of nine tiles, some of them dead in Antumbra (Cellular,
  Bluetooth, a battery tile, a manual "Portrait" rotation tile);
- a centred clock with the date;
- no Settings app: long-press on a tile and the Wi-Fi, Sound and Bluetooth
  "Settings" buttons call `org.gnome.Settings`, which is not installed;
- squeekboard, with no word suggestions;
- desktop-style GNOME header bars with a hamburger menu;
- a desktop Tor Browser;
- a long one-page Welcome form.

Android apps run in Waydroid with two status bars and two navigation
systems, small freeform windows and LineageOS's own teal accent. All of
this is seen in the VM screenshots.

Several gaps can be fixed with configuration alone: hiding the date,
disabling the adaptive app filter, shorter app names, icon-theme overrides
for the menu and back icons, a phosh-osk-stub keyboard (in trixie), and a
Tor Browser `userChrome.css` (the preference is already on).

**One verified configuration bug matters for performance and stability:**
the user's Phosh session never reads `/etc/antumbra/phoc.ini`. Debian's
`phosh-session` looks only at `/etc/phosh/phoc.ini`. So on the phone the
session will take the panel's preferred mode, which the port's driver sets
to 90 Hz, the mode Antumbra says has DSI transport errors. Only the greeter
is pinned to 60 Hz. The VM cannot show this, because Debian's default
`phoc.ini` happens to configure the VM's `Virtual-1` output the same way.

The Simulator (`tools/simulator/`) is careful: it does not invent Android
behaviour that Phosh lacks. It does look more polished than the real
system: it uses the browser's keyboard, not squeekboard; it lays out 390
logical px wide where the phone is 480; GNOME apps are title-only
placeholders; Tor Browser is an HTML mock that fits the screen; timings
are shortened and animations are composited on the browser's GPU; Tor
progress, Wi-Fi, battery and brightness are acted out.

### What it implies

- **Before the first flash,** ship the phone's phoc settings where
  `phosh-session` reads them (`/etc/phosh/phoc.ini`, or a link to
  `/etc/antumbra/phoc.ini`), and add a test so this cannot regress.
  Otherwise the session will probably run the 90 Hz preferred mode.
  Confirm it on the phone at first boot with `wlr-randr`.
- **Quick configuration wins with very low risk,** each buildable by CI:
  `clock-show-date=false` (optionally `clock-format`); `sm.puri.phosh
  app-filter-mode=[]` to drop "Show All Apps"; short-name `.desktop`
  overrides (Electrum, Metadata, Tweaks or Mobile Settings); reconsider
  Console in the dock; extend the Antumbra icon theme with Material
  `more_vert`, `arrow_back` and `search` for `open-menu`, `go-previous` and
  `edit-find`, and with Material versions of the Adwaita status icons Phosh
  still uses.
- **Medium items:** switch the on-screen keyboard to phosh-osk-stub
  (trixie main) through the Phosh-OSK alternative, restyle it, and change
  the greeter's; ship a mobile `userChrome.css` for Tor Browser after a
  fingerprinting review; fix the size of Waydroid's app windows and hide
  Android's duplicated status and navigation bars or match its accent
  (needs an investigation first); split the Welcome screen into pages;
  decide between gnome-control-center (with a privacy review of its
  dependencies) and a small Antumbra Settings app, because Phosh's
  long-press and "Settings" buttons are dead ends now.
- **Out of scope for now,** or stretch upstream patches: a system Back
  gesture (a phoc or phosh edge swipe that sends `KEY_BACK`), a real home
  screen and a split of recents and drawer, a two-stage shade, hiding or
  reordering built-in tiles, moving the clock left (gmobile panel data and
  a rebuild), lock-screen shortcuts.
- **An on-device CSS loop** for daily visual tweaks once Antumbra runs:
  edit `~/.config/gtk-3.0/gtk.css` or `gtk-4.0/gtk.css` in Text Editor, log
  out, then "Start a new session"; keep them with the Dotfiles feature;
  port proven changes back into `shell.css` and `apps.css`.
- **Daily checklist items** from this inventory: refresh rate and jank in
  the drawer and overview, legibility at scale 3 next to stock OxygenOS,
  whether the lock screen's keypad-first flow gets in the way of a
  passphrase, squeekboard's usability, Tor Browser's fit at 480 px,
  Android window sizing at density 480, Night Light and brightness, the
  battery reading, haptics.
- **Make the Simulator more honest** where it flatters the system: a
  480-logical-px width option, a squeekboard-like keyboard mode, real
  header bars for one or two GNOME apps, Tor Browser's desktop toolbar
  width, and a note that the session's refresh rate depends on the
  `phoc.ini` fix.

### Open questions

- On hardware: does the user session really come up at 90 Hz from the
  panel's preferred mode, and does it show the DSI transport errors? phoc
  falls back only when a test commit is rejected, not on errors at run
  time.
- Why did Waydroid's F-Droid window open small and freeform in the VM, and
  will phoc maximise Android windows on the phone at density 480? Can
  Android's own status and navigation bars be hidden in full-UI mode?
- Does a host `KEY_BACK`/`XF86Back` reach Android apps through Waydroid as
  `KEYCODE_BACK`? This decides whether one host Back gesture could cover
  GTK, Firefox and Android apps.
- Is phosh-osk-stub 0.46 (presage and hunspell) acceptable for an amnesic,
  privacy-focused system (is no learning persisted?), and does it work
  under the greeter's bare phoc?
- Is gnome-control-center acceptable for a Tails-like threat model, given
  gnome-online-accounts, accountsservice and colord? Or should Antumbra
  write a minimal Settings app that also answers `org.gnome.Settings`'
  `launch-panel` action?
- What logical scale should the phone use for an Android-like size? Stock
  OxygenOS's density on the 7T Pro (believed 560 dpi, about 411 dp wide)
  was not verified. Phosh's scaling quick-setting plugin is installed, but
  fractional scales cost rendering work.
- Does a mobile `userChrome.css` or a narrow window change Tor Browser's
  fingerprint or letterboxing, and how wide is Tor Browser 16's minimum
  toolbar?
- Does Debian's phosh link gmobile statically? This sets the effort for a
  panel description of the phone, which affects rounded-corner clearance
  and could move the clock.
- Does a window close button (x) appear in libadwaita header bars under
  Phosh on the phone? It was not visible in the Snapshot screenshot.

---

## 2. Testing without the phone

Without the phone, the only test that runs the real image is the QEMU
arm64 `virt` harness (`tests/vm/antumbra_vm.py`). It boots the debug
qemu-virt image and can tap, swipe and type through QMP, take screenshots,
run commands as root, launch apps as the user, check pixels, capture
network traffic, boot Waydroid and F-Droid, use the vimc test camera, and
create and unlock Persistent Storage.

On the cloud build host (x86-64, 4 vCPUs, no `/dev/kvm`, so full software
emulation) the guest reaches multi-user at about 213 s and the Phosh
session at about 370 s. A basic run takes 13 to 15 minutes, the tour plus
the camera about 41, Android about 59, and the image build about 70 (53 of
them for the root filesystem).

On GitHub's free `ubuntu-24.04-arm` runner the build is much faster (root
filesystem 2.5 min, squashfs 9 min; the kernel takes 30.5 min cold and can
be cached). That runner has no KVM: a maintainer closed the request as a
host limitation (Aug 2026) and a Sep 2026 probe found no `/dev/kvm`. So a
VM test there also runs under full emulation, probably at about the speed
seen on the build host (unverified). CI had no VM test job.

Already measured by the harness: per-check timestamps, screenshots, packet
capture, and a serial log with guest timestamps for boot milestones. Not
yet measured: memory after login, idle CPU and wake-ups, app launch times,
the Welcome screen's first frame and `systemd-analyze`, although each is
easy to add. Package count and image size come from the build files. Tor
only reaches 14% on the build host (no route to Tor); it may connect fully
on a GitHub runner (unverified). Absolute speed, the GPU, touch, the panel
layout at 480x1040 logical px, battery, suspend, the radios and the
cameras all need the phone.

The recommended daily loop:

1. a GitHub Actions workflow builds the image natively (kernel cached) and
   runs a "daily tour": screenshots, a time-lapse, metrics and a
   comparison with the day before, uploaded as a small artifact (the
   research proposed a schedule on `main`; the plan starts the run from
   pushes to the Antumbra branch instead);
2. a morning Claude Code routine (a fresh session with a push
   notification) turns that artifact into one private, phone-friendly page
   at a fixed address;
3. the page records one-tap "looks right / looks off" notes per screen and
   comments, which the next routine reads; replying in the routine's
   session works too;
4. the Simulator is kept honest by comparing each screen with the matching
   VM screenshot, reading theme tokens from the repository's CSS, and
   labelling each screen as real, modelled or acted out.

Do not use the repository's GitHub Pages: another project's live site is
deployed from it.

### What it implies

- **(a) The VM run on GitHub Actions, not in a Claude routine.** One small
  workflow; job on `ubuntu-24.04-arm` with a 180-minute limit; restore a
  kernel cache keyed on `device/*/kernel/*`, the port's patches and
  `sources.lock` (30 min cold, about 0 warm); build
  `ANTUMBRA_DEVICE=qemu-virt ANTUMBRA_DEBUG=1`, without Android on
  weekdays (root filesystem about 2.5 min, squashfs about 5 to 9 min);
  `apt install qemu-system-arm qemu-utils ipxe-qemu ffmpeg`; run a "daily"
  harness mode. Estimated 45 to 60 min warm (unverified until the first
  run). Weekly: `--android` (about 60 min), the `--persistence` pair (about
  28 min) and `--camera`. Upload only a small artifact (under 30 MB, kept
  14 days), never the 4.3 GB disk.
- **Harness work for the daily mode** (no phone needed):
  1. a longer tour with stable names: Welcome, lock screen, notification
     drawer, quick settings, app grid, an app window (Files, Settings),
     squeekboard open, power menu, the Android folder; "wait until the
     screen stops changing" instead of fixed sleeps;
  2. `virtio-multitouch-pci` and `mtt` events, so gestures and the
     keyboard behave as on a touchscreen;
  3. a metrics phase writing `metrics.json`: boot milestones with guest
     timestamps from `serial.log`, `systemd-analyze`, the first Welcome
     frame and the first session frame (screen polling), `MemAvailable` and
     the top 15 processes by PSS after login, 60 s of idle CPU and
     per-process context switches, launch-to-first-window for 3 or 4 apps,
     Tor's bootstrap percentage and time, the squashfs, initrd and disk
     sizes, the package count and a package diff;
  4. frames every 1 to 2 s, encoded to a 30 to 60 s MP4;
  5. a comparison with the previous run (the previous artifact through the
     API, or a cache keyed by date): a changed fraction per screen with
     masks for the pointer square, the clock and the battery, side-by-side
     PNGs for screens that changed by more than about 2%, and metric
     deltas, flagging time changes only above about 20% because of
     emulation noise.
- **(b) Getting the results to a phone:** a Claude Code routine
  (`create_trigger` with `create_new_session_on_fire=true`, push
  notifications on) an hour or two after the run. It reads the latest run
  through the GitHub tools (list the runs, then download the artifact),
  rebuilds one private page at a fixed address (publishing with that
  address, after reading it), and posts a 5-line summary in its session.
  If the run has not finished, it checks again later with `send_later`.
  The page holds the pass count, the time-lapse, today-against-yesterday
  screenshots, a metrics table with deltas and links to the Actions run;
  under 16 MB, or the video in the page's assets. A GitHub issue or the
  Actions job summary is only a fallback.
- **(c) Keeping the Simulator honest:** first move it and the report
  generator into the repository (done: `tools/simulator/`,
  `tests/vm/report/`), so CI and fresh sessions can rebuild them. Then:
  `build.py` reads palette tokens from
  `config/rootfs/usr/share/antumbra/theme/{apps,shell,welcome}.css` and
  fails if one is missing; a manifest maps each Simulator screen to its VM
  screenshot; Playwright renders those screens at 360x720 CSS px x2
  (720x1440) and compares them with the VM's PNGs, with the harness's
  changed fraction and the same masks. A screen above the threshold gets a
  banner "differs from the real OS since <date or commit>" and a "show the
  real VM screenshot" toggle. Each screen carries a badge: Real (a VM
  screenshot), Modelled from source, or Acted out. The Simulator should
  also say that the VM and the phone differ (360 against 480 logical px,
  so 4 against 5 grid columns), and a phone-size VM run should follow once
  the harness's hard-coded coordinates are scaled.
- **(d) Feedback with the least effort:** on the daily page, two buttons
  per changed screenshot ("Looks right", "Looks off") and an optional
  one-line note, stored in the page's database (`feedback/<date>/<screen>`),
  plus comments on the page; the next routine reads both before proposing
  the day's change. At most one decision question a day, with 2 or 3
  options. A reply in that day's routine session, or a marked-up
  screenshot, works too.
- **The daily change loop:** a choice on the page (or a reply) becomes one
  small, testable change a day: theme CSS, Phosh or phoc settings, a
  removed package or service, a change in unit ordering. Claude makes it on
  the branch, lint and unit tests run on the push, the VM run picks it up,
  and the next page shows the before and after with the metric deltas.
  Prefer memory, wake-ups, package count and image size as performance
  targets, because emulation does not distort them; treat VM timings as
  trends only.
- **Visual experiments during the day:** boot the CI-built VM image in a
  session, edit `/usr/share/antumbra/theme/*.css` in the running VM's RAM
  overlay over the debug console, restart the greeter or the session and
  take a screenshot, without a 70-minute rebuild. Whether the session must
  restart to pick up the CSS is untested.
- **An experiment worth one slot:** run the arm64 root filesystem directly
  in a container on the arm runner, with phoc's headless backend
  (`WLR_BACKENDS=headless`) and screencopy. If it works, it gives
  screenshots in seconds and launch times at native arm64 speed. Untested;
  Phosh's dependence on system services may limit it.
- **Scheduled workflows** in public repositories are disabled after 60
  days without activity, and notifications about failed scheduled runs go
  to whoever last edited the schedule. (Moot while runs start from pushes.)
- **Near-native speed** comes only with KVM or Apple's Hypervisor
  framework: the existing `make vm-bundle` bundle on an Apple-silicon Mac
  or an arm64 Linux machine with KVM (`docs/vm-testing.md`, lines 94-102).
  Those are the first VM timings that mean anything for speed.

### Open questions

- How fast is full emulation on the `ubuntu-24.04-arm` runner compared
  with the build host, and does Tor finish bootstrapping from a GitHub
  runner? The first run answers both.
- Can a fresh-session routine read the previous day's page, its database
  rows and its comments? That needs the page's address in the routine's
  prompt and the session's access to the page's data and comments.
  Untested.

---

## 3. A Termux preview on the phone

Yes, with limits. A "Termux preview" of Antumbra's userspace can run on the
OnePlus 7T Pro while it stays on OxygenOS 12, with no root and no computer.
It works as a look-and-feel and touch preview, not as a test of the OS.

Others have run Phosh inside a Termux proot container shown through
Termux:X11: Ivon Huang's guide (Nov 2024, Android 14), the Phosh-tmux
installer, and the Phoshdroid APK (Android 12 and later). Debian trixie
fits this well. Its phoc 0.46 is built on wlroots 0.18.2, and wlroots 0.18
no longer aborts when Termux:X11 advertises DRI3 but cannot hand over a DRM
device (0.17 did abort, the crash Phosh-tmux describes). So virgl is not
needed just to start phoc.

On the phone, phoc will almost certainly composite in software: wlroots'
GLES2 and Vulkan renderers need a DRM node, Android exposes the Adreno GPU
only as `/dev/kgsl-3d0`, so wlroots falls back to pixman. Debian's own Mesa
is built without KGSL, and Termux's KGSL-enabled Mesa is a Termux-native
build that glibc programs inside proot cannot load (inferred). GPU help is
therefore limited to GL clients through virgl (Termux's
`virglrenderer-android` plus `GALLIUM_DRIVER=virpipe`; Debian's Mesa
includes virgl) or a third-party KGSL Mesa. Run Termux:X11 at a scaled
resolution (for example 960x2080 at phoc scale 2, the same 480x1040
logical size as the real 1440x3120 panel at scale 3) and force
`GSK_RENDERER=cairo`.

These parts work or very likely work: the real phosh, the Antumbra CSS,
icons, wallpapers, gschema and dconf defaults, squeekboard (started by
hand), GTK apps, `antumbra-welcome --demo`, D-Bus through
`dbus-run-session`, and audio through Termux's PulseAudio over TCP.

These do not work: Tor-only networking and nftables, NetworkManager and
ModemManager, systemd units, greetd, logind, the network-namespace Tor
Browser launcher (sudo plus netns), Waydroid, the camera and the pop-up
motor, sensors, battery and suspend, amnesia and Persistent Storage, and
real performance or GPU behaviour.

The preview is not private either: traffic goes out over Android's network,
and proot-distro rewrites `resolv.conf` to Google's DNS.

The main risk is Android 12's phantom-process killer. OxygenOS 12 is very
likely Android 12 (API 31), not 12L, so there is no Developer-options
toggle. The only fix without root is one adb command, run from Termux
itself after pairing with Wireless debugging. That change must be undone
before any OS update. Other risks: OnePlus battery management, gesture
bugs in upstream Termux:X11's direct-touch mode reported by Phoshdroid,
CPU-only rendering (heat, lag at native resolution), a lock-screen lockout,
and Docker Hub pull limits.

Preparation for the install that can be done on the phone itself: read the
slot with `getprop ro.boot.slot_suffix` (readable without root under AOSP
12's policy); check whether the bootloader is unlocked with
`ro.boot.verifiedbootstate` and `ro.boot.flash.locked`; find the API level
with `ro.build.version.sdk`; turn on Developer options and the OEM
unlocking toggle. `fastboot oem unlock` and the flash itself still need
another host.

### What it implies

- **Preparation on the phone, before any Termux tooling:** check the
  model (HD1913); run `getprop ro.build.version.sdk`,
  `ro.boot.slot_suffix`, `ro.boot.verifiedbootstate` and
  `ro.boot.flash.locked`; turn on Developer options and the OEM unlocking
  toggle. This strand also proposed installing F.22 twice (over the air,
  then a Local install of the full package, which EU builds show under
  Settings > About device > Up to date once Developer options are on) and
  checking that the slot changed. The flashing strand (section 4) argues
  for unlocking first; the plan follows it. Make the phantom-process
  change only after any OS update, because config sync must be on during
  updates.
- **Install from GitHub, not Play:** Termux v0.118.3 (`apt-android-7`,
  arm64-v8a) from the `termux/termux-app` releases, and
  `termux-x11-universal-sharedUid-debug.apk` from Termux:X11's nightly tag.
  Do not mix in F-Droid or Play builds. Allow the browser to install
  unknown apps and turn off battery optimisation for both apps.
- **The phantom-process fix on Android 12 without a computer:** in Termux,
  `pkg install android-tools`; turn on Wireless debugging (on Wi-Fi), pair
  from split screen with `adb pair 127.0.0.1:<pairing port>`, then `adb
  connect 127.0.0.1:<port>`, and run:

  ```sh
  adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent; /system/bin/device_config put activity_manager max_phantom_processes 2147483647"
  ```

  Check the value with `device_config get`, turn Wireless debugging off
  afterwards, and run `set_sync_disabled_for_tests none` before any later
  OxygenOS update.
- **Termux side:** `pkg update; pkg install x11-repo; pkg install
  termux-x11-nightly proot-distro pulseaudio android-tools`
  (`virglrenderer-android` optional), then `proot-distro install
  debian:trixie --name antumbra`. If Docker Hub refuses, retry later or
  install a Debian trixie arm64 root filesystem tarball from a URL.
- **Guest side:** install the Phosh and app set from
  `config/packages/phosh.list` and `apps.list` (phosh, phoc, squeekboard,
  phosh-mobile-settings, fonts-roboto-unhinted, fonts-noto-core,
  librsvg2-common, gnome-console, nautilus and so on) plus dbus-x11. Create
  a non-root user (Nautilus refuses root). Copy Antumbra's overlay from the
  public repository: `usr/share/antumbra/theme`, `usr/share/icons/Antumbra`,
  `usr/share/backgrounds/antumbra`, the `90_antumbra.gschema.override`,
  `etc/dconf/db/local.d` (without the locks file and the idle lock) and
  `etc/fonts/conf.d/52-antumbra-sans.conf`. Then run
  `glib-compile-schemas` and `dconf update`, and write the gtk-3.0 and
  gtk-4.0 `gtk.css` stubs as `antumbra-session` does.
- **Launch recipe** (the experiment in section 7 replaced it with a
  launcher without gnome-session): in Termux, start PulseAudio with the
  TCP module, then `termux-x11 :0 &`, then open the Termux:X11 app; in its
  preferences set the display resolution mode to scaled (50 to 67%), the
  touch mode to Direct touch, and fullscreen on. Then:

  ```sh
  proot-distro login antumbra --user <user> --shared-tmp -- env DISPLAY=:0 \
      XDG_RUNTIME_DIR=/tmp/run-<user> GSK_RENDERER=cairo WLR_RENDERER=pixman \
      dbus-run-session -- phoc -C <preview phoc.ini> -E /usr/libexec/phosh
  ```

  with `[output:X11-1] mode=960x2080 scale=2` in the preview's `phoc.ini`,
  and squeekboard started from autostart. Switching OxygenOS to 3-button
  navigation may stop Android's bottom-edge gesture from swallowing
  Phosh's swipes (untested).
- **Package the steps** as a small script set in the repository: a Termux
  bootstrap, a guest setup script, a preview `phoc.ini` and an "update
  theme" command that pulls the CSS from the branch and restarts phoc.
  Optionally a CI job publishes a SHA-256-pinned preview root filesystem
  or overlay tarball as a public pre-release asset, because draft release
  assets cannot be downloaded without signing in. The daily loop is then:
  a CSS or dconf change is committed, the preview's update command pulls
  it, phoc restarts, screenshots go back.
- **What to test where:** the Termux preview for real Phosh and GTK
  rendering, the Antumbra CSS, fonts, icons, squeekboard, touch targets at
  the real panel size, and the Welcome screen's `--demo` flows; the
  Simulator for quick design discussions; boot, kernel and GPU
  performance, Tor and nftables, NetworkManager, the modem, the camera and
  the pop-up motor, sensors, battery and suspend, amnesia and persistence,
  greetd and Waydroid only after the first install. Visual tuning must not
  chase preview artefacts: pixman against GLES rendering, missing status
  icons, no battery or network data.
- **Known failure modes:** lag at native resolution (start scaled); heat
  in long sessions; Phosh's swipes misread by upstream Termux:X11's direct
  touch (then try the simulated touchscreen or trackpad mode, or a patched
  build such as Phoshdroid's fork); the lock screen (turn off the idle
  lock); Loupe and other glycin-based image loaders failing under proot;
  Tor Browser needing a direct launch with its sandbox off, since
  Antumbra's sudo and netns launcher cannot work.
- **A same-day fallback** for the Phosh feel if the Debian setup stalls:
  the Phoshdroid APK (stock postmarketOS Phosh, Android 12 and later
  claimed, tested only on Android 16). It is not Antumbra's userspace or
  theme.
- **Privacy:** the preview is neither amnesic nor Tor-only. Every guest
  connection uses Android's network, and `resolv.conf` points at Google's
  DNS. Treat it as a UI preview only. Logging in with `--isolated` keeps
  `/sdcard` and Android's system directories out of the container.

### Open questions

- Does phoc 0.46 with wlroots 0.18 start under Termux:X11 with no virgl?
  This needs MIT-SHM with shared pixmaps, or a working DRI3 path. Whether
  Termux:X11 offers SHM shared pixmaps was not checked; the prior art
  suggests a working path exists. (The experiment, section 7, showed the
  X11 backend works with pixman and SHM on an X server without DRI3.)
- Is OxygenOS 12 F.22 on the HD1913 API 31? Check with `getprop
  ro.build.version.sdk`. Has OnePlus backported the 12L phantom-process
  setting? The Termux GitHub build's Settings > About shows
  `MONITOR_PHANTOM_PROCS` as `<unsupported>` when it is missing.
- Does the October 2026 nightly of upstream Termux:X11 still have the
  direct-touch phantom-pointer and duplicate `XI_TouchUpdate` problems that
  Phoshdroid says break Phosh's swipe gestures?
- How well does trixie's phosh 0.46 run without gnome-session, logind,
  UPower and NetworkManager? Is the lock screen's PAM unlock usable in
  proot (`unix_chkpwd` without real root)? Does squeekboard come up when
  started by hand? (Section 7 answers the first and the last under
  emulation.)
- Does OxygenOS 12 accept a Local install of the build it already runs
  (F.22 over F.22)? The repository's docs already flag this as unverified.
  Does OxygenOS 12's background manager (from OPlus/ColorOS) kill Termux
  even with optimisation off and the `device_config` change in place?
- Frame rate and heat at 720x1560 against 960x2080 with pixman
  compositing on the Snapdragon 855+. No measurements exist for this
  device.
- Can Turnip on KGSL work at all with the 7T Pro's Android 4.14 vendor
  kernel, through a third-party glibc build or virgl/ANGLE, if GPU
  acceleration for GL clients such as Tor Browser's WebRender turns out to
  matter?
- Could another Android phone act as the fastboot host for `fastboot oem
  unlock` and flashing? Termux's android-tools plus `termux-usb` over
  USB-OTG is untested here, and `flash.sh` assumes a Linux host.

---

## 4. Unlocking and flashing without a computer

No iOS device (iPhone or iPad) can be the host. iOS gives apps no general
USB host access, Safari and every iOS browser lack WebUSB, and the only iOS
ADB app works over Wi-Fi. The OnePlus bootloader speaks fastboot over USB only, and
unlocking needs `fastboot oem unlock` sent from a host.

That leaves four routes to unlocking and flashing, and each needs some host
device:

1. **A second Android phone or tablet with USB-OTG,** running
   termux-fastboot (the real AOSP fastboot; `-S 128M`, `reboot fastboot`
   and `set_active` work as in `docs/flashing.md`) or a WebUSB page in
   Chrome for Android. GrapheneOS officially supports Android hosts for its
   fastboot.js-style installer, which reboots into fastbootd and sends
   large images. But no ready-made web tool runs Antumbra's sequence:
   fastboot.js uses the device's 256 MiB fastbootd download size instead
   of 128 MiB, and it appends the current slot (Android's) to any A/B
   partition name.
2. **A borrowed computer:** a Mac (no driver), a Windows PC with admin
   rights (the Google USB driver needs admin), or a Linux live USB that the
   OnePlus itself can write with EtchDroid. A public or library PC will
   almost certainly fail on driver rights or locked boot settings.
3. **A repair shop.** It can probably do it, but there are trust and
   wrong-slot risks, and a shop handling the phone works against the point
   of a privacy OS.
4. **No route without a host exists.** The cloud container has no USB, and
   a locked phone cannot unlock itself.

Two device-specific risks dominate. First, OnePlus 7-series phones on
OxygenOS 12 reportedly refuse `fastboot oem unlock` ("Device cannot be
unlocked for technical reason"). The fix is a rollback to OxygenOS 11,
which wipes the phone, then the unlock, then F.22 twice. Antumbra's docs
did not mention this. Second, Antumbra has never booted, `fastboot boot` is
refused so every test is a flash, the initramfs has no shell or USB
console, and the bootloader does not reliably fall back to Android's slot.
A failed first boot can only be fixed with a host.

Once Antumbra boots, a computer-free way back to Android (`qbootctl -s
<Android's slot>`) and in-OS updates are technically possible, because root
can write `boot_X`. But the current userdata layout sizes `ANTUMBRA_LIVE`
to its content plus 96 MiB with `ANTUMBRA_DATA` directly after it, and the
roadmap's "inactive slot" is Android's slot under the current design. So
an in-OS updater needs a layout change, and that change has to ship before
the one computer session if the computer is to be needed only once.

Recommendation: never a one-shot install on a borrowed or public computer
with no way back. Attempt an install before a computer is at hand only if
(a) a fastboot host is available again and again, ideally a second Android
device with an OTG adapter, already proven with a read-only rehearsal
(`getvar`, `reboot fastboot`, `is-userspace`); (b) the phone is an HD1913
(HD1911 or HD1917 untested; HD1925 never); (c) the OEM unlocking toggle
exists and the unlock succeeds, or the OxygenOS 11 rollback detour is
acceptable; and (d) a debug build is available, so a failed boot shows
kernel messages that can be photographed. A borrowed computer is acceptable
only for a single test boot after which, if it fails, Android is restored
before the computer goes back.

The phone alone can be prepared now: the model and OxygenOS version,
Developer options with OEM unlocking and USB debugging, the bootloader
screen's DEVICE STATE, Android's slot through Termux's `getprop` (may be
blocked for apps), backups, and cables.

### What it implies

- **One gating question:** is a fastboot host available at home, again
  and again (best a second Android phone or tablet with OTG; a cheap used
  one is enough)? If not, phone testing waits until a computer is; until
  then the work is visual and performance work proven in the VM and the
  Simulator, and the phone is only prepared. If yes, an early install with
  weekly reflash cycles becomes possible.
- **Without a host:** read the model (HD1913, HD1911 or HD1917 fine; HD1925
  stop) and the OxygenOS build; turn on Developer options, OEM unlocking
  and USB debugging; boot to the bootloader with Power + Volume Up +
  Volume Down to read DEVICE STATE, then press Start; install Termux and
  try `getprop ro.boot.slot_suffix`, `ro.product.model` and
  `ro.build.display.id` (apps may be blocked from some `ro.boot` properties;
  unverified); back up the phone; get a USB-C data cable and a
  USB-A-female-to-C OTG adapter.
- **Order of OS steps: unlock first, then F.22 twice.** Spend no effort on
  the F.22 double install before the unlock is confirmed, because on
  OxygenOS 12 the unlock may fail with "technical reason" and the OxygenOS
  11 rollback wipes the phone anyway. The over-the-air and local installs
  after unlocking are phone-only steps (an OTA on an unlocked stock
  OnePlus is a likely but unverified assumption).
- **Before any write,** a read-only rehearsal from the chosen host:
  `getvar product`, `getvar unlocked`, `getvar current-slot`, `reboot
  fastboot`, `getvar is-userspace`, `getvar snapshot-update-status`,
  `reboot bootloader`, `reboot`. It proves the cable, the OTG role,
  `termux-usb`'s permission prompts and fastbootd's reconnects before
  anything is risked.
- **Cloud-session work without a computer:** (a) a CI job that builds an
  `ANTUMBRA_DEBUG=1` phone image as a separate, non-release artifact for
  first boots; (b) a public pre-release, so no host has to sign in to
  GitHub; (c) a Termux variant of `flash.sh`, i.e. a `fastboot` shim that
  calls termux-fastboot, tested with `--dry-run` in CI; (d) optionally a
  WebUSB flasher built on fastboot.js, with a 128 MiB transfer cap,
  explicit `_X` partition names, `set_active`, a reconnect button for every
  reboot on Android and streaming SHA-256 checks; (e) a "Restart into
  Android" action using `qbootctl -s`.
- **If a computer is to be needed only once,** the userdata layout must
  change before that install: fixed-size `LIVE_A` and `LIVE_B` (userdata
  has about 232 GB), initramfs selection with a boot counter and fallback,
  and a boot image that accepts both live root hashes. Only then can
  roadmap item 4 deliver updates written from the phone itself. The
  roadmap and architecture text that says "inactive slot" needs rewording,
  because that slot is Android's.
- **Add to `docs/flashing.md` and the install guide:** the OxygenOS 12
  "technical reason" unlock failure and the OxygenOS 11 rollback detour;
  the second-Android-with-OTG route; the warning that generic web flashers
  write the current (Android's) slot; and restoring Android (`set_active`
  plus a factory reset) before handing back a borrowed computer if the
  first boot fails.
- **Photographs are the debugging channel:** with a debug build, the boot
  screen, a red error screen or the fastboot screen is photographed with
  another device and the photos go to the cloud session. The first-boot
  checklist names exactly what to photograph.
- **Not the main route:** public or library computers and repair shops. A
  shop is acceptable only for a supervised one-time job, with images
  checked beforehand on one's own device (Termux `sha256sum`)
  and the slot letter written down. A borrowed Mac, or any PC that can
  boot a Linux live USB written by EtchDroid, is the best borrowed-computer
  option.

### Open questions

- Does the "Device cannot be unlocked for technical reason" bug affect
  the 7T Pro (hotdog) on F.22, or only the 7 Pro? The only reports found
  are for the GM1913. Are 7T Pro rollback packages still downloadable now
  that the OnePlus US Community reportedly closed on 16 Aug 2026
  (unverified)?
- Does termux-fastboot get through the reboot to fastbootd, `termux-usb`'s
  permission prompts and a 1.42 GB `-S 128M` sparse flash on a real
  Android host? Is its reported per-command slowness (issue #30)
  acceptable?
- Does the OnePlus's fastbootd (OxygenOS 12) accept 256 MiB transfers,
  which a stock fastboot.js page would send, or must the 128 MiB bound be
  enforced?
- Can apps (Termux) on OxygenOS 11 or 12 read `ro.boot.slot_suffix`, or
  does it need shell ADB (wireless debugging through LADB or Shizuku)?
- Will the bootloader (ABL) boot a mainline Antumbra boot image from
  `recovery_X` through its menu? That would give a computer-free fallback
  after a bad update.
- Does Android, booted with `qbootctl -s` from Antumbra, cleanly
  reformat Antumbra's userdata, or does it stop in recovery asking for a
  factory reset? Either works, but the on-screen flow should be
  documented.
- Should the in-OS updater's dual-live layout ship before the first
  install on hardware? It delays the first boot but avoids a second
  mandatory host session.

---

## 5. Closer to Android

Recommendation: keep Phosh for now and make Antumbra more Android-like in
layers: first data, CSS and gsettings changes, then small helpers, and only
after that a few tiny Phosh UI patches. Do not switch to Plasma Mobile now.

Why stay on Phosh:

- Debian trixie is frozen at Phosh 0.46. Upstream has reached 0.58
  (October 2026), but no release from 0.47 to 0.58 added a Back gesture, a
  home screen with widgets, wallpaper-derived colours, a two-stage shade or
  swipe typing, and Phosh is still GTK 3 with libhandy. Waiting for
  upstream buys nothing Android-like.
- Plasma Mobile is more Android-like out of the box: Folio has pages,
  widgets, folders and an app drawer; gesture navigation (swipe up for
  home, hold for recents, a horizontal scrub); a quick-settings drawer that
  minimises and expands; reorderable tiles. It still has no system Back
  either: its right navigation-bar button is Close, and a draft to make it
  Back has been open since 2022.
- Trixie only has Plasma Mobile 6.3.6. Its dependencies pull in the Qt 5
  maliit-keyboard (about 106 MB) on top of Qt 6 and KF6, and
  plasma-workspace depends on gdb and drkonqi. Switching would mean redoing
  `shell.css`, the squeekboard styling, the dconf locks, the Android
  app-folder script and the lock screen's privacy settings, for a newer UI
  that Debian has only in forky.

What Antumbra can do itself, ranked by visibility per effort:

- a newer Android-style font (Google Sans Flex and Roboto Flex are both
  OFL);
- a keyboard with a suggestion strip: phosh-osk-stub (stevia's older
  name), which has presage and hunspell completion; squeekboard is dormant
  and has no prediction;
- an Android status bar: Material Symbols for every status icon, and the
  clock on the left (a one-file Phosh UI patch);
- an edge-swipe Back helper: a layer-shell edge strip that sends Alt+Left
  or Escape through the virtual-keyboard protocol, which phoc exposes;
- a real Settings app (gnome-control-center): Phosh's tile long-press and
  "Settings" buttons call `org.gnome.Settings`, which Antumbra does not
  ship;
- "Material You lite": a seed colour chosen at the Welcome screen or taken
  from the wallpaper, turned into a regenerated Material 3 palette at login,
  the nearest GNOME accent, and the same seed pushed into Android's Monet
  settings.

The honest limit: the shell can look and move like Android, but it cannot
become Android. There are no Google services or Play Integrity. Tor
carries TCP only, so calls and QUIC suffer and many services block Tor.
Amnesia means no learned words or usage history. Android itself is
LineageOS 20 (Android 13) in Waydroid, with its own keyboard and its own
window caption bar. GNOME apps keep GNOME layouts; only colours, fonts and
icons change.

### What it implies

- **Stay on trixie's Phosh 0.46** for this window: no Plasma Mobile, no
  backport of Phosh 0.58. Re-evaluate when Debian forky (Phosh 0.57 or
  later, GTK 4.24, libadwaita 1.10, Plasma 6.7) is the base, or when
  Phosh's GTK 4 port lands, which would invalidate `shell.css`. At most,
  build a Plasma Mobile VM image once for comparison, not as a migration.
- **Sizes used below:** S, one cloud session of data, CSS or gsettings
  work, checked with VM screenshots; M, 2 to 4 sessions with a small
  Python helper or a one-file Phosh patch, plus unit and VM tests; L, weeks
  of C work.
- **1. Font (S).** Ship Google Sans Flex (OFL, a 4.15 MB variable TTF, the
  Material 3 Expressive face) or Roboto Flex as the UI face: vendor the
  TTF; change `font-name` and `document-font-name` in
  `90_antumbra.gschema.override`; update `52-antumbra-sans.conf`; keep Tor
  Browser on its bundled fonts (`launch-tor-browser` already does); check
  that the Noto fallback covers CJK.
- **2. A keyboard with a suggestion strip (M).** Replace squeekboard with
  trixie's phosh-osk-stub 0.46: presage or hunspell completion, emoji,
  swipe down to close, a Ctrl/Alt bar, PIN and number layouts. Set the
  completer through gsettings; restyle its nodes in `shell.css` (Material 3
  key shapes, Gboard-like surface tones); check the greeter
  (`antumbra-greeter-inner` starts the on-screen keyboard). About 36 MB
  (libpresage-data). Presage's learning stays in RAM unless the Dotfiles
  feature persists it. No Phosh keyboard has glide typing. Needs touch
  testing on the phone.
- **3. An Android status bar.** (a) S: Material Symbols for every
  remaining status icon (cellular, Wi-Fi off, torch, rotation, airplane,
  charging) as data files in `/usr/share/icons/Antumbra`. (b) M the first
  time, S after: the clock on the left and icons on the right through a
  small patch to phosh's `top-panel.ui`, built as a local patched-phosh
  package with the pattern of `build/libcamera.sh` and its chroot; that
  package then carries any later one-file UI patches.
- **4. Edge-swipe Back (M, a behaviour change, needs touch testing).** A
  user-session helper (Python, GTK 3 with `gir1.2-gtklayershell-0.1`,
  about 150 to 250 lines, plus a systemd user unit) puts two transparent
  strips of about 12 px on the left and right overlay layer. A horizontal
  drag past a threshold sends Alt+Left through the virtual-keyboard
  protocol (`wtype` is in trixie), which covers Tor Browser and
  GTK/libadwaita apps. Waydroid windows (app id `waydroid.*`) get Escape
  instead; that Android treats an unhandled Escape as Back is believed, not
  verified. Risks: it steals edge touches, `wtype` swaps the keymap, and
  there is no visual arrow unless one is drawn. The VM's pointer can only
  partly test it.
- **5. A real Settings app (M).** Add trixie's gnome-control-center 48
  (adaptive, libadwaita): Phosh's tile long-press and the Wi-Fi, Bluetooth
  and audio "Settings" buttons start working, and the grid gets an
  Android-like Settings entry. Hide or remove the panels that conflict
  with the privacy model: Online Accounts, Sharing, Users, perhaps Network
  proxy. About 24 MB plus dependencies (accountsservice, colord,
  gnome-online-accounts, tecla); needs a privacy and AppArmor review.
- **6. "Material You lite".** (a) S/M: precompute 4 to 6 Material 3
  tonal-spot palettes at build time with material-color-utilities, offer a
  Colour choice on the Welcome screen (the Tails-style place for
  settings), have the login stub import the chosen palette before or over
  `shell.css` and `apps.css`, and set the nearest GNOME `accent-color`.
  (b) M: derive the seed from a custom wallpaper at login with a small
  quantiser (vendored or pure Python). Phosh and GTK read user CSS only at
  start, so a change applies at the next login. Test in the VM that a
  later `@define-color` overrides an earlier one in the same imported
  provider. (c) S: push the same seed into Android during Waydroid's
  provisioning: `settings put secure theme_customization_overlay_packages`
  with `system_palette` and `color_source=preset`, plus `cmd uimode night
  yes`. The keys are verified in AOSP 13; the effect in Waydroid is not.
- **7. Material dark surfaces in apps (S, a product decision).** Extend
  `apps.css` from accent only to libadwaita's surface variables (window,
  view, headerbar, card, popover, dialog, sidebar) in Material 3 surface
  tones, so apps look Android-dark rather than GNOME-grey. GTK 4.18 has no
  `prefers-color-scheme` for custom colours, so this means committing to
  dark only and removing or redefining the Dark Mode tile.
- **8. Themed app icons (M, data only).** Material-Symbols-style
  monochrome icons on tonal circles for the roughly 15 shipped apps and the
  Android folder, as overrides in the Antumbra icon theme, like Android
  13's themed icons. Keep Tor Browser's own logo if its trademark guidance
  requires it.
- **9. Android apps polish (S each).** Check in the VM that Android
  notifications reach Phosh (Waydroid 1.6.3 forwards them; the pinned
  image's support is unknown); keep multi-window and the Android folder;
  document that Android's own caption bar (back, minimise, maximise,
  close) cannot be hidden (Waydroid issue #2204).
- **10. Animation feel (an S experiment, low visibility).** Try
  `GTK_SLOWDOWN` around 0.75 for the phosh process only (not exported to
  the whole session) and compare VM frame captures. phoc's 300 ms
  ease-out-cubic panel slide needs a phoc patch, which is not worth it
  now.
- **11. Custom quick-setting tiles (M):** out-of-tree C plugins against
  trixie's phosh-dev 0.46, for example "New Tor circuit" or "Android
  on/off". The built-in tile order and a two-stage Android shade need Phosh
  C changes (L): later.
- **12. Deferred (L), each needing the patched-phosh package:** a bottom
  dock and favourites below the grid (`app-grid.ui` and code); a home-bar
  horizontal quick-switch (`home.c`); a home screen with widgets (Phosh
  has no home-screen layer); a gmobile panel description for
  `oneplus,hotdog` (rebuild gmobile or contribute it upstream).
- **Scheduling before the first install:** CSS, data and gsettings items
  (font, icons, palette, app surfaces, the Settings app) can be built and
  checked now through cloud VM screenshots and the Simulator. Touch
  behaviour (the keyboard swap, edge Back, quick-switch) should be built
  so it is ready for the first real tests on the phone.
- **Write the honest limits into the plan and the docs:** no Google Play
  services, Play Store, Google account, FCM push or Play Integrity, so some
  banking apps and games will not work; Tor carries TCP only, so WebRTC,
  VoIP and QUIC degrade, many services block or challenge Tor exits, and
  pages load slower; amnesia means no learned keyboard words, recent items
  or "smart" suggestions unless persisted; Android is LineageOS 20
  (Android 13) in a weaker Waydroid sandbox, with its own keyboard and
  caption bar; GNOME and libadwaita apps keep GNOME layouts, and only
  colour, font and icons can be made Android-like. The result is
  "Android-like Phosh", not Android.

### Open questions

- Do Phosh's tile long-press and its Wi-Fi, Bluetooth and audio
  "Settings" buttons really do nothing in the current image, which has no
  gnome-control-center? Inferred from the source; check it in the VM.
- Does the Waydroid image pinned on 2026-09-27 include the Android-side
  notification client, so that Android notifications appear in Phosh's
  drawer? Test it in the VM by posting a notification inside Android.
- Inside Waydroid's LineageOS 20 multi-window windows, does an injected
  Escape act as Android's Back? Does setting
  `theme_customization_overlay_packages` (`system_palette`, `preset`)
  actually re-tint Android apps?
- Does phoc deliver touches to a thin left- or right-anchored overlay
  layer surface above fullscreen apps without breaking Phosh's top and
  bottom drag gestures? Does `wtype`'s keymap upload on every call
  interfere with the on-screen keyboard's virtual keyboard?
- If a per-user palette file is imported after `shell.css`, do its later
  `@define-color` values override the earlier ones? This decides how the
  palette is wired in; verify it with VM screenshots.
- Which gnome-control-center 48 panels can be hidden cleanly (for example
  by removing their `.desktop` files)? Which conflict with the Tor-only,
  amnesic model: Online Accounts, Sharing, Users, Network proxy,
  Privacy/location? Does Tails ship GNOME Settings, and how does it prune
  it? Not checked.
- Phosh's and Plasma Mobile's memory use on this phone is unmeasured. If
  the Plasma question comes up again, measure `MemAvailable` at an idle
  home screen in a one-off VM run.
- Should Antumbra become dark only (needed for full Material surfaces in
  GTK 4.18 apps), or should apps stay accent-only until GTK 4.20 or later
  arrives with forky?
- Licence and trademark check before vendoring Google Sans Flex (OFL, but
  carrying a Google brand name): is Roboto Flex the safer choice for an
  OS image?

---

## 6. Performance

Most performance levers can be found, and many measured, before the
phone. On 9 Oct a baseline ran in QEMU on the debug VM image (8 GiB, TCG;
`tests/vm/perf/vmperf.py`, results in `vm-baseline-2026-10-09.txt`), a
squashfs read benchmark ran on the build host
(`tests/vm/perf/readbench.py`), and the port's evidence was read up to its
HEAD of 2026-08-29.

Found by inspection or VM measurement (verified):

- **Wrong refresh rate and scale in the user session.** Only the greeter
  reads `/etc/antumbra/phoc.ini` (60 Hz, scale 3). `phosh-session` reads
  `/etc/phosh/phoc.ini`, which the image does not ship, then Debian's
  default, where `DSI-1` is commented out. The port's panel driver marks
  90 Hz as the preferred mode. So the Phosh session will most likely switch
  the panel to 90 Hz, the mode with DSI transport errors, at a scale phoc
  picks itself. (Evidence: `config/rootfs/usr/libexec/antumbra-greeter-session`
  lines 17-21; `config/rootfs/usr/libexec/antumbra-session` line 30;
  `image:/usr/bin/phosh-session` lines 4, 40-41, 57; Debian's
  `/usr/share/phosh/phoc.ini` lines 4-5; the port's patches 0004 (90 Hz
  mode first, `DRM_MODE_TYPE_PREFERRED`) and 0007 ("90 Hz selected as the
  preferred mode"); phoc's strings "Using preferred mode for %s" and
  "Output DPI is %f for mode %dx%d, using scale %f".)
- **Slow root filesystem compression.** Reads from the xz squashfs with
  1 MiB blocks ran about 11 times slower than zstd sequentially and about
  13 times slower for random 4 KiB reads. The zstd image is only 10 to 17%
  larger (table below).
- **Work repeated at every boot.** The image ships no AppArmor cache, so
  about 127 profiles are compiled at each boot (`apparmor.service` took
  57 s under TCG, second in `systemd-analyze blame`). It ships no
  fontconfig cache either (`var/cache/fontconfig` holds only
  `CACHEDIR.TAG`, and `mksquashfs -all-time` would leave a cache stale
  unless the font directories' times are normalised first).
- **The largest idle wake source.** Tails' `tor_wait_until_bootstrapped`
  polls once a second (about 26 context switches a second, 20 MiB PSS)
  until Tor has bootstrapped. Because of the same unit, `systemd-analyze`
  reports nothing until then.
- **Memory after login.** 970 MiB used, 6.97 GiB available. Transparent
  huge pages are set to "always" and back 224 of 426 MiB of anonymous
  memory. 17 gnome-settings-daemon plugins run, and the gvfs AFC monitor
  wakes once a second.
- **Kernel command line.** `slub_debug=FZ` sends every slab allocation
  down the slow path and turns off pointer hashing.

The squashfs benchmark: a 493 MiB subset of the VM's root filesystem (Tor
Browser, libLLVM, libgallium, GTK 4, libadwaita), mounted with the host
kernel's squashfs (6.18, an x86 Xeon), one reader, the page cache dropped
before each run:

| Compression, block size | On disk | Sequential | Random 4 KiB read |
|---|---|---|---|
| xz, 1 MiB (shipped: `build/squashfs.sh`) | 184 MB | 38 to 40 MiB/s | 3.7 ms |
| xz, 128 KiB | 197 MB | 41 to 42 MiB/s | 2.3 ms |
| zstd level 19, 1 MiB | 202 MB (+10%) | 503 to 510 MiB/s | 0.33 ms |
| zstd level 19, 128 KiB | 215 MB (+17%) | 428 to 441 MiB/s | 0.25 to 0.29 ms |
| lz4hc, 128 KiB | 268 MB (+46%) | 854 to 886 MiB/s | 0.14 ms |

The absolute numbers are x86's, but the ratio comes from decompression and
should hold on the phone's Cortex-A76 and A55 cores; a TCG VM shows the
same direction. The kernel already has `SQUASHFS_ZSTD`, `SQUASHFS_LZ4` and
`DECOMP_MULTI_PERCPU`. The xz BCJ filter in use is `-Xbcj arm`, the 32-bit
ARM filter, which is unlikely ever to win on AArch64 code (mksquashfs keeps
whichever of no filter and `arm` compresses smaller per block, so the cost
is build time only; mksquashfs 4.6.1 offers no arm64 filter). The Waydroid
images sit inside the xz squashfs and are loop-mounted, so every Android
read is a 4 KiB read that can force decompressing a whole 1 MiB xz block,
and the data is cached twice.

Already in the mainline device tree and kernel: cpufreq-hw, an energy
model, EAS and PSCI cluster idle. Missing: uclamp, the TEO idle governor,
tracing (FTRACE), SoC sleep statistics, and the measurement tools
(powertop, perf, mesa-utils, vulkan-tools).

Mesa 26.1.6 is in trixie-backports against 25.0.7 in trixie. GTK 4.18 uses
the Vulkan renderer by default on Wayland. The VM forces cairo, so GPU,
frame-rate and 90 Hz work can only be measured on the phone.

Upstream 90 Hz: not fixed as of 2026-08-29. The errors (DSI/DSC FIFO
underflow and timeout bursts) are characterised but not fixed; a soft-reset
fix was tried and reverted. Similar errors also appear in fixed 60 Hz mode
around screen blank and unblank, and a lock and unlock or a suspend and
resume clears corrupted scanout. The port's newest release tag is still
v0.2.0-alpha.2, the one Antumbra pins. So: keep 60 Hz, and since Phosh
blanks the screen after 120 s of idle, count `dsi_err_worker` lines per day
as a display-stability metric.

Battery levers that need the phone: Phosh suspends automatically after 15
minutes idle (the default); no WoWLAN triggers are set, so the port's
evidence says Wi-Fi drops at every suspend; Tor's connection padding keeps
network traffic going; the modem's radio-off timer queries the modem every
5 minutes.

Anything GPU, display, battery or suspend related can be measured only
after the first install.

### What it implies

Before the phone (VM only):

1. Ship `/etc/phosh/phoc.ini` (`DSI-1` at 60 Hz, scale 3), or point
   `phosh-session` at Antumbra's file, and add a lint check. Without it,
   the session probably runs at the unstable 90 Hz.
2. Switch the root squashfs to zstd (`-Xcompression-level 19`, 128 to
   256 KiB blocks), or move the Waydroid images out of the xz squashfs.
   Measure the image size (+10 to 17%) and the VM's boot and Android boot
   times before and after.
3. Precompile the AppArmor cache and ship a valid fontconfig cache (font
   directory times normalised before `fc-cache`). Check in the VM with
   `systemd-analyze blame` and `time fc-list`.
4. Replace the 1 Hz `tor_wait_until_bootstrapped` poll with an event
   subscription; load each network namespace's rules in
   `antumbra-create-netns` with one `nft -f`.
5. Mask units that do nothing useful here: `apt-daily*`, `dpkg-db-backup`,
   `e2scrub*`, `fstrim`, the gvfs AFC, GOA, gphoto2 and MTP monitors; make
   udisks2 D-Bus-activated. Test masking unneeded gnome-settings-daemon
   plugins in the VM, checking that gnome-session still starts.
6. VM A/B tests of transparent huge pages `madvise` against `always`,
   `vm.swappiness` 100 to 180 with `page-cluster` 0, and `slub_debug` off
   (or kept, with `hash_pointers=always`, which fits the 49 free bytes of
   the command line). Use a scripted memory-pressure run (Tor Browser plus
   Android) and log PSS, PSI, `zramctl` and `MemAvailable`.
7. A debug-only package list: powertop, linux-perf, mesa-utils,
   vulkan-tools, wlr-randr, smem, qrencode, so that the first measurements
   on the phone and `docs/hardware-validation.md`'s `glxinfo` and
   `vulkaninfo` steps work. An `antumbra-perf-snapshot` script prints the
   daily metrics on one screen and as a QR code, to be captured with a
   phone camera: Antumbra has no USB networking or SSH, by design.
8. Optionally a device-tree override with the `qcom,rpmh-stats` node (the
   address taken from sister SoCs; to verify), so suspend-to-idle depth can
   be read in debug builds.
9. An image variant with Mesa 26.1.6 from trixie-backports, ready for an
   A/B test on the phone. It cannot be judged in the VM.
10. Make the VM baseline a recurring job: it takes about 15 min under TCG
    and is fully scripted (`tests/vm/perf/vmperf.py`). Absolute boot times
    are inflated by emulation (estimated 10 to 30 times); compare rankings,
    PSS and wake-ups across builds instead. GPU, display, 90 Hz, frame
    pacing, battery, suspend, the modem and Wi-Fi power cannot be measured
    in the VM.

On the phone, after the first install: first establish the clock at boot
(the date against real time) and Tor's bootstrap time, and confirm that
the session runs at 60 Hz and scale 3. Then record three days of the daily
metrics below before changing anything. Then A/B one variable at a time:
`GSK_RENDERER` vulkan against ngl; Mesa 25.0.7 against 26.1.6; automatic
suspend on and off, and WoWLAN on and off (overnight drain); the modem
timer at 5 against 30 minutes; 60 against 90 Hz (`dsi_err` count per hour,
jank, drain) only as an opt-in. To time app launches and animations, film
them at 240 fps: it is the cheapest objective way to measure
tap-to-first-frame and dropped frames.

The daily metrics, with the commands for the phone:

| Metric | How |
|---|---|
| Boot, power key to Welcome screen | `journalctl -b -o short-monotonic -u greetd -u apparmor -u antumbra-create-netns \| head`; `systemd-analyze blame \| head -15` (blame works before boot "finishes"; plain `systemd-analyze` and `critical-chain` do not until Tor has bootstrapped); a stopwatch from the power key to the visible Start button |
| Start to a usable home screen | `journalctl -b -o short-monotonic -u antumbra-apply-welcome-settings \| tail -2`; `journalctl -b -o short-monotonic _COMM=phosh \| head -1` |
| Tor bootstrap and the clock | `journalctl -b -o short-monotonic -t Tor \| grep -E 'Bootstrapped (0\|100)%'`; `ls -l --time-style=+%s /run/htpdate/success`; `date` at the Welcome screen against real time |
| Memory in three states (idle after login; one Tor Browser tab; Android running) | `grep -E '^(MemAvailable\|AnonPages\|AnonHugePages\|Shmem\|SwapFree):' /proc/meminfo; zramctl; df -m /run/live/overlay; cat /proc/pressure/memory`; PSS per process: `smem -tk -s pss \| tail -15` (debug build) or the `smaps_rollup` snippet in `vmperf.py`; GPU memory: `grep -h drm-.*memory /proc/$(pidof phosh)/fdinfo/* \| sort \| uniq -c` |
| Idle wake-ups (screen on and idle, 60 s; and screen off) | interrupts: `/proc/interrupts` before and after `sleep 60`; context switches per task: the 60 s snippet in `vmperf.py`; wake-up sources: `grep -H . /sys/class/wakeup/wakeup*/{name,event_count} \| paste - -`; CPU idle residency: `grep -H . /sys/devices/system/cpu/cpu*/cpuidle/state*/time` (deltas) |
| CPU and GPU frequency, temperature | `cat /sys/devices/system/cpu/cpufreq/policy*/stats/time_in_state` (deltas); `cat /proc/sys/kernel/sched_energy_aware`; `cat /sys/class/devfreq/*/cur_freq /sys/class/devfreq/*/trans_stat`; `paste <(cat /sys/class/thermal/thermal_zone*/type) <(cat /sys/class/thermal/thermal_zone*/temp)`; is 2956800 in `policy7/scaling_available_frequencies`? |
| Battery drain | `ls /sys/class/power_supply/`, then `cat /sys/class/power_supply/bq27411-0/{capacity,current_now,voltage_now,charge_now,temp}` (the name to confirm) or `upower -d`; percent per hour overnight with the screen off; suspend counts: `cat /sys/power/suspend_stats/{success,fail}` and `journalctl -b \| grep -cE 'PM: suspend (entry\|exit)'` |
| Display stability | `journalctl -k -b \| grep -c dsi_err_worker`; `dmesg \| grep 'initializing panel at'` (60 or 90); `journalctl -k -b -p err \| wc -l`; GPU faults: `journalctl -k -b \| grep -ciE 'gmu\|hangcheck\|iommu fault'` |
| App launch, cold (first this boot) and warm, for Settings, Files, Console, Tor Browser | film at 240 fps from the tap to the first frame; as a proxy, `time gdbus wait --session --timeout 30 org.gnome.Nautilus` while launching; a cold squashfs read: `sync; echo 3 > /proc/sys/vm/drop_caches; time cat /usr/local/lib/tor-browser/libxul.so >/dev/null` |
| Smoothness | film a fixed gesture script at 240 fps (open the app grid, scroll Settings, pull down quick settings, switch apps) and count dropped frames; on the device, `VK_INSTANCE_LAYERS=VK_LAYER_MESA_overlay` for GTK 4 apps and `GALLIUM_HUD=fps` for GL clients |

### Open questions

- Which scale does phoc choose for the 71x154 mm, 1440x3120 panel when no
  configuration applies? It computes one from the output's DPI
  ("Output DPI is %f ... using scale %f"). Unverified until the phone runs
  it, or until phoc's scale computation is read.
- Is the CI-built phone release (0.1.0-alpha.2) the same as the VM build
  in these respects: no `/etc/phosh/phoc.ini`, empty fontconfig and
  AppArmor caches? It uses the same hooks and lists, so very likely, but
  its squashfs was not inspected.
- What is the `sh` process (pid 1881 in the VM's user session) that woke 2
  times a second? It was not identified before the VM was shut down. Check
  with `ps -o pid,ppid,args -p <pid>` on the next run.
- Can gnome-session (systemd-managed, `phosh.session`'s
  RequiredComponents) start with the Wacom, Smartcard,
  PrintNotifications, Sharing, Wwan and Color plugins masked, or does
  Antumbra need its own session file?
- Do GitHub's `ubuntu-24.04-arm` hosted runners expose `/dev/kvm`? (Section
  2: no, as of Sep 2026.)
- Does the PM8150's RTC hold usable wall-clock time under mainline without
  Android's offset? If not, does Tor bootstrap at all on the first boot,
  and how is the clock recovered without the captive-portal date prompt?
- Does Tor Browser 16 alpha on this GPU use hardware or software
  WebRender? Check `about:support` on the phone; it drives both the
  browser's smoothness and battery.
- Is the 855+'s prime-core 2.96 GHz step dropped by qcom-cpufreq-hw
  because the device tree's OPP table stops at 2.84 GHz? Check `dmesg |
  grep 'failed to update OPP'` on the phone.
- WoWLAN trade-off: keeping Wi-Fi associated across s2idle (fast resume,
  Tor circuits survive) against wake-ups from ordinary traffic and Tor's
  padding. Which trigger set (none, disconnect, magic-packet, any) gives
  the best overnight drain? Phone only.
- Is the `qcom,rpmh-stats` SRAM really at `0x0c3f0000` on SM8150, as on
  SDM845 and SM8250? Unverified.
- How much does Mesa 26.1.6 improve GTK 4 on Turnip or phoc on freedreno
  on the A640? No release-note evidence specific to A6xx was found; it
  needs an A/B test on the phone.
- Is the cost of decompressing and caching the loop-mounted Waydroid
  images twice large in practice? Measure Android's boot time and
  `fincore` in the VM with and without zstd.

---

## 7. The nested-Phosh experiment

**Verified:** Antumbra's real arm64 Phosh session, from the 6 Oct VM disk
with Android apps, runs nested inside a plain X server (Xvfb, 720x1560),
without systemd, logind, journald or a system D-Bus. The binaries ran under
qemu-user in a root chroot on the read-only squashfs with an overlay. phoc
0.46 (wlroots 0.18) used its X11 backend with the pixman renderer and SHM,
because the X server has no DRI3; phosh 0.46 printed "Phosh ready after
36.55s" on the cold first run and 25.1 to 25.9 s on later runs. The app
grid, quick settings, the lock screen and wallpaper, squeekboard, a GTK 4
app (Calculator, about 30 s to its first frame with `GSK_RENDERER=cairo`)
and GTK 4 Text Editor on the default GL renderer (llvmpipe, about 31 s) all
rendered with Antumbra's theme and defaults. XTEST pointer clicks reached
phoc and phosh through XInput2: a tap on the top bar opened quick settings,
a tap on an app icon launched it.

What it took, and what failed, run by run, is in
`tools/termux-preview/experiment/README.md`, with the scripts and the
launcher. In short:

- The faithful path (`antumbra-session`, then `phosh-session`) dies at
  once without journald, because `phosh-session` wraps phoc in
  `systemd-cat`. A 4-line `systemd-cat` shim gets past it.
- On the gnome-session route, gsd-power (a RequiredComponent of
  `phosh.session`) needs logind and UPower; it exits, and gnome-session
  showed its failure screen in one of five runs. Race-prone without
  logind.
- **The reliable route has no gnome-session:** `dbus-run-session -- phoc -S
  -C phoc.ini -E "sh -c 'squeekboard & exec /usr/libexec/phosh
  --unlocked'"`, with `WLR_BACKENDS=x11 WLR_RENDERER=pixman
  GSK_RENDERER=cairo`, the session variables `antumbra-session` exports and
  its two `gtk.css` stubs. About 10 processes instead of roughly 25.
- Antumbra's idle lock (`/etc/dconf/db/local.d/00-antumbra` lines 13-17:
  idle-delay 120, lock-enabled true, lock-delay 0) blanked and locked the
  nested screen after about 2 minutes; the blank unmaps the X window, and a
  pointer could not get past "Slide up to unlock". A preview must turn the
  lock off or start phosh with `--unlocked`.
- The side finding of sections 1 and 6, confirmed: run 2 used Debian's
  `/usr/share/phosh/phoc.ini` (its `[output:X11-1]` mode 360x720 gave the
  first window's size) and tried to start Xwayland.
  `GSK_RENDERER=cairo` is exported only when `systemd-detect-virt --vm`
  succeeds (`config/rootfs/usr/libexec/antumbra-session-env` lines 5-6),
  so it was not set in the chroot.

What it means for the preview:

- A nested Antumbra Phosh needs only an X server with XFixes, XInput2,
  Present and MIT-SHM (DRI3 optional), a session bus, `WLR_BACKENDS=x11`
  and `WLR_RENDERER=pixman`; no systemd, logind, journald, DRM or
  `/dev/input`. Termux:X11 is that X server on the phone; that it exposes
  all four extensions to proot clients is unverified (`xdpyinfo` first).
- Startup under qemu-user on 4 x86 vCPUs: Phosh ready in 25 to 37 s, a
  GTK 4 app's first frame in about 30 s; RSS phoc 89 MiB, phosh 311 MiB,
  squeekboard 120 MiB, emulator overhead included. Unmeasured on the phone.
- The preview is CPU-rendered (phoc runs pixman with no dmabuf, so
  hardware GL would not reach its clients): its smoothness says nothing
  about the phone's GPU.
- It is not private: gnome-calculator tried to resolve
  `exchange-api.gnome.org` during the run.
- The root filesystem ships only inside the release's userdata image; a
  preview needs the squashfs unpacked in Termux or a separately published
  arm64 root filesystem.
