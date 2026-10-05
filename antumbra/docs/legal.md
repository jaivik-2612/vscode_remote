# Legal notes

## Licences

- Antumbra's own files: GPL-3.0-or-later (`LICENSE`).
- `vendor/tails/` and the files derived from it under `config/rootfs/`:
  Tails, GPL-3.0-or-later. Tails is a trademark of the Tails project;
  Antumbra is not Tails and is not endorsed by it.
- Kernel sources: GPL-2.0 (Linux, the sm8150-mainline tree, the
  hotdog-linux-bringup patches by Robin Snyders, and Antumbra's patch under
  `device/oneplus-hotdog/kernel/patches/`).
- The hotdog-linux-bringup tooling and documentation this project
  learned from: GPL-2.0.
- `avbtool.py`, fetched at build time from AOSP: Apache-2.0 (MIT-style
  notice in the file).
- Tor Browser, fetched at build time: Mozilla Public License 2.0 and the
  Tor licence; Tor and Tor Browser are trademarks of The Tor Project, Inc.,
  which does not endorse Antumbra.
- Debian packages: their respective licences, recorded in
  `/usr/share/doc/*/copyright` inside the image.
- The optional libcamera rebuild (`ANTUMBRA_LIBCAMERA_LOCAL=1`,
  `camera.md`): libcamera is LGPL-2.1-or-later (its tools GPL-2.0-or-later),
  rebuilt from Debian's source package with the hotdog-linux-bringup
  libcamera patches and tuning files. Debian does not publish that
  modified source, so whoever distributes an image built with it must also
  offer the source: the files in `build/cache/libcamera/` and
  `device/oneplus-hotdog/libcamera/`. Default images do not contain it.
- The interface theme: the stylesheets and gesture pill in
  `config/rootfs/usr/share/antumbra/theme/` and the wallpapers in
  `config/rootfs/usr/share/backgrounds/antumbra/` are Antumbra's own work,
  GPL-3.0-or-later. Their colour values were computed once with Google's
  material-color-utilities (Apache-2.0); only the resulting numbers are
  used, the library is not distributed.
- Roboto, the interface font (Debian package `fonts-roboto-unhinted`):
  Apache-2.0.
- The status icons in `config/rootfs/usr/share/icons/Antumbra/`: Material
  Symbols by Google, Apache-2.0, taken from the npm package
  `@material-symbols/svg-400` 0.47.6 (pinned by hash). The Apache-2.0 text
  ships beside them, and `SOURCES` there lists every file with its upstream
  name and hashes and marks the three that were changed (a colour class
  added to the low-battery icons).

The interface follows Google's published Material Design 3 guidelines in
style only. Antumbra uses no Google brand names or assets for it: no
"Material You", Pixel or Google Sans names, fonts or logos.

## Firmware

The phone needs proprietary firmware for its GPU, Wi-Fi, Bluetooth, DSPs,
modem and video engine. Qualcomm and OnePlus do not license it for
redistribution. Consequently:

- Antumbra never commits firmware to this repository and never includes it
  in a published image. `release.sh` packages only what the build
  produced from free sources plus two hash-pinned device-tree/vbmeta
  assets from the port's public release.
- `build/fetch-firmware.sh` assembles the firmware for the builder's own
  device from a community mirror that the mainline port also uses. It
  prints a notice and requires `ANTUMBRA_ACCEPT_PROPRIETARY_FIRMWARE=1`.
  Using firmware extracted for the device you own is generally treated as
  use of the software that came with the device; redistributing the
  resulting image is not. Builders who publish images must strip the
  firmware or obtain a licence.
- The sensor DSP firmware and the per-unit calibration data from the
  phone's `persist` partition are not used at all.

## OnePlus software

Antumbra contains, downloads and installs no OxygenOS component, in
particular not the OnePlus camera app: the OxygenOS licence allows its use
only on a OnePlus device and forbids making it available to anyone
(sections 2.2(a) and 3(g)), and the app bundles other companies'
proprietary libraries. It would not work on mainline Linux anyway
(`camera.md`). `tests/no-oneplus-camera.py` checks the source tree and the
image for it.

## No warranty

Antumbra is alpha software for a single phone model that has not yet been
booted on hardware by its authors. Flashing it can render a phone
unbootable until restored with the OnePlus MSM Download Tool. Nothing here
is legal advice.
