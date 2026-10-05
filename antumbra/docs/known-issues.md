# Known issues and gaps

Version 0.1.0-alpha.1. Everything here is as of the state of the mainline
port in August 2026 and of this repository; see `roadmap.md` for plans.

## Not yet validated on hardware

Nothing in this repository has booted on a physical OnePlus 7T Pro yet.
`hardware-validation.md` lists what to confirm first: boot, display,
touch, the Welcome screen under bare phoc, Wi-Fi with the modem in
low-power mode, the self-check, Tor bootstrap, shutdown behaviour.

## Hardware

- 90 Hz display mode is disabled (DSI transport errors on the port).
- Earpiece, headset and most microphone routes do not work on the port;
  the internal speakers and handset microphone do.
- Charging from USB hosts may be limited to the USB default (around
  500 mA) because Antumbra configures no USB gadget; dedicated chargers
  are unaffected. Warp charging is unsupported by the port.
- Bluetooth is off by default and has no opt-in flow yet.
- Sensors (rotation, light, proximity) are not available: the sensor DSP
  is disabled. There is no automatic screen rotation.
- Fingerprint unlock will never work on mainline.

## Software

- Tor Browser is the 16.0 **alpha** channel build, the only official
  Linux arm64 build. Tor Project advises people at risk not to rely on
  alphas. It runs without an AppArmor profile (network isolation comes
  from its namespace and the firewall, as before).
- Four AppArmor profiles shipped by Debian do not parse with AppArmor 4.1
  ("merged rule with conflicting x modifiers"): plasmashell, pidgin, totem
  and papers. The build sets them aside, so the installed document viewer
  Papers runs unconfined, as it would have anyway.
- Tor Browser is a desktop browser on a phone screen: usable with the
  compositor's 3x scale, not adapted.
- No Unsafe Browser (captive portals cannot be handled from the device
  yet).
- No Tor Connection assistant: bridges are entered on the Welcome screen
  or with `antumbra-tor-connect`; no QR code or Moat.
- The Welcome screen passes the Persistent Storage passphrase to the
  root-side applier through a 0600 file in a tmpfs owned by the greeter
  user, not over D-Bus as Tails' `tps` does.
- Persistent Storage features are bind mounts without Tails' `nosymfollow`
  protection, and OS updates erase the volume (full re-flash).
- Audio routing uses Debian's generic ALSA UCM profiles, not the port's
  device-specific ones; sound may need manual mixer settings.
- `htpdate` time synchronisation needs Tor to bootstrap first; the
  pre-Tor clock fix from Tails (captive-portal `Date` header) is not
  wired to a user prompt.
- Screen lock without a passphrase is not protective; the Welcome screen
  says so but does not force one.

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

## Build

- The kernel is validated to build with LLVM only (the port's recipe).
- The release includes the port's DTBO and vbmeta assets as-is; Antumbra
  cannot yet regenerate them.
- Without the builder's own firmware tree the image has no display
  acceleration, Wi-Fi or audio.
