# Research notes

Condensed, fact-checked findings the design rests on, with their primary
sources. Each item was read in the source named; items marked *unverified*
could not be confirmed from a primary source.

## The OnePlus 7T Pro mainline port

- Repository: `github.com/Sr-0w/hotdog-linux-bringup` (Robin Snyders,
  GPL-2.0 tooling). Release `v0.2.0-alpha.2` (2026-08-28) is the current
  public release; its docs are newer than the `main` branch's.
- Kernel: `gitlab.com/sm8150-mainline/linux` tag `v6.17.0-sm8150`
  (commit `379d8fe35c7c…`) plus 27 patches in
  `aports/device/testing/linux-oneplus-hotdog-mainline617-clean/`;
  config `config-oneplus-hotdog-mainline617-clean.aarch64`; DTB
  `qcom/sm8150-oneplus-hotdog.dtb`; built with LLVM. No newer sm8150
  tag exists; the hotdog DTS lives only in the port.
- Boot image: header v2, page 4096, base 0, kernel 0x8000, ramdisk
  0x01000000, tags 0x100, dtb 0x01f00000, raw `Image` plus separate DTB,
  `avbtool add_hash_footer --algorithm NONE` padded to 100663296 bytes.
  The ABL truncates the cmdline at 511 bytes, ignores `extra_cmdline`
  and refuses `fastboot boot`. Required parameters:
  `iommu.passthrough=0 arm-smmu.disable_bypass=0 clk_ignore_unused`.
  `console=ttyGS0` must not be set.
- Storage: since v0.2.0 the root filesystem is written to `userdata`
  (232,382,812,160 bytes) as a nested GPT with 4096-byte sectors, from
  fastbootd with `-S 128M` (the bootloader stalls on large transfers).
  The port moved away from `super` because of a backup-GPT/kpartx failure
  on the short image, to preserve Android's `super`, both recoveries and
  slot A, and for the capacity. Linux sees the nested partitions through
  `losetup --sector-size 4096 -P`.
- Companions: `dtbo_b` (25165824 bytes, filtered LineageOS-derived DTBO,
  SHA-256 `d23564d4…`) and `vbmeta_b` (65536 bytes, OxygenOS 12 F.22
  vbmeta with flags 3, SHA-256 `e1d9ee62…`), both published in the port's
  release; a stock flags-0 vbmeta sends the phone back to fastboot.
