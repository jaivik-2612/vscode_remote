# Testing Antumbra in a virtual machine

The `qemu-virt` device profile boots the system on QEMU's arm64 `virt`
machine so the whole userland, the initramfs and the live-medium logic can
be exercised without the phone. It is a test target, not a release target:
`release.sh` refuses it and nothing from it is meant to be flashed.

## What is the same as on the phone

- The kernel comes from the same sources, the same port patches and the
  same hardening fragment (`device/oneplus-hotdog/kernel/antumbra.config`),
  built with the same toolchain; `device/qemu-virt/kernel/virt.config`
  only adds the virtio display, input, RTC, power button and sound, builds
  the virtio network driver as a module so that the driver blocklist
  and the MAC-spoofing path are exercised as on the phone, and builds
  `vimc`, the kernel's virtual camera, as a module (four symbols in all:
  `MEDIA_TEST_SUPPORT`, `V4L_TEST_DRIVERS`, `VIDEO_VIMC` and the test
  pattern generator it selects).
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
- Debug builds only, for the camera checks: hook `72-vm-camera.sh` loads
  `vimc` at boot and adds a WirePlumber rule that hides its raw V4L2 nodes
  by card name (the VM's counterpart of the CAMSS rule), and
  `config/packages/vm-debug.list` adds `libcamera-tools` (`cam`). The phone
  has neither, and its kernel does not build `vimc`.
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
   the "Start Antumbra" button on the display (by the theme's accent
   colour) and presses it with the
   defaults (amnesic session, MAC address anonymization, Tor connected
   automatically), then checks that the settings were applied and Phosh
   started, that the network driver loaded only now and the interface got
   an address, that the interface's MAC address is not the one QEMU gave
   the hardware, and, polling every socket in the system once a second for
   90 seconds, that every connection to the network belongs to Tor (DHCP
   aside); from the packet capture, that no DNS, NTP, IPv6 or other UDP
   left the guest, that every TCP connection the guest opened went to one
   of the directory addresses built into the image's Tor, to a peer seen
   on Tor's sockets, or to a destination in the guest kernel's record of
   the TCP SYNs Tor's sockets sent (an nft set in a table of the harness's
   own, loaded before the Welcome decision and deleted after the session's
   network checks; it catches relays Tor contacts and closes between two
   socket polls), and that no frame carried the hardware MAC address;
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

`--camera` checks the camera path on `vimc` (`camera.md`): the driver is
loaded and udev names its video nodes by card name (`ID_V4L_PRODUCT`, the
key the WirePlumber rules match); `cam -l` lists the camera; Snapshot,
libcamera 0.7 with its IPA modules from the same build and PipeWire's
libcamera plugin at PipeWire's version are installed, and Megapixels is
not; no OnePlus camera software or Qualcomm camera HAL file is anywhere in
the image, inside packages, archives, compressed files, the initramfs and
Waydroid's Android images included (`tests/no-oneplus-camera.py`, run in
the guest under a limit that follows the timeout scale and the size of the
image's squashfs, about 28 minutes for the `--android` image at scale 1;
the guest stops it there, and the log gives the time it took), and the
same scanner in the guest does flag a OnePlus camera
APK placed in a small ext4 image and in a zstd-compressed XAPK. With
`--through-welcome` it goes on in the amnesia session: PipeWire offers the
camera as a libcamera node and has no V4L2 camera device or node; the first
Snapshot start makes the camera portal ask through Phosh's Access dialog
(seen on the session bus) and gets no stream meanwhile; once the decision
is stored as "allow", the portal also gives `amnesia` a PipeWire
connection when called from inside Tor Browser's network namespace (the
gap the planned browser profile must close, `camera.md`), Snapshot
streams, the preview shows `vimc`'s colour
bars (under full emulation the first frame takes a few minutes: Snapshot
draws 1920x1080 frames in software and drops most as late, so the harness
polls the display for up to five minutes times the timeout scale), the shortcut `t` saves a JPEG to `~/Pictures/Camera`, and the stream
stops when Snapshot quits and when it is killed. Screenshots:
`camera-portal-prompt.png`, `camera-after-prompt.png`,
`camera-preview.png`. The full run is
`tests/vm-smoke.sh --through-welcome --camera`.

Every check is reported as PASS or FAIL and the exit status is non-zero if
any failed; a command that fails on the debug console is a FAIL of its own,
never output for a check to read. `--timeout-scale 2` doubles every timeout for slow hosts.

## Android apps

