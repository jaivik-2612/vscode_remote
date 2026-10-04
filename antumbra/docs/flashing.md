# Flashing Antumbra onto a OnePlus 7T Pro

Read all of this first. The procedure replaces the phone's `userdata`
partition and slot B. It follows, step for step, what the hotdog mainline
port validated on hardware.

## Before you start

- **Device**: OnePlus 7T Pro **HD1913** (European). The Indian HD1911 and
  the T-Mobile HD1925 have never booted the complete mainline port.
  `fastboot getvar product` must say `msmnile`.
- **Bootloader unlocked** (OnePlus: OEM unlocking in Developer options,
  then `fastboot oem unlock`; this wipes the phone). The orange
  "device has been unlocked and can't be trusted" screen at every boot is
  expected and permanent.
- **Firmware baseline**: the port's images were validated on top of
  OxygenOS 12 firmware (the vbmeta asset derives from OxygenOS 12 F.22).
  If the phone runs older firmware, update it to the last OxygenOS 12 build
  first.
- **A recovery that offers fastbootd** must be in the active slot
  (stock OxygenOS recovery or LineageOS recovery). `fastboot reboot
  fastboot` must land in fastbootd; if it does not, install a compatible
  recovery first. Flashing `userdata` from the bootloader instead of
  fastbootd stalls on this device and must not be attempted.
- **Everything in `userdata` is destroyed**: Android's user data and any
  existing Antumbra Persistent Storage. Export what you need.
- **Slot A is not a safe way back to Android**: it keeps Android's boot and
  recovery, but booting the Android *system* there will detect the foreign
  `userdata` and format it, erasing Antumbra and its Persistent Storage.
  The way back is the backup made below (restoring `boot_b`, `dtbo_b`,
  `vbmeta_b`) plus a fresh Android `userdata`, or the OnePlus MSM Download
  Tool (EDL mode, Vol Up + Vol Down + USB; wipes everything and relocks).
- **Never send commands to a device that enumerates as 05c6:9008 or
  05c6:900e** (Qualcomm EDL) unless you are deliberately using the MSM tool.

## Files

A release directory contains:

| File | Partition | Origin |
|---|---|---|
| `antumbra-<v>-boot.img` (100663296 bytes) | `boot_b` | built by Antumbra |
| `antumbra-<v>-userdata.simg[.zst]` | `userdata` (fastbootd) | built by Antumbra |
| `antumbra-<v>-dtbo.img` (25165824 bytes) | `dtbo_b` | hotdog-linux-bringup release, hash-pinned |
| `antumbra-<v>-vbmeta-disabled.img` (65536 bytes) | `vbmeta_b` | hotdog-linux-bringup release, hash-pinned |
| `SHA256SUMS`, optionally `SHA256SUMS.minisig` | | |

Verify first:

```sh
build/verify-release.sh antumbra-<v>-oneplus-hotdog [minisign-public-key]
```

## The guided script

```sh
build/flash.sh --release antumbra-<v>-oneplus-hotdog
```

It checks the device identity, the unlocked state and every partition
size, backs up `boot_b`, `dtbo_b` and `vbmeta_b` with `fastboot fetch`
into `./antumbra-backup-<date>/`, flashes the three slot-B images from
the bootloader, reboots into fastbootd, writes `userdata` in bounded
128 MiB transfers, makes slot B active and reboots. `--dry-run` prints
the commands instead. Keep the backup directory.

## By hand

```sh
fastboot devices
fastboot getvar product          # msmnile
fastboot getvar unlocked         # yes
fastboot fetch boot_b boot_b.img && fastboot fetch dtbo_b dtbo_b.img && fastboot fetch vbmeta_b vbmeta_b.img
fastboot flash vbmeta_b antumbra-<v>-vbmeta-disabled.img
fastboot flash dtbo_b   antumbra-<v>-dtbo.img
fastboot flash boot_b   antumbra-<v>-boot.img
fastboot reboot fastboot
fastboot getvar is-userspace     # yes
zstd -d antumbra-<v>-userdata.simg.zst
fastboot -S 128M flash userdata antumbra-<v>-userdata.simg
fastboot reboot bootloader
fastboot set_active b
fastboot reboot
```

The first boot takes longer. The bootloader counts boot attempts: if the
system never reaches its services, after seven attempts the phone falls
back to slot A (which will offer recovery, and will format `userdata` if
you let Android start).

## Updating

Version 1 updates are full re-flashes of `boot_b` and `userdata`. They
erase Persistent Storage: export it first (copy `~/Persistent` and
anything else you need to an encrypted external medium), flash, recreate.
In-place updates that keep the Persistent Storage partition are on the
roadmap.

## Going back to Android

1. From fastboot: `fastboot flash boot_b boot_b.img`, `fastboot flash
   dtbo_b dtbo_b.img`, `fastboot flash vbmeta_b vbmeta_b.img` from your
   backup, then `fastboot set_active a` (or `b`, whichever held Android).
2. Boot the Android recovery and perform a factory reset so `userdata` is
   re-created for Android.
3. If anything is wrong, the OnePlus MSM Download Tool for your exact
   variant restores the phone to stock from EDL mode.
