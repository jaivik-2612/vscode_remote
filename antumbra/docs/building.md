# Building Antumbra

## Build host

Any Debian 13 or Ubuntu 24.04 machine. On x86_64 the root-filesystem
steps run the arm64 Debian maintainer scripts under `qemu-user-static`
(about three times slower than native); a native arm64 host needs no
emulation. Root is required for `rootfs.sh`, `squashfs.sh` and the
optional `libcamera.sh` (chroots, file ownership); everything else runs
as a user.

```sh
sudo apt-get install -y mmdebstrap debian-archive-keyring qemu-user-static binfmt-support arch-test \
    squashfs-tools e2fsprogs android-sdk-libsparse-utils systemd-repart zstd python3 \
    clang lld llvm make bc bison flex libssl-dev libelf-dev kmod cpio git curl gpg gpgv \
    cryptsetup-bin fastboot shellcheck nftables tor python3-pytest yamllint unzip openssl
arch-test arm64        # must print "arm64: ok" on an x86_64 host
```

Disk: about 6 GB for the kernel tree and build, 4 GB for the root
filesystem, plus the images. Android apps (`ANTUMBRA_ANDROID=1`) add about
3.5 GB to the cache and 2.5 GB to the root filesystem.

## Steps

`build/build.sh` runs the steps below in order, all but `release`:
`libcamera` only with `ANTUMBRA_LIBCAMERA_LOCAL=1` (and not with
`ANTUMBRA_MINIMAL=1`), and no `bootimg` for the VM profile.
`build/build.sh STEP...` runs only the steps named (`build/build.sh
release` packages a release). Each script can also be run on its own and
is idempotent.

| Step | Script | Produces |
|---|---|---|
| fetch | `fetch-sources.sh` | `build/cache/`: kernel tree at the pinned commit, the port's 27 patches and config, avbtool and the mkbootimg tools, the port's DTBO and vbmeta, Tor Browser (SHA-256 and OpenPGP verified); with `ANTUMBRA_ANDROID=1` also the Waydroid images of the profile's variant (each zip pinned by SHA-256 and size, each extracted image by size, CRC-32 and SHA-256, checked again on every run, cached or not) and F-Droid (SHA-256, OpenPGP and APK certificate verified) |
| kernel | `kernel.sh` | `build/out/kernel/`: raw arm64 `Image`, DTB, stripped modules tarball, config, kernel release, ASLR sysctl values |
| libcamera (optional) | `libcamera.sh` (root) | only with `ANTUMBRA_LIBCAMERA_LOCAL=1`: `build/out/libcamera-repo/`, the port's patched libcamera 0.7.2 as arm64 packages in a local apt repository (`camera.md`) |
| rootfs | `rootfs.sh` (root) | `build/work/rootfs/` tree; `build/out/rootfs/initrd.img`, `packages.txt`, `build-flags` (what the tree was built with, below) and, with the builder's firmware, `firmware.sha256` (each firmware file with its SHA-256) |
| squashfs | `squashfs.sh` (root) | `filesystem.squashfs` (xz, arm BCJ), `.verity` hash tree, `.roothash`; `ANTUMBRA_VERITY` (1 or 0) added to `build-flags` |
| image | `image.sh` | `userdata.simg`: 4096-byte-sector GPT sized to the physical partition, live partition + empty Persistent Storage partition, as an Android sparse image |
| bootimg | `bootimg.sh` | `boot.img`: header v2, cmdline with the verity root hash, unsigned AVB footer, exactly 96 MiB |
| release | `release.sh` | `build/out/release/antumbra-<version>-oneplus-hotdog/` with checksums, manifest and optional minisign signature; checks `build-flags` first (below) |

`build-flags` records the device profile (`ANTUMBRA_DEVICE`), the debug,
minimal and Android knobs, whether the port's libcamera and the
builder's firmware were installed (`ANTUMBRA_LIBCAMERA_LOCAL` and
`DEVICE_FIRMWARE`, 1 or empty) and the kernel release
(`KERNEL_RELEASE`). `squashfs.sh` adds `ANTUMBRA_VERITY` (1 or 0),
replacing an earlier value, once the squashfs is complete.
`squashfs.sh`, `image.sh`, `bootimg.sh` and `release.sh` refuse a
missing `build-flags` or one for another profile. `bootimg.sh`, `vm.sh`
and `vm-bundle.sh` refuse an `ANTUMBRA_VERITY` other than the recorded
one and say which value to set; with no value recorded they go on, and
with dm-verity on they then need a root hash, which `rootfs.sh` and
`squashfs.sh` delete before they run. `release.sh` also refuses a debug
build, a kernel release other than `build/out/kernel`'s, a `build-flags`
that does not record whether the image has device firmware (one an older
`rootfs.sh` wrote: run the rootfs step again), `DEVICE_FIRMWARE=1`
without a `firmware.sha256` listing the files, and a `build-flags` with
no `ANTUMBRA_VERITY` (`squashfs.sh` has not completed on this tree: run
it, then `image.sh` and `bootimg.sh`). Its manifest has a dm-verity
line, `dm-verity: on` or `dm-verity: off (built with ANTUMBRA_VERITY=0;
the root filesystem is not verified at boot)`, says whether the images
contain device firmware, names a minimal build as such with what it
lacks, and mentions the port's libcamera and Android apps when they are
in the image.