The VM profile selects Waydroid's `arm64_only` images: the test bundle
may run the VM under HVF or KVM with a host CPU that has no 32-bit
(AArch32) mode, which the phone's `arm64` images need. Build an image with
Android apps beside the plain one:

```sh
ANTUMBRA_DEVICE=qemu-virt ANTUMBRA_DEBUG=1 ANTUMBRA_ANDROID=1 build/build.sh
```

Both modes below need such an image and imply `--through-welcome`; on a
plain image their first check fails. Before the Welcome screen, both check
that Android is off: binder devices root-only, no container, no DHCP
server, LXC's own services masked, D-Bus activation of Waydroid's
container service refused, Waydroid's templates edited (bridge
`waydroid-tor`, no `sys_time`, the start-host hook, every device but
cameras: `allow = a` before the V4L2 deny, `/sys/firmware` hidden, the
generic kernel command line, Antumbra's post-stop hook before
Waydroid's), the images and F-Droid in the read-only system, `pkexec`
not setuid; and they record the modes of the binder devices, the render
node, the framebuffers and the DMA-BUF heaps. The usual checks of a
session then run too, with the Android listeners excluded from
"everything goes to Tor".

`tests/vm-smoke.sh --android-net` presses Start without turning Android
on, and tests the network Android would use without booting Android: a
stand-in container (a network namespace with the container's MAC address
on the bridge) runs the DHCP client and a set of probes. It checks the
bridge's address and sysctls, Tor's two listeners, the self-check lines,
the DHCP lease (with and without the broadcast flag), that TCP to the
Internet, the host's own public address included (203.0.113.77, put on
the guest's loopback for the probes), reaches Tor's TransPort for Android
and a held connection ends in the `tor` process, that the local network
and the host's own addresses there and on the namespaces' veths all time
out alike, that the bridge's host address (Tor's control port, the
control-port filter, the TransPort addressed directly) and DNS over TLS
are refused at once, that any DNS server is answered by Tor, that the
start-host hook, run for the stand-in with `LXC_PID`, rejects `.onion`
virtual addresses in its namespace (a `.onion` name's address is refused
while a listener on that port there works), that NTP, QUIC, ping and IPv6
get no answer, the firewall's redirect counters, the start-host hook
failing closed without each part of the network or the container's PID
(and passing with it), that Tor refuses to connect while the bridge is
missing, and from the packet capture that nothing of the stand-in left the
guest. `tests/android-net-lab.py`, run by `tests/lint.sh`, replays the
firewall, the hook and these probes in network namespaces on the build
host. Where the build host lacks something the lab itself needs (network
or mount namespaces, a tmpfs, the bridge or veth driver, nftables or the
reject expression the hook loads), the lab says what and is skipped
(exit 0); only its checks fail.
It takes a few minutes longer than `--through-welcome`.

