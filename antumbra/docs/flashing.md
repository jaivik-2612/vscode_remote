# Flashing Antumbra onto a OnePlus 7T Pro

Read all of this first. The procedure replaces the phone's `userdata`
partition and the boot images of one A/B slot: the slot Android is *not*
running from. It follows what the hotdog mainline port validated on
hardware. Antumbra itself has not yet been booted on a phone by its
authors: expect problems, and use a phone you can afford to restore.

A step-by-step guide to the same procedure for Windows, macOS and Linux,
written for non-experts, is `docs/antumbra-install-guide.pdf` in the
repository.

## Before you start

- **Device**: OnePlus 7T Pro **HD1913** (European). The Indian HD1911 and
  the North American HD1917 run the same software line but have never
  booted the complete mainline port; the T-Mobile 7T Pro 5G McLaren
  (HD1925) is a different phone and is not supported. Check the model on
  the label or the box: Settings can show `HD1911` on a phone that once
  ran LineageOS, and `fastboot getvar product` says `msmnile` on the
  OnePlus 7 Pro and 7T as well. `flash.sh` also checks every partition
  size.
- **OxygenOS 12, build F.22, in both slots**: Antumbra runs on the
  bootloader, TrustZone and modem firmware of its own slot, and the port
  validated F.22's (the vbmeta asset is F.22's). An A/B update writes only
  the slot Android is not running from, so after updating to F.22 the
  other slot, Antumbra's, still holds the previous build. Therefore:
  update to F.22 (OxygenOS 12: Settings, About device, the version card;
  OxygenOS 10 and 11: Settings, System, System updates), restart, then install
  the F.22 full package once more with a local install (the full package
  as the Oxygen Updater app downloads it; on OxygenOS 12 the *Local
  install* entry is in the menu of Settings, About device, Up to date,
  once Developer options are on). Check with `adb shell getprop
  ro.boot.slot_suffix` before and after: the second install moves
  Android to the other slot and leaves F.22 in both. Whether OxygenOS
  accepts installing the build it already runs is unverified; if it
  refuses, Antumbra runs on the previous build's chain, which nobody has
  tested. After the last install, restart Android once more and wait:
  OxygenOS 12 updates with Virtual A/B, and fastbootd refuses `userdata`
  while an update is still being merged.
- **Android's slot, written down**: `fastboot getvar current-slot` before
  the first install names Android's slot. Antumbra's slot `X` is always
  the other letter, on the first install, on a retry after a failed boot
  and on every update. After the first install `current-slot` names
  Antumbra's slot, so it can no longer tell you which one is Android's.
- **Bootloader unlocked**: Developer options (tap *Build number* seven
  times), turn on *OEM unlocking* and *USB debugging*, then from the
  bootloader `fastboot oem unlock` and confirm on the phone with the
  volume and power keys. This erases the phone. A warning that the
  bootloader is unlocked then shows at every boot; it is expected and
  permanent. Do not lock the bootloader again while Antumbra is installed.
- **A recovery that offers fastbootd** must be in the active slot (stock
  OxygenOS recovery, which Android needs anyway, or LineageOS recovery).
  `fastboot reboot fastboot` must land in fastbootd. Flashing `userdata`
  from the bootloader instead of fastbootd stalls on this device and must
  not be attempted.
- **Everything in `userdata` is destroyed**: Android's user data and any
  existing Antumbra Persistent Storage. Back up what you need.
