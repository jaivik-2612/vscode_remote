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
the kernel builds from the mainline port's sources, the root filesystem
builds and its firewall, Tor configuration, units and scripts pass their
checks, and the images come out in the exact format the phone's bootloader
validated for the mainline port. What has **not** happened yet is a boot on
a physical OnePlus 7T Pro. `docs/hardware-validation.md` is the checklist
for that first boot. Treat this as a developer preview.

| Area | What you get |
|---|---|
| Base | Debian 13 "trixie" arm64, Phosh mobile shell, Linux 6.17 from the [hotdog mainline port](https://github.com/Sr-0w/hotdog-linux-bringup) |
| Tor enforcement | Tails' per-user firewall ported to nftables; Tails' torrc, control-port filter, namespaces, time sync |
| Amnesia | squashfs root + RAM overlay, dm-verity, zram-only swap, memory zeroing, return-to-initramfs shutdown |
| Radios | MAC spoofing per session, modem radio pinned to low-power, Bluetooth/NFC/GNSS off, no USB gadget |
| Session | Welcome screen (Persistent Storage, bridges, lock passphrase, admin), Tor Browser in its own network namespace |
| Persistence | LUKS2/argon2id volume with Tails-style features (folder, settings, Wi-Fi, bridges, GnuPG, SSH, dotfiles) |

## Quick start (build machine: Debian/Ubuntu x86_64 or arm64, root for the root-filesystem steps)

```sh
cd antumbra
sudo apt-get install -y mmdebstrap debian-archive-keyring qemu-user-static binfmt-support arch-test \
    squashfs-tools e2fsprogs android-sdk-libsparse-utils systemd-repart zstd python3 \
    clang lld llvm make bc bison flex libssl-dev libelf-dev kmod cpio git curl gpg gpgv \
    mkbootimg cryptsetup-bin fastboot
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
the on-device procedure with its backups and recovery paths.

## Documents

- `docs/architecture.md`: the design, section by section, with what is validated and what is not
- `docs/threat-model.md`: what Antumbra protects against, what it does not
- `docs/device-oneplus-7t-pro.md`: the hardware, the port, the variants, the partitions
- `docs/building.md`, `docs/flashing.md`, `docs/hardware-validation.md`
- `docs/tails-porting-map.md`: every Tails mechanism and where it went
- `docs/known-issues.md`, `docs/roadmap.md`, `docs/legal.md`, `docs/research-notes.md`

## Layout

```
build/            build and flash scripts (bash)
device/           pinned sources, kernel fragment and patches, boot-image contract
config/rootfs/    files installed over the Debian root filesystem
config/hooks/     scripts run inside the root filesystem at build time
config/packages/  package lists
tests/            lint harness, package checker, unit tests
vendor/tails/     the Tails sources this derives from, with provenance
docs/
```

## Licence

GPL-3.0-or-later (see `LICENSE`). Files under `vendor/tails/` and those
derived from them are Tails' work under the same licence; the kernel
patches under `device/` are GPL-2.0. Device firmware is proprietary and is
never part of this repository or of a published image.
