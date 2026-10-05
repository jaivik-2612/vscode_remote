# Building Antumbra

## Build host

Any Debian 13 or Ubuntu 24.04 machine. On x86_64 the root-filesystem
steps run the arm64 Debian maintainer scripts under `qemu-user-static`
(about three times slower than native); a native arm64 host needs no
emulation. Root is required for `rootfs.sh` and `squashfs.sh` (chroots,
file ownership); everything else runs as a user.

```sh
sudo apt-get install -y mmdebstrap debian-archive-keyring qemu-user-static binfmt-support arch-test \
    squashfs-tools e2fsprogs android-sdk-libsparse-utils systemd-repart zstd python3 \
    clang lld llvm make bc bison flex libssl-dev libelf-dev kmod cpio git curl gpg gpgv \
    cryptsetup-bin fastboot shellcheck nftables tor python3-pytest yamllint
arch-test arm64        # must print "arm64: ok" on an x86_64 host
```

Disk: about 6 GB for the kernel tree and build, 4 GB for the root
filesystem, plus the images.

## Steps

`build/build.sh` runs the steps below in order; each script can also be
run on its own and is idempotent.

| Step | Script | Produces |
|---|---|---|
| fetch | `fetch-sources.sh` | `build/cache/`: kernel tree at the pinned commit, the port's 27 patches and config, avbtool, the port's DTBO and vbmeta, Tor Browser (SHA-256 and OpenPGP verified) |
| kernel | `kernel.sh` | `build/out/kernel/`: raw arm64 `Image`, DTB, stripped modules tarball, config, kernel release, ASLR sysctl values |
| libcamera (optional) | `libcamera.sh` (root) | only with `ANTUMBRA_LIBCAMERA_LOCAL=1`: `build/out/libcamera-repo/`, the port's patched libcamera 0.7.2 as arm64 packages in a local apt repository (`camera.md`) |
| rootfs | `rootfs.sh` (root) | `build/work/rootfs/` tree; `build/out/rootfs/initrd.img`, `packages.txt` |
| squashfs | `squashfs.sh` (root) | `filesystem.squashfs` (xz, arm BCJ), `.verity` hash tree, `.roothash` |
| image | `image.sh` | `userdata.simg`: 4096-byte-sector GPT sized to the physical partition, live partition + empty Persistent Storage partition, as an Android sparse image |
| bootimg | `bootimg.sh` | `boot.img`: header v2, cmdline with the verity root hash, unsigned AVB footer, exactly 96 MiB |
| release | `release.sh` | `build/out/release/antumbra-<version>-oneplus-hotdog/` with checksums, manifest and optional minisign signature |

Firmware is a separate, deliberate step: `fetch-firmware.sh` assembles the
proprietary blobs for **your** device from the community mirror the port
uses, verifies every file against the pinned hashes, and lays them out for
`/lib/firmware`. Pass the result as `ANTUMBRA_FIRMWARE_DIR` to
`rootfs.sh`. Without it the image boots but has no display acceleration,
Wi-Fi or audio. See `docs/legal.md`.

## Knobs

| Variable | Effect |
|---|---|
| `ANTUMBRA_MINIMAL=1` | base + network + amnesia package lists only, no Phosh, apps or Tor Browser: validates the pipeline in a fraction of the time |
| `ANTUMBRA_DEBUG=1` | debug command line; `release.sh` refuses to package such a build |
| `ANTUMBRA_VERITY=0` | no dm-verity hash tree and no root hash on the command line |
| `ANTUMBRA_FIRMWARE_DIR=DIR` | firmware tree to copy into `/lib/firmware` |
| `ANTUMBRA_KERNEL_TOOLCHAIN=gcc` | Debian cross GCC instead of LLVM (the port validates only LLVM) |
| `ANTUMBRA_KERNEL_ALLOW_CONFIG_DRIFT=1` | warn instead of fail when the config fragment is not fully honoured |
| `ANTUMBRA_LIBCAMERA_LOCAL=1` | build the port's patched libcamera 0.7.2 (`libcamera.sh`, about five minutes as a cross build on a 4-core x86-64 host) and install it instead of trixie-backports' 0.7.1; off by default (`camera.md`) |
| `ANTUMBRA_SIGNING_KEY=FILE` | minisign secret key for `release.sh` |
| `SOURCE_DATE_EPOCH` | build timestamp (default: the last git commit) |
| `ANTUMBRA_CACHE`, `ANTUMBRA_OUT`, `ANTUMBRA_WORK` | relocate the cache, output and scratch directories |

## Reproducibility

Every input is pinned by hash in `device/oneplus-hotdog/sources.lock` and
the two `.sha256` lists next to it. Timestamps come from
`SOURCE_DATE_EPOCH`, filesystem UUIDs and partition GUIDs are derived from
the version string, the squashfs and ext4 are built with fixed times, and
the package set can be pinned to a `snapshot.debian.org` timestamp
(`DEBIAN_SNAPSHOT` in the lock file). What still varies between builds:
Debian's packages when no snapshot is pinned, and the live partition's
free-space layout if `mke2fs` changes between e2fsprogs versions.

## Testing in a VM

`ANTUMBRA_DEVICE=qemu-virt` builds the same system for QEMU's arm64 `virt`
machine (`make vm-build`, `make vm-run`, `make vm-test`); see
`docs/vm-testing.md`. Profiles live in `device/<name>/device.conf`; the VM
profile reuses the phone's sources, patches and hardening fragment.

## Checks before a release

```sh
make lint          # shellcheck, python, nftables syntax, tor config, systemd units, yaml, file modes
make test          # lint + unit tests
make check-packages
ANTUMBRA_MINIMAL=1 build/build.sh    # pipeline validation end to end
```

The minimal pipeline has been run unattended on an x86-64 build host
(arm64 under qemu-user binfmt): every hook, the initramfs check
(`80-base-initramfs.sh`), the squashfs and verity step, the sparse image,
the boot image and the release checksums completed, and the resulting live
partition was mounted and its squashfs and verity tree verified. The
kernel step was validated with LLVM 18 on the same host.

The CI workflow (`.github/workflows/antumbra.yml`) runs the lint and unit
tests on every push, assembles a boot image from the pinned inputs, and on
manual dispatch builds the kernel and a minimal root filesystem on a native
arm64 runner.
