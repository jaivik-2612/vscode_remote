# Testing Antumbra in a virtual machine

The `qemu-virt` device profile boots the system on QEMU's arm64 `virt`
machine so the whole userland, the initramfs and the live-medium logic can
be exercised without the phone. It is a test target, not a release target:
`release.sh` refuses it and nothing from it is meant to be flashed.

## What is the same as on the phone

- The kernel comes from the same sources, the same port patches and the
  same hardening fragment (`device/oneplus-hotdog/kernel/antumbra.config`),
  built with the same toolchain; `device/qemu-virt/kernel/virt.config`
  only adds the virtio display, input, RTC, power button and sound, and
  builds the virtio network driver as a module so that the driver blocklist
  and the MAC-spoofing path are exercised as on the phone.
- The root filesystem is built by the same hooks from the same overlay and
  package lists; the squashfs, its dm-verity tree and the initramfs are
  built by the same steps.
- The disk holds the same nested layout: an outer GPT (4096-byte sectors)
  whose only partition is named `userdata`, containing the live partition
  and the Persistent Storage partition exactly as the phone's userdata
  partition does. The initramfs finds it the same way (partition name, then
  the live filesystem UUID recorded at build time), with one switch:
  `antumbra.live-bus=virtio` on the VM's command line accepts a virtio block
  device where the phone only accepts the UFS controller. The phone's
  command line never carries that switch, so its path is unchanged.

## What differs

- The kernel keeps the port's direct-boot contract for the phone's bootloader
  (`CONFIG_ONEPLUS_HOTDOG_EARLY_BOOT`): at entry, with the MMU off, it
  writes zero to the SM8150 watchdog's address. On the virt machine that
  address lies in the empty PCIe window, where the write is discarded; the
  first VM boot confirmed it is harmless, so the VM kernel stays identical
  to the phone's in this respect. The same option sets the Image header's
  load offset, hence QEMU's "Kernel image misaligned" warning at boot.

- No modem, no Wi-Fi, no Qualcomm remote processors: the units that talk to
  them fail or stay inactive, and the network interface is a virtio NIC on
  QEMU's user-mode network (10.0.2.0/24). That network has no route to Tor
  from a build host behind an HTTP proxy, so Tor will not bootstrap there;
  what the VM proves is that nothing but Tor tries.
- Debug builds only: a root shell on the virtio console `hvc0`
  (`config/hooks/70-debug-console.sh`), installed when both
  `ANTUMBRA_DEBUG=1` and `ANTUMBRA_DEVICE=qemu-virt` are set at build time
  and active only with `antumbra.debug=1` on the command line. The journal
  is forwarded to the serial console in such builds. Release builds and
  phone builds never contain it.
- The display is a virtio GPU rendered in software; expect the Welcome
  screen to take a minute or two to appear under emulation.

## Building

```sh
make vm-build            # ANTUMBRA_DEVICE=qemu-virt ANTUMBRA_DEBUG=1 build/build.sh
```

Outputs go to `build/out/qemu-virt/` (`kernel/Image`, `rootfs/initrd.img`,
`rootfs/filesystem.squashfs*`, `vm-disk.img`) and scratch to
`build/work/qemu-virt/`; the phone's `build/out/` is untouched. The build
needs the same host tools as the phone build plus `qemu-system-aarch64`
and `qemu-img` (`qemu-system-arm qemu-utils ipxe-qemu` on Debian/Ubuntu).
`ANTUMBRA_MINIMAL=1` works here too for a small, session-less image.

## Running

```sh
make vm-run              # serial console on this terminal; Ctrl-A X quits
make vm-start            # background; then:
build/vm.sh console      #   attach to the serial console
build/vm.sh shell 'nft list ruleset | head'   # run a command on the debug console
build/vm.sh screenshot shot.png
build/vm.sh powerdown    #   press the virtual power button
make vm-stop
```

`build/vm.sh start --vnc 1` shows the display on VNC port 5901. Each run
starts from a fresh copy-on-write overlay of `vm-disk.img` (so a run can
never alter the image); `--keep-disk` reuses the previous overlay, which is
how Persistent Storage survives a reboot in a test.

## Smoke test

```sh
make vm-test             # boots in the background, checks, powers down
```

`tests/vm-smoke.sh` (the `smoke` command of `tests/vm/antumbra_vm.py`)
asserts, in order:

1. the initramfs ran Antumbra's medium search and accepted the live
   partition (bus check, partition name, filesystem UUID), and systemd
   reached `multi-user.target`;