`tests/vm-smoke.sh --android --timeout-scale 3` turns on "Android apps"
at the Welcome screen (Alt+A, the switch's mnemonic, then a screenshot
`welcome-android.png`) and boots Android, with 6 GiB of guest memory
unless `--memory` is given, `androidboot.serialno=ANTUMBRATEST` added to
the kernel command line (`vm.sh --append`, as the phone's boot loader adds
its serial number) and the disk given the serial number
`ANTUMBRATESTDISK` (`vm.sh --disk-serial`). It checks that
`antumbra-waydroid.service` prepared Waydroid from the images in the
system without touching the network, the generated container
configuration, that Waydroid's own `waydroid-net.sh` does nothing, that
the container runs and Android reports `sys.boot_completed=1` (the
harness waits 40 minutes times the timeout scale; software emulation is
slow), the generic Waydroid identity,
`/sys/firmware` hidden, that Android's `/proc/cmdline` is the generic one
and neither it nor `ro.serialno` or `ro.boot.serialno` shows the test
serial, that every serial number file in sysfs (the disk's included)
reads empty inside Android, that the container can open `/dev/null` but
not a V4L2 device node it creates, the DHCP lease and route, the provisioning
(captive-portal checks, Private DNS and network time off), a screenshot
of Android's full UI (`android-full-ui.png`), F-Droid installed and
listed in the app grid's "Android" folder, F-Droid's index fetch counted
at Tor's TransPort for Android, Android's resolver mapping a `.onion` name
into 127.192.0.0/10 with no answer to a ping there (Android's own
`ping`, output saved as `android-onion-ping.txt`; should it get no
address at all under `lxc-attach`, the run says so on an `[INFO]` line
rather than failing, since that shows nothing about the block), the
start-host hook's `.onion` block in Android's network namespace (a
connection to the name's address, looked up through Tor's DNSPort for
Android, refused, not delivered to a listener there on its port: the
check that decides), the
session's traffic, no frame from the container's MAC address or network
in the capture; after `waydroid session stop`, that Waydroid's container
service stops, that every device it opened has its boot mode again and
that Android stays stopped for 30 seconds; and the start-host hook
refusing to start the container without the firewall's Android rules,
after which Android starts again. The harness runs commands inside the
container with `lxc-attach` with no standard descriptor on the console's
tty (`in_android`): given a tty, lxc-attach switches to a terminal proxy
that sends the output to `/dev/tty` instead of a pipe and flushes the
console's pending input, the harness's status marker with it.

To check the `android` Persistent Storage feature by hand: run with
`--keep-disk`, create Persistent Storage and turn on both Android
switches, install an app from F-Droid, power off, start again with
`--keep-disk`, unlock with Android on and see the app; unlock with "Keep
Android apps and data" off and see a fresh Android.

What the VM cannot tell about Android: performance and memory use on the
phone, the 32-bit half of the `arm64` images, the Adreno GPU under
Android (the VM renders in software), audio and the microphone, the
on-screen layout at the phone's density, and suspend with Android
running.

## Persistent Storage

`tests/vm-smoke.sh --persistence` creates Persistent Storage, and
`tests/vm-smoke.sh --persistence -- --keep-disk` (the next run, on the
same disk overlay) unlocks it. Both write the Welcome screen's settings
through the Welcome screen's own module, run as the greeter user (the
same files, byte for byte, as the Welcome screen writes: a passphrase
typed through QMP into GTK password rows under software emulation would
test the keyboard path rather than Persistent Storage), wait for the
root applier, then press "Start Antumbra", which starts the session as
after a logout, and run the usual session and network checks.

The first run (fresh disk) checks that the partition had no volume,
chooses "Create" with a screen-lock passphrase and administration on,
and checks that the volume is LUKS2 with argon2id, unlocked and mounted,
with `~/Persistent`, the Welcome settings, the network connections and
`/var/lib/tca` bound from it; that this boot's settings were applied and
saved on the volume, owned by the greeter user, without the passphrase's
hash; that no Persistent Storage passphrase was left behind; that
administration and the passphrase are in force; and that a file written
to `~/Persistent` lands on the volume. The second run (`--keep-disk`)
checks that the partition holds a LUKS volume, opens it read-only first
to check what the first run stored (administration on, no passphrase
hash, the file in `Persistent`), then chooses "Unlock" with no
screen-lock passphrase and administration off, and checks that the
volume was unlocked, that this boot's settings were applied and replaced
the stored ones (administration off, no passphrase, no sudoers rule), and
that `~/Persistent` still holds the file. The run takes longer than
`--through-welcome`: argon2id with 1 GiB of memory runs several times
under emulation.

In this mode the check "the guest wrote nothing to the disk" is skipped,
not failed (the harness says so): Persistent Storage writes the disk by
design.

## Kernel test modules

`tests/kernel/genpd-sleep-vm.sh` loads a small genpd test module into a
running debug VM and runs suspend-to-idle cycles with an RTC wake-up, two
of them refused at `PM_SUSPEND_PREPARE` on purpose. It shows that genpd
calls a power domain's callbacks in the noirq phases (power_on in
resume_noirq, power_off in suspend_noirq), and that a model of the pop-up
motor patch's sleep gate, a copy of its logic in the test module rather
than the driver, keeps those calls from moving the motor. It also runs
that model through a suspend aborted while a failed close keeps the domain
on, and through a retract that fails before sleep, and shows that the
gate as the patch first had it fails both (`tests/kernel/README.md`).
`tests/lint.sh` replays the same failure sequences against a Python model
of the driver's flags (`tests/kernel/popup_gate_model.py`).

Not covered: the driver itself. `hotdog-popup-motor.c` is never built or
loaded in the VM, so a regression in its gate passes these tests unless
the models change with it. Exercising it would need the module built for
the VM with simulated GPIOs (`GPIO_SIM`), a GPIO-driven PWM for STEP
(`PWM_GPIO`) and a fake IIO provider for the Hall channels; until then the
driver is checked by review and on the phone
(`docs/hardware-validation.md`).

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
firmware, audio routing, the cameras themselves (CAMSS, the sensors, the
pop-up motor, image quality, whether PipeWire can hold the CAMSS graph),
the bootloader (slot B, AVB), battery and thermal behaviour.
`docs/hardware-validation.md` keeps that list.