What each step deletes before it runs:

- `rootfs.sh`, just before mmdebstrap: the old tree's `build-flags` and
  `firmware.sha256`, its initramfs, its squashfs
  (`filesystem.squashfs` and its `.verity`, `.roothash` and `.sha256`),
  the images built from them (`userdata.simg`, `vm-disk.img` and
  `boot.img`, each with its `.sha256`), then the tree itself. It writes
  `build-flags` again last, so if anything fails from the deletions on
  (mmdebstrap, a build hook, the initramfs) there is no `build-flags`
  and the steps after it refuse to go on. A run that fails before them,
  on a missing input for example, leaves the old tree and all of these
  as they were, still matching.
- `squashfs.sh`: the previous squashfs (with its `.verity`, `.roothash`
  and `.sha256`), the images built from it and the `ANTUMBRA_VERITY`
  record.
- `image.sh` and `bootimg.sh` replace only their own image, and
  `release.sh` deletes the release directory of the same version.

`rootfs.sh` does not install `config/rootfs` and `config/rootfs-android`
as they are checked out: it stages copies in `build/work/overlay/`, owned
by root, with 0755 directories and 0644 or 0755 files (by the execute
bit), without Python byte code, and with the modes git cannot record set
again (0440 for `etc/sudoers.d/*`, 0600 for `etc/usbguard/rules.conf` and
`etc/skel/.tor/control_auth_cookie`), and installs those. It copies the
firmware tree the same way, root-owned. So a checkout or firmware tree
owned by an ordinary user (often UID 1000, which is `amnesia` in the
image) passes neither its owner nor its umask's modes to the image.

Firmware is a separate, deliberate step: `fetch-firmware.sh` assembles the
proprietary blobs for **your** device from the community mirror the port
uses, verifies every file against the pinned hashes, and lays them out for
`/lib/firmware` in `build/cache/firmware/`; it prints a notice and stops
unless `ANTUMBRA_ACCEPT_PROPRIETARY_FIRMWARE=1` is set. Pass the result as
`ANTUMBRA_FIRMWARE_DIR` to `rootfs.sh`. Without it the image boots but
has no display acceleration, Wi-Fi or audio. With it, `rootfs.sh` records
the firmware in `build-flags` and `firmware.sha256`, and the release's
`MANIFEST.md` says that the userdata image contains proprietary device
firmware which Qualcomm and OnePlus do not license for redistribution,
that the release is for your own phone only and must not be published,
and lists the files with their hashes; `release.sh` also warns about it
when it finishes. See `docs/legal.md`.

## Knobs

