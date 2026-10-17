# Legal notes

## Licences

- Antumbra's own files: GPL-3.0-or-later (`LICENSE`).
- `vendor/tails/` and the files derived from it under `config/rootfs/`:
  Tails, GPL-3.0-or-later. Tails is a trademark of the Tails project;
  Antumbra is not Tails and is not endorsed by it.
- Kernel sources: GPL-2.0 (Linux, the sm8150-mainline tree, the
  hotdog-linux-bringup patches by Robin Snyders, and Antumbra's patches
  under `device/oneplus-hotdog/kernel/patches/` and device-tree overrides
  in `device/oneplus-hotdog/kernel/`).
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
  `device/oneplus-hotdog/libcamera/`. The manifest `release.sh` writes for
  such a build says so. Default images do not contain it.
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

## Android apps

Only images built with `ANTUMBRA_ANDROID=1` contain these (`building.md`).

- Waydroid (Debian package `waydroid`, from trixie-backports):
  GPL-3.0-or-later. Antumbra changes it at build time with
  `config/rootfs-android/usr/share/antumbra/patches/waydroid-no-video.diff`
  (GPL-3.0-or-later, like Waydroid) and edits its LXC configuration
  templates in `config/hooks/56-session-android.sh`; both are in this
  repository, and Waydroid's own source is Debian's source package.
- The Android system and vendor images: LineageOS 20 builds published by
  the Waydroid project on its update channel, fetched at build time,
  pinned by hash and installed unmodified. They are built from LineageOS
  (<https://github.com/LineageOS>) and Waydroid's device and vendor trees
  (<https://github.com/waydroid>). Most of Android is Apache-2.0; the
  images also contain components under the GPL, LGPL, BSD and MIT
  licences, listed in Android's own legal notices inside the images.
  Antumbra has not audited those notices, so the following is an
  inference: whoever distributes a built image with these images in it
  redistributes those binaries and takes on their obligations, for the
  GPL parts the corresponding source at the matching revisions. Builders
  who publish such images must provide it or point to it as those
  licences allow; `release.sh` notes in the manifest that the build
  includes them.
- F-Droid, the app store installed into Android: GPL-3.0-or-later,
  fetched from f-droid.org at build time and checked against F-Droid's
  OpenPGP signature and APK signing certificate. Apps installed from
  F-Droid later come under their own licences, which F-Droid lists.
- No Google components: Antumbra uses only the images without Google
  apps (`VANILLA`), installs no Google Play services or microG, and uses
  nothing from OxygenOS. Android is a trademark of Google LLC. Antumbra is
  not endorsed by Google, LineageOS, Waydroid or F-Droid; Android inside
  Antumbra reports Waydroid's generic product names, which are Waydroid's
  own.

## Firmware

The phone needs proprietary firmware for its GPU, Wi-Fi, Bluetooth, DSPs,
modem and video engine. Qualcomm and OnePlus do not license it for
redistribution. Consequently:

- Antumbra never commits firmware to this repository and never includes it
  in a published image. On the phone, `antumbra-phone-firmware` reads the
  firmware at every boot from the phone's own partitions (the copies
  OxygenOS itself uses), read-only, and keeps it in RAM: nothing is
  redistributed, and nothing of it is written anywhere. The one file it
  writes that the phone does not have, ath10k's `firmware-5.bin`, holds no
  code, only 60 bytes of feature flags that Antumbra generates.
- `release.sh` packages the images the build
  produced plus two hash-pinned device-tree/vbmeta assets from the port's
  public release. An image built with `ANTUMBRA_FIRMWARE_DIR` carries the
  builder's firmware in its root filesystem, and `release.sh` packages it
  all the same: its manifest then says that the userdata image contains
  proprietary device firmware which Qualcomm and OnePlus do not license
  for redistribution, that the release is for the builder's own phone
  only and must not be published, and lists the firmware files with their
  SHA-256, and `release.sh` warns about it when it finishes.
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