- **Device firmware**: the images contain none (`legal.md`). At every boot
  Antumbra reads the signed firmware the mainline drivers need (audio and
  modem DSPs, Wi-Fi, Bluetooth, the GPU's zap shader) from the phone's own
  partitions, read-only: `modem` and `bluetooth` of the slot it booted,
  and `vendor` inside `super` (`architecture.md`, "Device firmware from
  the phone"). A phone whose partitions were wiped or replaced by another
  system has no Wi-Fi under Antumbra.
- **Never send commands to a device that enumerates as 05c6:9008 or
  05c6:900e** (Qualcomm EDL) unless you are deliberately using the MSM
  Download Tool.

## Files

A release contains:

| File | Partition | Origin |
|---|---|---|
| `antumbra-<v>-oneplus-hotdog-boot.img` (100663296 bytes) | `boot_<slot>` | built by Antumbra |
| `antumbra-<v>-oneplus-hotdog-userdata.simg` | `userdata` (fastbootd) | built by Antumbra |
| `antumbra-<v>-oneplus-hotdog-dtbo.img` (25165824 bytes) | `dtbo_<slot>` | hotdog-linux-bringup release, hash-pinned |
| `antumbra-<v>-oneplus-hotdog-vbmeta-disabled.img` (65536 bytes) | `vbmeta_<slot>` | hotdog-linux-bringup release, hash-pinned |
| `SHA256SUMS`, optionally `SHA256SUMS.minisig` | | |
| `MANIFEST.md` (the build, its pinned inputs and packages, and whether the userdata image holds device firmware), `INSTALL.md` (this document) | | built by Antumbra |

Never mix files of different releases: the boot image's command line
names the userdata image's file systems.

A userdata image larger than 1900 MiB comes in pieces,
`antumbra-<v>-oneplus-hotdog-userdata.simg.part000`, `.part001` and so on
(GitHub release files must be under 2 GiB); `flash.sh` joins them
itself, and `MANIFEST.md` gives the SHA-256 of the joined image. Releases
up to 0.1.0-alpha.1 shipped the image zstd-compressed (`.simg.zst`,
possibly in `.part` pieces too); `flash.sh` still accepts those, and by
hand they need `zstd -d` after joining.

Verify first (Linux; on macOS `shasum -a 256 -c SHA256SUMS`, on Windows
`certutil -hashfile <file> SHA256` for each file):

```sh
build/verify-release.sh antumbra-<v>-oneplus-hotdog [minisign-public-key]
```

## The guided script (Linux)

`flash.sh` and `verify-release.sh` are in the repository, not in the
release: clone it and check out the release's tag (`antumbra-v<v>`).

```sh
build/flash.sh --release antumbra-<v>-oneplus-hotdog --android-slot <Android's slot>
```

It checks the device identity, the unlocked state and every partition
size, and needs to know Android's slot: `--android-slot` with the letter
you noted, or the record it keeps per phone (by serial number, in
`~/.local/share/antumbra/`) after a run on this computer, or
`--first-install`, which takes the current slot when the phone runs
Android (refused unless that slot has booted successfully). Without any
of them it stops rather than guess: once Antumbra is installed, nothing
the phone reports tells its slot from Android's. `--update` says the
phone runs Antumbra now. Antumbra goes into the other slot, never
Android's; the script shows both slots' boot state and asks you to type
the target slot's letter. Before writing anything it
starts fastbootd once to make sure it works and that no OxygenOS update
is pending. It then flashes the slot's vbmeta, dtbo and boot images from
the bootloader, writes `userdata` from fastbootd in bounded 128 MiB
transfers, makes the slot active and reboots. `--dry-run` prints the
commands instead.

There is no backup step: this phone's bootloader and stock fastbootd do
not support `fastboot fetch`, and none is needed, because Android's own
slot is never written (`--backup` tries `fetch` on bootloaders that have
it).

## By hand

Below, `X` is Antumbra's slot: the letter that is not Android's (see
"Before you start"). On the first install `current-slot` names Android's
slot: `a` means `X=b`, `b` means `X=a`.

```sh
fastboot devices
fastboot getvar unlocked         # yes
fastboot getvar current-slot     # first install: Android's slot; X is the other
fastboot reboot fastboot
fastboot getvar is-userspace     # yes: fastbootd works
fastboot getvar snapshot-update-status   # none (if it says snapshotted or merging: stop, see above)
fastboot reboot bootloader
fastboot flash vbmeta_X antumbra-<v>-oneplus-hotdog-vbmeta-disabled.img
fastboot flash dtbo_X   antumbra-<v>-oneplus-hotdog-dtbo.img
fastboot flash boot_X   antumbra-<v>-oneplus-hotdog-boot.img
fastboot reboot fastboot
fastboot getvar is-userspace     # yes
cat antumbra-<v>-oneplus-hotdog-userdata.simg.part* > antumbra-<v>-oneplus-hotdog-userdata.simg   # only if it came in pieces
fastboot -S 128M flash userdata antumbra-<v>-oneplus-hotdog-userdata.simg
fastboot reboot bootloader
fastboot set_active X
fastboot reboot
```

The first boot takes longer. The bootloader counts boot attempts, but
do not count on it falling back to Android's slot when they run out: the
port saw it stay on the failed slot (a red error screen) or fall back to
an unusable one. If the phone does not reach Antumbra's Welcome screen,
hold Power and Volume Up for about ten seconds to switch it off, start
the bootloader with Power, Volume Up and Volume Down, and either try
again (`fastboot set_active X`, which restores the attempts) or go back
to Android (below).

## Updating

Version 1 updates are full re-flashes of the boot image and `userdata`
into Antumbra's slot. They erase Persistent Storage: export it first
(copy `~/Persistent` and anything else you need to an encrypted external
medium), flash, recreate. In-place updates that keep the Persistent
Storage partition are on the roadmap.

An update goes into the same slot `X`, the one that is not Android's.
Once the phone has started Antumbra (or only tried to), `fastboot getvar
current-slot` names Antumbra's slot, not Android's: do not pick "the
other one" again, which would overwrite Android's. `flash.sh` remembers
Android's slot per phone on the computer that ran it, and without that
record asks for `--android-slot`.

## Going back to Android

Android's own slot was never written, so:

1. From the bootloader: `fastboot set_active <Android's slot>` (the
   `current-slot` you noted before installing).
2. Start the recovery (in the bootloader's menu, choose *Recovery mode*
   with the volume keys and confirm with Power) and run its factory reset
   (the option that wipes or formats data), so `userdata` is created
   again for Android. Without it Android finds Antumbra's `userdata` and
   formats it itself.
3. Android starts as it was before, minus its data. Antumbra's images stay
   in the other slot, where they do no harm, until an OxygenOS update
   rewrites that slot.
4. If anything is wrong, the OnePlus MSM Download Tool for your exact
   variant restores the phone to stock from EDL mode (Windows only; it
   erases everything and locks the bootloader again).