2. on the debug console: the release file, an overlay root on the
   loop-mounted live partition whose UUID equals the recorded one, the live
   medium mounted read-only, dm-verity active when the command line asks
   for it, the nftables ruleset with a
   dropping output chain, `selfcheck` reporting the firewall OK,
   `tor@default.service` active,
   no network interface, no network driver and NetworkManager inactive
   before the Welcome decision, `virtio_net` in the driver blocklist, a
   resolver whose only nameserver is 127.0.0.1, zram-only swap with
   `dmesg_restrict` and volatile logs, a Persistent Storage partition with
   no filesystem signature, and (full builds) greetd and phoc running;
3. a screenshot of the display (`build/work/qemu-virt/vm-run/smoke/display.png`);
4. from the packet capture of the VM's network (`net.pcap`): no frame of
   any kind (ARP included) left the guest before the Welcome decision, judged
   by source MAC address (only QEMU's own user network, `52:55:`/`52:56:`,
   may appear), and the display shows the drawn Welcome screen rather than
   a text console;
5. with `--through-welcome` (what `make vm-test` runs): the harness finds
   the "Start Antumbra" button on the display and presses it with the
   defaults (amnesic session, MAC address anonymization, Tor connected
   automatically), then checks that the settings were applied and Phosh
   started, that the network driver loaded only now and the interface got
   an address, that the interface's MAC address is not the one QEMU gave
   the hardware, and, polling every socket in the system once a second for
   90 seconds, that every connection to the network belongs to Tor (DHCP
   aside); from the packet capture, that no DNS, NTP, IPv6 or other UDP
   left the guest, that every TCP connection the guest opened went to one
   of the directory addresses built into the image's Tor or to a peer seen
   on Tor's sockets, and that no frame carried the hardware MAC address;
6. a short press of the virtual power button is ignored (only a long
   press powers off, as on the phone), a power-off requested from the
   console goes through the return-to-initramfs shutdown path (the hook
   reports the old root and the medium unmounted, the verity device
   removed, the loop devices detached and the caches dropped), and, on a
   run that started from a fresh overlay, `qemu-img map` shows that the
   guest wrote not one block to its disk.

`--tour` adds screenshots of the session (app overview, quick settings,
Tor Browser) and checks that Tor Browser runs inside its `tbb` network
namespace. `make vm-test SCALE=2` doubles every timeout.

Every check is reported as PASS or FAIL and the exit status is non-zero if
any failed; a command that fails on the debug console is a FAIL of its own,
never output for a check to read. `--timeout-scale 2` doubles every timeout for slow hosts.

## What the first VM runs found

Booting the full image and pressing Start exposed these defects, all fixed
in the configuration. Every one except the interface rename would have
affected the phone the same way.

| Symptom in the VM | Cause | Fix |
|---|---|---|
| Greeter screen black, phoc aborts at startup | `phoc.ini` mode line without the `Hz` suffix | `1440x3120@60Hz`; `tests/lint.sh` validates mode lines |
| Greeter shows only a spinner | phoc started with `-S` (waits for a Phosh shell the greeter does not run) | no shell mode in the greeter session |
| Welcome window never drawn | fullscreen requested before the surface's first commit; phoc drops the initial configure | go fullscreen once presented |
| Session ends at once, greeter returns | `phosh-session` runs `gnome-session`, only recommended by Phosh | `gnome-session-bin`, `gnome-session-common` |
| Tor runs unconfined | Debian's `apparmor.service` skips live systems with an overlayfs root | unit override, Tails' alias tunables for trixie's paths, `attach_disconnected` (hook 48) |
| Interface keeps the hardware MAC | udev passed the pre-rename name (`eth0`) to the spoofing script | look the interface up by `IFINDEX`; record and verify every Ethernet-type interface |
| Tor Browser does not start | browser and profile directories kept the tarball's 0700 mode | `chmod -R a+rX`, as Tails' 10-tbb |
| Every icon is a placeholder | gdk-pixbuf's SVG loader (`librsvg2-common`) only recommended by GTK | added to the package list |
| usbguard fails at every boot | its audit-log directory is under the volatile `/var/log` | tmpfiles entry |
| Self-check banner: sysctl errors | Tails' userfaultfd key (kernel built without userfaultfd) and bubblewrap's Debian-only key | `-` prefix; bubblewrap's file masked |
| Self-check banner: modem radio | the check could not accept the "absent"/"unavailable" states | parse the state file's first line |
| `swapon --show` refused | the zram-only wrapper treated every call as an activation | queries pass; every named device must be zram |

## What the VM cannot tell you

Anything that needs the phone's hardware: the display panel, touch, the
modem policy (`antumbra-modem-radio-off`), the Wi-Fi driver and its
firmware, audio routing, the bootloader (slot B, AVB), battery and thermal
behaviour. `docs/hardware-validation.md` keeps that list.
