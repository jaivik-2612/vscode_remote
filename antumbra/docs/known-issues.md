# Known issues and gaps

Version 0.1.0-alpha.1. Everything here is as of the state of the mainline
port in August 2026 and of this repository; see `roadmap.md` for plans.

## Not yet validated on hardware

Nothing in this repository has booted on a physical OnePlus 7T Pro yet.
`hardware-validation.md` lists what to confirm first: boot, display,
touch, the Welcome screen under bare phoc, Wi-Fi with the modem in
low-power mode, the self-check, Tor bootstrap, shutdown behaviour; then
the pop-up motor, the cameras and Android apps.

## Hardware

- 90 Hz display mode is disabled (DSI transport errors on the port).
- Earpiece, headset and most microphone routes do not work on the port;
  the internal speakers and handset microphone do.
- Charging from USB hosts may be limited to the USB default (around
  500 mA) because Antumbra configures no USB gadget; dedicated chargers
  are unaffected. Warp charging is unsupported by the port.
- Bluetooth is off by default and has no opt-in flow yet.
- Cameras (`camera.md`): the front camera has a single 1748x1748 mode;
  pictures come from libcamera's software ISP with generic parameters
  (the default libcamera 0.7.1 also lacks sensor data for these sensors;
  `ANTUMBRA_LIBCAMERA_LOCAL=1` builds the port's patched 0.7.2); no flash
  control or touch focus, video recording untested; a CAMSS failure can
  need a reboot. PipeWire as the only user of CAMSS, the preview's
  orientation and the WirePlumber rule that hides CAMSS's raw nodes are
  untested on the phone (`hardware-validation.md` items 36-45).
- Sensors (rotation, light, proximity) are not available: the sensor DSP
  is disabled. There is no automatic screen rotation.
- The pop-up front camera has no drop protection. OxygenOS retracts it
  when the phone falls, on a signal from the sensor DSP, which Antumbra
  disables; mainline offers no free-fall sensor either. Do not keep the
  selfie camera open while walking, and do not push a raised camera down
  by hand: the driver reads the Hall sensors only for a course, for its
  `status` file, around sleep, at boot and at power-off or reboot, so it
  does not follow a push, and the push loads the idle gear train.
- The front camera rises whenever the front sensor is powered, which makes
  it a physical indicator for that camera only. It is not a boundary
  against root, it can lag a few hundred milliseconds behind around
  suspend and resume, and the rear cameras have no indicator at all.
- The pop-up motor's Hall thresholds were measured on a single HD1913, and
  its retraction before suspend, power-off and at boot (kernel patch
  `0102`) has not run on hardware yet (`hardware-validation.md` items
  28-35).
- Fingerprint unlock will never work on mainline.

## Software

- Tor Browser is the 16.0 **alpha** channel build, the only official
  Linux arm64 build. Tor Project advises people at risk not to rely on
  alphas. It runs without an AppArmor profile (network isolation comes
  from its namespace and the firewall, as before).
- The camera permission prompt does not protect against installed
  programs: any program running as `amnesia`, Tor Browser included, can
  use the cameras without a prompt, through the camera devices, through
  PipeWire, or through the camera portal (one "Allow" for any installed
  program, or one write to the portal's permission store by any program
  in the session, counts for all of them). That stays so until Tor Browser
  gets a confinement profile that is an allow-list: no camera device,
  neither of PipeWire's sockets (`pipewire-0`, `pipewire-0-manager`), and
  on the session bus only what the browser needs, so not the camera
  portal, the permission store, the systemd user manager or D-Bus
  activation (`camera.md`). There is no OnePlus camera app, and there will
  not be.
- Tor Browser is a desktop browser on a phone screen: usable with the
  compositor's 3x scale, not adapted.
- No Unsafe Browser (captive portals cannot be handled from the device
  yet).
- No Tor Connection assistant: bridges are entered on the Welcome screen
  or with `antumbra-tor-connect`; no QR code or Moat. What
  `antumbra-tor-connect` sets lasts until Tor restarts or, unless the
  Welcome screen chose offline mode, until the next network connection
  comes up, when the Welcome screen's choice is applied again; it is not
  saved anywhere.
- Bridges: plain, obfs4, obfs2 and obfs3 bridges must have IPv4
  addresses: IPv6 is off and the firewall gives Tor no IPv6, so the
  Welcome screen refuses such a bridge with an IPv6 address at Start,
  saying so. webtunnel and meek_lite bridges are accepted and have a
  transport; their address is only a placeholder and may be IPv6. No
  bridge of any type has connected through Antumbra yet, in the VM or on
  the phone (`hardware-validation.md`, item 17). Snowflake bridges do not
  work: snowflake needs UDP, and the firewall lets Tor make only TCP
  connections and DNS queries. The Welcome screen refuses a snowflake
  line at Start, saying so, and any other bridge type as unsupported.
  Its bridge field is a single line, but bridges pasted one per line
  are all kept; bridges typed there go separated by `;`. They are
  entered again at every boot (next item).
- The Welcome screen does not show the settings saved in Persistent
  Storage: the volume is unlocked only after Start, so every question,
  bridges included, is answered again at each boot. The volume keeps
  this boot's choices (never the screen-lock passphrase's hash) for a
  Welcome screen that unlocks first, which does not exist yet.