| Variable | Effect |
|---|---|
| `ANTUMBRA_MINIMAL=1` | base + network + amnesia package lists only, no Phosh, apps or Tor Browser: validates the pipeline in a fraction of the time. Recorded in `build-flags`; the release manifest says that the build is a minimal one and what it lacks |
| `ANTUMBRA_ANDROID=1` | Android apps: Waydroid, the LineageOS 20 images of the profile's `WAYDROID_IMAGE_VARIANT` and F-Droid, off until turned on at the Welcome screen (`architecture.md`, section 11.1). Recorded in `build-flags` and the release manifest; not combinable with `ANTUMBRA_MINIMAL=1`. Without it the image has no Waydroid, Android images or Android services; the firewall's Android rules and the kernel's binder driver are there but unused (binder devices root-only) |
| `ANTUMBRA_DEBUG=1` | debug command line; in the VM profile also the root console, the virtual camera and its test tools (`vm-testing.md`); `release.sh` refuses to package such a build |
| `ANTUMBRA_VERITY=0` | no dm-verity hash tree and no root hash on the command line (empty or unset: dm-verity on); `squashfs.sh` records it in `build-flags`, `bootimg.sh`, `vm.sh` and `vm-bundle.sh` need the same value, and the release manifest states it (above) |
| `ANTUMBRA_FIRMWARE_DIR=DIR` | firmware tree to copy into `/lib/firmware`; recorded in `build-flags` and the release manifest (above) |
| `ANTUMBRA_KERNEL_TOOLCHAIN=gcc` | Debian cross GCC instead of LLVM (the port validates only LLVM) |
| `ANTUMBRA_KERNEL_ALLOW_CONFIG_DRIFT=1` | warn instead of fail when the config fragment is not fully honoured |
| `ANTUMBRA_LIBCAMERA_LOCAL=1` | build the port's patched libcamera 0.7.2 (`libcamera.sh`, about five minutes as a cross build on a 4-core x86-64 host) and install it instead of trixie-backports' 0.7.1; off by default, ignored with `ANTUMBRA_MINIMAL=1` (`camera.md`). Recorded in `build-flags` when installed; the release manifest then says that whoever distributes the build must also offer the patched libcamera source (`legal.md`) |
| `ANTUMBRA_SQUASHFS_MEM=SIZE` | cache size for `mksquashfs` (default `1G`, where its own default is a quarter of the host's memory); the image does not depend on it |
| `ANTUMBRA_SIGNING_KEY=FILE` | minisign secret key for `release.sh` |
| `SOURCE_DATE_EPOCH` | build timestamp (default: the last git commit) |
| `ANTUMBRA_CACHE`, `ANTUMBRA_OUT`, `ANTUMBRA_WORK` | relocate the cache, output and scratch directories |

## Reproducibility

Every input is pinned by hash in `device/oneplus-hotdog/sources.lock` and
the `.sha256` lists beside it (`kernel/port-patches.sha256`,
`firmware/firmware-files.sha256`, `libcamera/patches.sha256`). Timestamps
come from `SOURCE_DATE_EPOCH`, filesystem UUIDs and partition GUIDs are derived from
the version string, the squashfs and ext4 are built with fixed times, and
the package set can be pinned to a `snapshot.debian.org` timestamp
(`DEBIAN_SNAPSHOT` in the lock file). What still varies between builds:
Debian's packages when no snapshot is pinned, the live partition's
free-space layout if `mke2fs` changes between e2fsprogs versions, and,
with `ANTUMBRA_LIBCAMERA_LOCAL=1`, the libcamera packages, whose IPA
modules are signed with a key generated anew by each build.

## Testing in a VM

`ANTUMBRA_DEVICE=qemu-virt` builds the same system for QEMU's arm64 `virt`
machine (`make vm-build`, `make vm-run`, `make vm-test`); see
`docs/vm-testing.md`. Profiles live in `device/<name>/device.conf`; the VM
profile reuses the phone's sources, patches and hardening fragment.

## Checks before a release

```sh
make lint          # shellcheck, python, the pop-up motor's flag model, nftables syntax,
                   # Android's network lab, tor config, systemd units, yaml, phoc modes,
                   # no OnePlus camera software, pinned inputs, the staged overlays' modes
make test          # lint, unit tests and the headless Welcome screen self-test
sudo python3 -m pytest -q -p no:cacheprovider tests/unit/test_applier.py   # applier, as root
make check-packages
ANTUMBRA_MINIMAL=1 build/build.sh    # pipeline validation end to end
```

Git records only the modes 0644 and 0755, so `make lint` does not read
the checkout's modes: it stages both overlays as `rootfs.sh` does and
checks the copies (0440 for the sudoers files, 0600 for usbguard's rules
and the Tor control cookie, nothing group- or world-writable), and fails
if `rootfs.sh` syncs an overlay tree in from `config/` instead of the
staged copy.
A fresh clone passes without any `chmod`.

Some of these skip on a build host that cannot run them, and say so:
Android's network lab needs unprivileged user namespaces or root, and
the network and mount namespaces, bridge and veth drivers and nftables
features it uses (`vm-testing.md`); the Welcome settings applier's tests
need root, to run it in a mount namespace of their own; the self-test
needs GTK 4's and libadwaita's Python bindings and `xvfb-run`.

The minimal pipeline has been run unattended on an x86-64 build host
(arm64 under qemu-user binfmt): every hook, the initramfs check
(`80-base-initramfs.sh`), the squashfs and verity step, the sparse image,
the boot image and the release checksums completed, and the resulting live
partition was mounted and its squashfs and verity tree verified. The
kernel step was validated with LLVM 18 on the same host.

The CI workflow (`.github/workflows/antumbra.yml`) runs the lint and unit
tests (the applier's again as root), the Welcome screen self-test and the
package check on every push, assembles a boot image with the pinned
tools from a placeholder kernel, initramfs and build stamps (dm-verity
off), and on manual dispatch builds the kernel and a minimal root
filesystem on a native arm64 runner.
