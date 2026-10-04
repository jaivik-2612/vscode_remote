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

## No warranty

Antumbra is alpha software for a single phone model that has not yet been
booted on hardware by its authors. Flashing it can render a phone
unbootable until restored with the OnePlus MSM Download Tool. Nothing here
is legal advice.