- Firmware: GPU `qcom/a630_sqe.fw` (also in Debian's `firmware-qcom-soc`),
  `qcom/a640_gmu.bin`, `qcom/sm8150/oneplus/hotdog/a640_zap.mbn` (signed
  by OnePlus for this model); `adsp.mbn`, `cdsp.mbn`, `modem.mbn`,
  `venus.mbn`, `wlanmdsp.mbn` under `qcom/sm8150/oneplus/hotdog/`;
  `ath10k/WCN3990/hw1.0/{firmware-5.bin,board-2.bin}`; `qca/crbtfw21.tlv`,
  `qca/crnv21.bin`. Community mirror
  `github.com/sm8150-linux-mainline/firmware-oneplus-hotdog` at commit
  `5e5c5347…`, no licence file. `slpi.mbn` (sensors) and the `persist`
  calibration are not published and not used.
- Hardware status (port's `docs/status.md`, 2026-08-25/28): display 60 Hz
  works, 90 Hz has DSI FIFO errors; touch works awake; Wi-Fi works
  including suspend; Bluetooth fixed by patches 0021–0023; audio
  speakers and handset mic; USB-C dual role and DisplayPort; cameras raw
  capture; modem boots and scans, nothing SIM-validated; GNSS engine
  starts; s2idle 30 cycles; fingerprint impossible.
- Safety contract from the port: dedicated unlocked test phone; back up
  `boot_b`/`dtbo_b`/`vbmeta_b` with size checks; never issue commands to
  a 05c6:9008/900e device; `userdata` is shared with Android and Android
  will format it.

## Wi-Fi needs the modem processor

- The WLAN firmware `wlanmdsp.mbn` runs as a protection domain on the
  modem's DSP; the modem fetches it through `tqftpserv`; `ath10k_snoc`
  only talks to it over the QMI WLFW service. Port evidence
  (`2026-08-04-mainline616-wifi-mpss.md`): no WLAN interface with the
  MPSS disabled; `wlan0` only after the modem reached `running` with
  `rmtfs` and `tqftpserv` active. postmarketOS' SDM845 page says the same
  ("3 packages are required for functional wifi: rmtfs, pd-mapper and
  tqftpserv"). The ath10k list (Dec 2023) confirms the download path.
- Minimum userspace: `rmtfs -r -P -s` (read-only), `tqftpserv`, and a
  protection-domain mapper (the kernel's `qcom_pd_mapper` has an SM8150
  table including `msm/modem/wlan_pd`).
- Radio control: QMI DMS operating modes; `low-power` = IMSI detach and
  RF off, `persistent-low-power` survives a modem reset, `offline` can
  only be left by a reset. Nothing on mainline turns the radio on by
  itself: the port observed the modem in `shutting-down` after boot;
  ModemManager sends `online` only on Enable. There is no rfkill device
  for a QRTR modem. ModemManager had to be blocked at the D-Bus
  activation level on the port. *Unverified*: acceptance of
  `persistent-low-power` from `shutting-down` on this firmware; emergency
  camping in low-power mode.
- GNSS (QMI LOC) only tracks between explicit Start and Stop requests.
- Any process could open an `AF_QIPCRTR` socket on an unpatched kernel
  (`qrtr_create` has no capability check); hence Antumbra's kernel patch.

## Debian trixie as the base

- Tails 7.x is itself Debian 13 based (Tails 7.0, 2025-09-18; 7.14 on
  2026-09-30 with tor 0.4.9.13, Linux 6.12.111).
- 128 of 128 package names Antumbra uses exist in trixie arm64, those of
  Waydroid and its gbinder libraries in trixie-backports only
  (`tests/check-packages.sh`). Notable versions: phosh 0.46.0, greetd
  0.10.3, tor 0.4.9.11, nftables 1.1.3, live-boot 1:20250815, apparmor
  4.1.0, qbootctl 0.2.2, rmtfs/tqftpserv/qrtr-tools/libqmi-utils present,
  mkbootimg and android-sdk-libsparse-utils present; `avbtool` and
  `lyrebird` are not packaged (lyrebird only in unstable).
- Debian's `phosh.service` runs as UID 1000 with `Restart=always` and
  no greeter; `phoc` ships no unit; `greetd` has `[initial_session]` and
  a documented IPC; `phrog` is a greetd greeter built on libphosh with a
  `first-run` hook. `phosh-session` exports no `XDG_*` variables.
- live-boot: an explicit `live-media=<path>` is honoured and skips the
  UUID check; its own scan excludes loop devices; `live-premount` scripts
  run before the medium search; its hook copies util-linux `losetup`
  (with `--sector-size`); dm-verity is supported with
  `dm-verity-root-hash=IMAGE:HASH` and `dm-verity-oncorruption=`.
- udev's `60-persistent-storage.rules` creates by-label/by-uuid/
  by-partlabel symlinks for loop partitions; udev runs in the initramfs.
- `qbootctl.service` runs `qbootctl -m` at `multi-user.target`;
  `systemd-zram-generator`'s vendor config already enables `zram0`;
  `usbguard` defaults to `ImplicitPolicyTarget=block` and needs a 0600
  rules file (Debian's postinst would generate one from the build host).
- Tor Browser 16.0a13 ships `tor-browser-linux-aarch64-16.0a13.tar.xz`
  (SHA-256 `4dba033e…`, signed by `EF6E 286D DA85 EA2A 4BA7 DE68 4E2C
  6E87 9329 8290`), with `lyrebird` and `conjure-client` as transports;
  stable 15.0.24 is x86 only; alphas track Firefox Rapid Release and Tor
  Project advises at-risk users against them.
- `ferm` 2.5 emits iptables syntax only and prefers the legacy binaries;
  `nft` supports `meta skuid "name"` and `redirect to :port`.

## Tails internals used

- Tree: Tails 7.11 from a Software Heritage snapshot of 2026-08-19
  (revision `fd415c38…`); every vendored file matched the listing's
  hashes. Current Tails is 7.14; 7.12–7.14 configuration changes have not
  been diffed.
- Tails states it does not run on ARM or on phones; Antumbra is a
  rebuild of its design, not a port of its images or build system
  (live-build, Vagrant, x86 only).
- Firewall semantics, torrc ports, onion-grater, netns addresses
  (10.200.1.0/24), MAC spoofing chain, module blocklists, sysctl set,
  kernel cmdline hardening (`slab_nomerge slub_debug=FZ init_on_free=1
  page_alloc.shuffle=1 randomize_kstack_offset=on`), memory erasure
  design, tps parameters (LUKS2, argon2id, 1 GiB, 4 iterations, partition
  type `8DA63339-0007-60C0-C436-083AC8230908`) and the Welcome Screen
  file format were taken from the tree. `page_poison=on` would disable
  `init_on_free` (kernel `mm/mm_init.c`) and is deliberately absent.
- Tails' `vm.mmap_rnd_bits=32` is x86 only; arm64 maxima come from the
  kernel configuration (33/16 for this kernel).

## Threat-model inputs

- Cold-boot and forced-reset attacks on phones are documented (FROST on
  the Galaxy Nexus); LPDDR4X remanence on SM8150 is unmeasured.
- AVB in the unlocked state treats verification failures as non-fatal and
  shows the orange state; `fastboot flash avb_custom_key` is documented for
  Pixels only.
- Inertial sensors leak keystrokes and routes (TouchLogger, Gyrophone,
  Narain et al.); Antumbra disables the sensor DSP.
- Prior art: Tails' ARM ticket and handheld discussions, Whonix (needs
  KVM), Tor Project's 2014 "Mission Impossible" tablet, GrapheneOS with
  Orbot; none shipped an amnesic Tor-enforcing phone OS.
