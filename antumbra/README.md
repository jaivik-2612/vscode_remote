# Antumbra

An amnesic, Tor-enforcing mobile operating system for the OnePlus 7T Pro,
built from Debian 13 and the design of Tails.

Antumbra boots a read-only system from the phone's own storage, routes
every connection through Tor at the firewall, randomises the Wi-Fi
hardware address, keeps the cellular radio off, and forgets everything at
power-off unless you unlock an encrypted Persistent Storage.

Tails is a trademark of the Tails project; Tor is a trademark of The Tor
Project, Inc. Antumbra is an independent derivative endorsed by neither.

## Status: alpha, not yet booted on hardware

Everything in this repository was built and validated on a build machine:
the kernel builds from the mainline port's sources, the unattended
pipeline (`ANTUMBRA_MINIMAL=1 build/build.sh`) produces a root filesystem
whose firewall, Tor configuration, units and scripts pass their checks and
whose initramfs is proven free of network drivers, and the images come out
in the exact format the phone's bootloader validated for the mainline
port: the sparse userdata image expands to the full partition, its live
partition mounts, the squashfs hash matches and dm-verity verifies, and
the release directory passes `build/verify-release.sh`. The same system
also boots in QEMU (`make vm-build`, `make vm-test`, see
`docs/vm-testing.md`): from the initramfs to the Welcome screen, through
pressing Start to the Phosh session and Tor Browser, and back to the
initramfs at power-off, with the privacy properties checked on the way.
Further modes of the VM test cover the camera path on a virtual camera,
Android apps and Persistent Storage.
What has **not** happened yet is a boot on a physical OnePlus 7T Pro. `docs/hardware-validation.md` is the checklist
for that first boot. Treat this as a developer preview.

| Area | What you get |
|---|---|
| Base | Debian 13 "trixie" arm64, Phosh mobile shell, Linux 6.17 from the [hotdog mainline port](https://github.com/Sr-0w/hotdog-linux-bringup) |
| Tor enforcement | Tails' per-user firewall ported to nftables; Tails' torrc, control-port filter, namespaces, time sync |
| Amnesia | squashfs root + RAM overlay, dm-verity, zram-only swap, memory zeroing, return-to-initramfs shutdown |
| Radios | MAC spoofing per session, modem radio pinned to low-power, Bluetooth/NFC/GNSS off, no USB gadget |
| Session | Welcome screen (Persistent Storage, bridges, lock passphrase, admin, Android apps in images built with them), Tor Browser in its own network namespace |
| Interface | a dark theme close to Android 14's (Material Design 3 colours, Roboto, Material Symbols status icons), as far as Phosh allows without code changes |
| Cameras | GNOME Snapshot through the camera portal, PipeWire and libcamera's software ISP; the pop-up front camera rises while it streams; no OnePlus camera app |
| Android apps | optional (`ANTUMBRA_ANDROID=1`): Waydroid with LineageOS 20 (Android 13) and F-Droid, no Google apps, traffic only through Tor, off until turned on at the Welcome screen |
| Persistence | LUKS2/argon2id volume with Tails-style features (folder, Wi-Fi, GnuPG, SSH, and the Welcome settings, which are not read back yet; Android apps and data in images built with them) |

## Quick start (build machine: Debian/Ubuntu x86_64 or arm64, root for the root-filesystem steps)

```sh
cd antumbra
sudo apt-get install -y mmdebstrap debian-archive-keyring qemu-user-static binfmt-support arch-test \
    squashfs-tools e2fsprogs android-sdk-libsparse-utils systemd-repart zstd python3 \
    clang lld llvm make bc bison flex libssl-dev libelf-dev kmod cpio git curl gpg gpgv \
    cryptsetup-bin fastboot shellcheck nftables tor python3-pytest yamllint unzip openssl
make lint                       # static checks
build/fetch-sources.sh          # pinned kernel tree, patches, Tor Browser (verified)
build/kernel.sh                 # Image + modules + DTB (about an hour on 4 cores)
ANTUMBRA_ACCEPT_PROPRIETARY_FIRMWARE=1 build/fetch-firmware.sh   # your own device's firmware; read docs/legal.md
sudo env ANTUMBRA_FIRMWARE_DIR=build/cache/firmware build/rootfs.sh
sudo build/squashfs.sh
build/image.sh
build/bootimg.sh
build/release.sh
build/flash.sh --release build/out/release/antumbra-*-oneplus-hotdog
```

`docs/building.md` explains every step and knob; `docs/flashing.md` is
the on-device procedure with its backups and recovery paths. Two knobs
add optional parts: `ANTUMBRA_ANDROID=1` for `fetch-sources.sh` (which
then also fetches the Waydroid images and F-Droid) and `rootfs.sh` adds
Android apps; `ANTUMBRA_LIBCAMERA_LOCAL=1` for `rootfs.sh`, after `sudo
build/libcamera.sh`, installs the port's patched libcamera. An image
built with your device's firmware contains it, and so does the release
made from it: it is for your own phone only (`docs/legal.md`).

## Documents

- `docs/architecture.md`: the design, section by section, with what is validated and what is not
- `docs/vm-testing.md`: boot-testing the system in QEMU (`make vm-build`, `make vm-test`)
- `docs/threat-model.md`: what Antumbra protects against, what it does not
- `docs/device-oneplus-7t-pro.md`: the hardware, the port, the variants, the partitions
- `docs/camera.md`: the camera path, the pop-up front camera, who can use the cameras, and why there is no OnePlus camera app
- `docs/building.md`, `docs/flashing.md`, `docs/hardware-validation.md`
- `docs/tails-porting-map.md`: every Tails mechanism and where it went
- `docs/known-issues.md`, `docs/roadmap.md`, `docs/legal.md`, `docs/research-notes.md`

## Layout

```
build/                  build and flash scripts (bash), the QEMU launcher
device/                 the phone's pinned sources, kernel fragment and patches, libcamera pins,
                        boot-image contract; the QEMU test profile (qemu-virt/)
config/rootfs/          files installed over the Debian root filesystem
config/rootfs-android/  the Android-only part of those, installed only with ANTUMBRA_ANDROID=1
config/hooks/           scripts run inside the root filesystem at build time
config/packages/        package lists
tests/                  lint harness, package checker, unit tests, VM smoke test, pop-up motor
                        model and sleep test, Android network lab, OnePlus camera scanner
vendor/tails/           the Tails sources this derives from, with provenance
docs/
```

## Licence

GPL-3.0-or-later (see `LICENSE`). Files under `vendor/tails/` and those
derived from them are Tails' work under the same licence; the kernel
patches under `device/` are GPL-2.0. Device firmware is proprietary and is
never part of this repository; an image built with it is for your own
phone only (`docs/legal.md`).
