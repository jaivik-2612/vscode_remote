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
- The pop-up front camera has no drop protection. OxygenOS retracts it
  when the phone falls, on a signal from the sensor DSP, which Antumbra
  disables; mainline offers no free-fall sensor either. Do not keep the
  selfie camera open while walking, and do not push a raised camera down
  by hand: the driver reads the Hall sensors only while the motor moves,
  so it does not follow a push, and the push loads the idle gear train.
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

## Build

- The kernel is validated to build with LLVM only (the port's recipe).
- The release includes the port's DTBO and vbmeta assets as-is; Antumbra
  cannot yet regenerate them.
- Without the builder's own firmware tree the image has no display
  acceleration, Wi-Fi or audio.