- The Welcome screen passes the Persistent Storage passphrase to the
  root-side applier through a 0600 file in the greeter user's directory
  in RAM (on the root overlay's tmpfs), which the applier moves into a
  root-only directory and shreds, not over D-Bus as Tails' `tps` does.
- Persistent Storage features are bind mounts without Tails' `nosymfollow`
  protection, and OS updates erase the volume (full re-flash).
- Persistent Storage has none of Tails' features for Tor Browser
  bookmarks, Electrum wallets (`~/.electrum`) or software installed with
  APT, so these are lost at every restart (`architecture.md`, section 12).
- When applying the Welcome screen's settings fails after Persistent
  Storage was created or unlocked, the applier locks it again before the
  Welcome screen can start again, and the volume's stored Welcome
  settings stay as they were (they are saved last). If locking fails too
  (a mount of it still in use; the error then says "Persistent Storage
  could not be locked again"), the volume stays open until a restart: a
  new attempt still needs the passphrase, an attempt without Persistent
  Storage is refused (an amnesic session must not start with the volume
  open), and the volume's Welcome settings are unmounted from the
  greeter's directory (lazily if need be), but restarting is the clean
  way out.
- Audio routing uses Debian's generic ALSA UCM profiles, not the port's
  device-specific ones; sound may need manual mixer settings.
- `htpdate` time synchronisation needs Tor to bootstrap first; the
  pre-Tor clock fix from Tails (captive-portal `Date` header) is not
  wired to a user prompt.
- Screen lock without a passphrase is not protective; the Welcome screen
  says so but does not force one.
- Files (Nautilus) searches file names only, not file contents: the file
  indexer, localsearch, is off, because it would rebuild its index in RAM
  at every boot (`architecture.md`, section 11).

## Interface

The theme (`architecture.md`, "Interface theme") restyles Phosh 0.46 with
settings, data files and CSS only. These Android 14 features would need
changes to Phosh's code, so they are missing:

- The top-bar clock stays in the centre. Phosh moves it only around a
  display cutout it knows about.
- Phosh's nine built-in quick-setting tiles keep their order and cannot be
  hidden. The added Dark Mode and Night Light tiles come after them.
- The drawer is a single panel (sliders, tiles, media player,
  notifications), not a two-stage shade.
- There are no back or quick-switch edge gestures. Phoc supports draggable
  surfaces on all four screen edges, but Phosh uses only the top and bottom
  ones, and a draggable panel is not a "back" action anyway.
- There are no home-screen widgets and no camera or torch shortcuts on the
  lock screen.
- Colours are fixed: they do not follow the wallpaper. The shell's own
  accent is limited to GNOME's nine accent colours (purple), which still
  shows where the theme sets no colour of its own, such as the faint tint
  of a focused shell button.
- There are no adaptive icon masks, themed monochrome app icons or blur.
- Rounded display corners: gmobile 0.3.1 has no panel description for this
  phone (`oneplus,hotdog`), so top-bar items may sit close to the corners.
  The fix is a panel description contributed to gmobile.

If these are wanted, the way is a small Phosh patch (for example moving
the clock in the top-panel template), not GLib's `G_RESOURCE_OVERLAYS`,
which GLib documents as a debugging aid.

Other limits of the theme:

- Phosh reads its stylesheets when it starts, and the session cannot be
  restarted on its own: changes to them, or to a user's own
  `~/.config/gtk-3.0/gtk.css`, apply at the next login.
- GTK 4.18 has no light/dark media query, so GTK 4 apps get only the
  theme's accent; their surfaces stay libadwaita's. The Dark Mode tile
  switches the apps and the wallpaper to light; Phosh itself always stays
  dark.
- The stylesheet targets Phosh 0.46's internal style names. A Phosh
  upgrade, and in particular its planned move to GTK 4 (which would ignore
  the GTK 3 stylesheet), needs the screenshots checked again.
- Only the battery, Wi-Fi signal, Bluetooth, Dark Mode and Night Light
  icons are Material Symbols; the others, including the ones Phosh ships
  itself (cellular, Wi-Fi off, torch, rotation), are Adwaita's, so the two
  styles mix in places.
- Notification content is not shown on the lock screen, and the
  lock-screen plugin list is locked empty, for privacy. Mobile Settings'
  lock-screen panel still lists the plugins but cannot enable them.
- Electrum and OnionShare (Qt) are listed in the phone's app grid but are
  not designed for a 480-pixel-wide screen.

## Android apps

Only in images built with `ANTUMBRA_ANDROID=1`; experimental and off until
turned on at the Welcome screen. `threat-model.md`, "Android apps", has
the security side. None of this has run on the phone yet
(`hardware-validation.md`), and in the VM only under software emulation.

- Android 13 (LineageOS 20, the newest image Waydroid's official channel
  publishes), not Android 14. No Google apps or Play services, so apps
  that need them fail or degrade; F-Droid is the app store.
- Android's security patches are frozen at the pinned image (2026-09-27)
  until Antumbra pins a newer one. The images are not reproducible and are
  not signed; they are checked against the hash Waydroid publishes.
- Android is a weaker sandbox than the rest of Antumbra and than a stock
  phone: a privileged container where Android's root is the system's
  root, no SELinux, and binder open to every local user while Android
  runs. Use it only for apps you trust.
- Network: TCP to the Internet only, through Tor. UDP (calls, WebRTC,
  QUIC, many games), VPN apps and IPv6 do not work. `.onion` addresses do
  not work either: Tor answers a lookup of one with an address in
  127.192.0.0/10, which inside Android is Android's own loopback, and
  connections to that range are refused there (otherwise they would reach
  whatever Android app listens on that port). Connections to the local
  network, the phone's own addresses on it included, wait for a time-out
  instead of failing at once; TCP to the phone's own public address, if it
  has one, goes through Tor like TCP to any other. All apps share one Tor
  identity, separate from the host's and unchanged by Tor Browser's "New
  Identity"; streams are separated per destination only. Apps you log in
  to identify you.
- Android checks for captive portals on its first start in a session
  before Antumbra's provisioning turns the check off; the check goes
  through Tor like everything else.
- No cameras inside Android (`camera.md`). The microphone is available,
  gated only by Android's own permission prompt.
- Android apps use Android's keyboard, not Phosh's on-screen keyboard.
  There is no clipboard sharing between Android and the host (Waydroid's
  clipboard needs `pyclip`, which Debian does not package).
- Apps can read the kernel release, which names the SoC and this port,
  and the CPU and GPU models (`threat-model.md`). The phone's own
  identifiers in sysfs and procfs are masked as far as Antumbra knows
  them, but which ones the phone has (its QFPROM fuse region, a settable
  or free-running RTC, factory partition GUIDs) is confirmed only on
  hardware (`hardware-validation.md`, item 55). Something plugged in
  while Android runs, such as a USB device with a serial number, is
  readable inside Android until Android is next started; something
  plugged in while it is stopped is masked at its next start. Analog
  values such as the battery's measured capacity are not masked.
- Android refuses to start rather than start without its Tor-only
  network or with a hardware identifier the container could read: the
  container's start-host hook checks the firewall, the bridge, the
  container's configuration and every mask, in the container's own view,
  at each start. `journalctl -t antumbra-waydroid` says what it found.
  Android stopped in a session stays stopped until the "Android"
  launcher starts it again.
- Cost (estimates, not measured on the phone): about 1.1 GB more to
  download and flash (2.4 GB uncompressed in the root filesystem; 0.8 GB
  for the VM's `arm64_only` images), and roughly 1 to 1.5 GB of RAM while
  Android runs, which is tight next to Tor Browser on the 8 GB model.
  Without Persistent Storage, installed apps and their data also live in
  RAM.
- Amnesic like the rest: apps and data are gone at shutdown unless "Keep
  Android apps and data" is on, which needs Persistent Storage and keeps
  Android's own usage history too. Turning it off later does not delete
  what is stored; Android's data stays on the volume, unused.
- Every session sets Android up again (`waydroid init`). Without
  Persistent Storage, Android also boots for the first time and F-Droid
  is installed again, which takes a while (unmeasured on the phone; under
  the VM's full emulation, Android's boot alone took about 22 minutes in
  the one run that completed it, where its timeouts were scaled by hand
  part-way through: `vm-testing.md`, "Android apps").
- Android's own timeouts: when system_server's Watchdog reaches its
  half-way mark, it asks for native stack dumps of vold and the HALs and
  gives each 2 seconds. A dump that takes longer kills the dumped process
  (SIGPIPE, when the requester gives up), and vold's death reboots
  Android, which stops the container until the "Android" launcher starts
  it again. This is Android's upstream behaviour. It kept Android from
  booting under the VM's full emulation, so in a virtual machine
  `antumbra-waydroid` scales Android's timeouts tenfold
  (`ro.hw_timeout_multiplier=10`, as emulators do; `vm-testing.md`,
  "Android apps"). The phone keeps Android's default timeouts, which
  have not been tested there (`hardware-validation.md`, item 56).
- Waydroid's AppArmor profiles run in complain mode, and while Android
  runs the GPU render node, DMA-BUF heaps and framebuffers are open to
  every local user.

## Build

- The kernel is validated to build with LLVM only (the port's recipe).
- The release includes the port's DTBO and vbmeta assets as-is; Antumbra
  cannot yet regenerate them.
- Without the builder's own firmware tree the image has no display
  acceleration, Wi-Fi or audio. With it, the firmware is in the image and
  in the release `release.sh` makes from it: such a release is for the
  builder's own phone only, as its manifest says (`legal.md`).
- Images built with `ANTUMBRA_LIBCAMERA_LOCAL=1` are not reproducible:
  libcamera signs its IPA modules with a key generated at each build
  (`camera.md`).
