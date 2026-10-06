# Roadmap

In order of importance.

1. **First boot on hardware** and the fixes it will need
   (`hardware-validation.md`).
2. **Modem policy evidence**: confirm on this firmware that
   `persistent-low-power` is accepted from the boot-time state, survives a
   modem restart, and that a low-power modem does not answer emergency
   camping. Measure the battery cost versus a stopped modem (which would
   cost Wi-Fi).
3. **Welcome screen hardening**: pass the Persistent Storage passphrase
   over a root D-Bus service (the Tails `tps` model) instead of a file;
   adopt Tails' `nosymfollow` bind-mount protection; an "export my
   Persistent Storage" flow before updates.
4. **In-place updates** that keep Persistent Storage: write the new live
   partition and boot image from the running system to the inactive
   slot, mark success with `qbootctl` only after a good boot.
5. **Tor Connection assistant** on the phone: bridge QR codes, Moat,
   the pre-Tor clock fix with user consent, as in Tails.
6. **Tor Browser confinement**: an AppArmor profile for the launcher and
   the browser, and Tails' Flatpak-based sandbox when it is portable. The
   profile must deny the camera devices (`/dev/video*`, `/dev/media*`,
   `/dev/v4l-subdev*`), the PipeWire socket, and the browser's session-bus
   calls to the camera portal (`org.freedesktop.portal.Camera`) and to the
   portal's permission store (`org.freedesktop.impl.portal.PermissionStore`),
   or allow the session bus only for the names the browser needs: the
   portal hands out connected PipeWire file descriptors, which no device
   or socket rule sees. Until then the browser can use the cameras without
   a prompt (`camera.md`).
7. **Unsafe Browser** for captive portals, in the clearnet namespace.
8. **Bluetooth opt-in session** with a random address before power-on
   (the driver stack works on the 6.17 line).
9. **Audio**: the port's UCM profiles for the TFA9874 amplifiers.
10. **Sensors**: evaluate shipping Debian unstable's iio-sensor-proxy with
    the SSC backend behind a polkit gate, if the SLPI firmware can be
    obtained by the user.
11. **Verified boot research**: whether any OnePlus bootloader path allows
    a custom AVB key; otherwise document and move on.
12. **Reproducible releases** pinned to `snapshot.debian.org`, with
    published build attestations.
13. **Second device**: the OnePlus 7 Pro (`guacamole`, same SoC) once its
    mainline status is comparable.
14. **Android apps** (experimental, `ANTUMBRA_ANDROID=1`): validation on
    the phone; Waydroid's AppArmor profiles in enforce mode; binder for
    Android only (not every local user); `.onion` and per-app Tor
    isolation inside Android; pinning the extracted images' hashes; newer
    images when Waydroid publishes them.
