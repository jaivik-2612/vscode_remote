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
  screen to take a minute or two to appear under emulation. Screenshots
  show artifacts of the VM that the phone does not have: a black square
  in the top-left corner (the pointer, under software rendering), in one
  screenshot black patches over the top bar's clock, and the battery
  indicator at 0% (the VM has no battery).

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

`make vm-bundle` packages the build as a test bundle for another machine,
`build/out/qemu-virt/antumbra-<version>-qemu-virt.tar`: the kernel, the
initramfs, the compressed disk, the command line with the root hash and a
`run.sh` that needs only `qemu-system-aarch64`, `qemu-img` and `zstd`, and
uses KVM on arm64 Linux, Apple's hypervisor on Apple-silicon Macs and
emulation elsewhere (`--debug` for the root console). The VM gets 6 GiB
of memory when the image has Android apps and 4 GiB otherwise (`MEM=` in
MiB changes it), and the README names the commit the root filesystem was
built from (`ANTUMBRA_SOURCE` in `build-flags`). The bundle has no
harness: the checks below need the source tree.

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
   `tor@default.service` active, AppArmor profiles loaded with Tor
   confined in enforce mode,
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
   aside), judged by the owner the guest kernel reports for each socket
   (Tor's user ID from `ss -e`, root's for the DHCP client; a socket in
   TIME-WAIT, which has no owner left, by its peer, which must be Tor's);
   from the packet capture, that no DNS, NTP, IPv6 or other UDP
   left the guest, that every TCP connection the guest opened went to one
   of the directory addresses built into the image's Tor, to a peer seen
   on Tor's sockets, or to a destination in the guest kernel's record of
   the TCP SYNs Tor's sockets sent (an nft set in a table of the harness's
   own, loaded before the Welcome decision and deleted after the session's
   network checks; it catches relays Tor contacts and closes between two
   socket polls). Destinations are matched by address and port, so another
   program's connection to an address and port Tor also used would pass
   this capture check; the socket check catches it only while it is open.
   And that no frame carried the hardware MAC address. Then, in the
   session, that no file indexer runs (hook 52 switches it off,
   `architecture.md` section 11): `localsearch-3`, its control and
   writeback services and `tinysparql-xdg-portal-3` are masked user units,
   a D-Bus call to `org.freedesktop.LocalSearch3` is refused rather than
   activating it, and no localsearch process runs for any user. Every
   mode below that starts a session runs this check too;
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
the "Allow" button stores (`yes`) is in place, the portal also gives
`amnesia` a PipeWire connection when called from inside Tor Browser's
network namespace (the gap the planned browser profile must close,
`camera.md`; the call runs
unconfined, so once the profile ships it has to run under the profile,
`aa-exec -p`, and expect a refusal), Snapshot
streams, the preview shows `vimc`'s colour
bars (under full emulation the first frame takes a few minutes: Snapshot
draws 1920x1080 frames in software and drops most as late, so the harness
polls the display for up to five minutes times the timeout scale), the shortcut `t` saves a JPEG to `~/Pictures/Camera`, and the stream
stops when Snapshot quits and when it is killed. Screenshots:
`camera-portal-prompt.png`, `camera-after-prompt.png`,
`camera-preview.png`. The full run is
`tests/vm-smoke.sh --through-welcome --camera`; without a session the
session part is one FAIL.

Every check is reported as PASS or FAIL and the exit status is non-zero if
any failed; a command that fails on the debug console is a FAIL of its own,
never output for a check to read. A command that times out is interrupted
(Ctrl-C on the console) so that the commands after it still get an
answer. The results also go to
`build/work/qemu-virt/vm-run/smoke/report.json`, beside the screenshots.
`--timeout-scale 2` doubles every timeout for slow hosts.

## Android apps

The VM profile selects Waydroid's `arm64_only` images: the test bundle
may run the VM under HVF or KVM with a host CPU that has no 32-bit
(AArch32) mode, which the phone's `arm64` images need. Build an image with
Android apps:

```sh
ANTUMBRA_DEVICE=qemu-virt ANTUMBRA_DEBUG=1 ANTUMBRA_ANDROID=1 build/build.sh
```

It replaces the plain image in `build/out/qemu-virt/`; to keep both,
build and run one of them with other `ANTUMBRA_OUT` and `ANTUMBRA_WORK`
directories.

Both modes below need such an image and imply `--through-welcome`; on a
plain image their first check fails. They exclude each other and
`--persistence`; `--camera` and `--tour` combine with them. Before the
Welcome screen, both check that Android is off: binder devices
root-only, no container, no DHCP server, LXC's own services masked,
D-Bus activation of Waydroid's container service refused and the
container service not started at boot, Waydroid's templates edited
(bridge `waydroid-tor`, no `sys_time`, the start-host hook, every device but
cameras: `allow = a` before the V4L2 deny, `/sys/firmware` hidden, the
generic kernel command line, Antumbra's post-stop hook before
Waydroid's) and its code passing no video device, the images and F-Droid
in the read-only system, `pkexec` not setuid, Tor's TransPort and DNSPort
for Android and the `android` Persistent Storage feature configured; and
they record the modes of the binder devices, the render node, the
framebuffers and the DMA-BUF heaps. The usual checks of a session then
run too, with the Android listeners excluded from "everything goes to
Tor".

`tests/vm-smoke.sh --android-net` presses Start without turning Android
on, and tests the network Android would use without booting Android: a
stand-in container (a network namespace with the container's MAC address
on the bridge) runs the DHCP client and a set of probes. The VM gets the
same serial numbers as with `--android` below, on the kernel command line
and the disk. It checks the bridge's address and sysctls, Tor's two
listeners, the self-check lines, that the bridge's DHCP server does not
start while Android is off, the DHCP lease (with and without the
broadcast flag), that TCP to the
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
failing closed without each part of the network or the container's PID,
or for a stand-in whose mount namespace lacks the mask of one identifier
that has content (the hook rightly accepts an identifier that reads empty
or is hidden with its directory), and passing with them all, switching
the bridge's forwarding off (the stand-ins get the masks in a mount
namespace of their own, as LXC mounts them), that Tor refuses to connect
while the bridge is missing and connects again once it is back, and from
the packet capture that nothing of the stand-in left the guest.
`tests/android-net-lab.py`, run by `tests/lint.sh`, replays the firewall,
the hook and these probes in network namespaces on the build host, the
stand-in container's identifier masks mounted in its mount
namespace (the hook must refuse a stand-in where a file's mask is
missing, or a directory's if the build host has one to hide). It needs
unprivileged user namespaces, or root. Where the build host lacks
something the lab itself needs (network or mount namespaces, a tmpfs,
bind mounts over sysfs, the bridge or veth driver, nftables or the reject
expression the hook loads), the lab says what and is skipped (exit 0),
and so are the unit tests of its skipping (`tests/unit/test_android_net.py`,
with the lab's reason); only its checks fail, and on any host a file it
runs that cannot be read (the firewall, the hook, the image's generic
kernel command line).
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
the container runs, its start-host hook having found every hardware
identifier masked in the container's own view (its journal line), and
Android reports `sys.boot_completed=1` (the
harness waits 40 minutes times the timeout scale; software emulation is
slow, see below; if Android does not boot, the run saves Waydroid's log
and the units' journals as `android-boot-failure.txt` and Android's log
as `android-logcat.txt`), the generic Waydroid identity, Android set up
for emulation (`ro.hw_timeout_multiplier=10` and
`persist.waydroid.suspend=false`),
`/sys/firmware` and `/proc/device-tree` hidden, that Android's
`/proc/cmdline` is the generic one and neither it nor `ro.serialno` or
`ro.boot.serialno` shows the test serial, that every hardware identifier
file in sysfs (serial numbers, the disk's included, and device-mapper
UUIDs, the dm-verity root's among them) and every partition's `uevent`
(PARTUUID) read empty inside Android, that the RTC's directory (and any
nvmem provider's) is empty there and `/proc/driver/rtc` reads empty, that
none of the host's MAC addresses and no Wi-Fi radio shows in Android's
sysfs, that the container can open `/dev/null` but not a V4L2 device node
it creates, the DHCP lease
and route, the provisioning
(captive-portal checks, Private DNS and network time off), Android's
full UI drawn (`android-full-ui.png`: more than half of the screen must
differ from what it showed just before, since the session alone has
plenty of colours), F-Droid installed (the
harness waits 20 minutes times the timeout scale, and saves the
installer's journal as `android-fdroid-install.txt` if F-Droid is
missing) and listed in the app grid's "Android" folder, F-Droid's
window shown (`android-fdroid.png`, the same comparison), its index
fetch counted
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
after which Android starts again with a device plugged in meanwhile (a
device-mapper device with a UUID: its mask is in the configuration and
Android reads it empty, `cat` succeeding; the read is repeated until
`lxc-attach` gets in, so that an error message is never taken for the
file), and once more after Android has stopped and the
device has gone. The harness runs commands inside the
container with `lxc-attach` with no standard descriptor on the console's
tty (`in_android`): given a tty, lxc-attach switches to a terminal proxy
that sends the output to `/dev/tty` instead of a pipe and flushes the
console's pending input, the harness's status marker with it.

Under QEMU's full emulation Android does not boot with its own timeouts.
When system_server's Watchdog reaches its half-way mark, it asks for
native stack dumps of vold and the HALs and gives each 2 seconds. Under
emulation every dump took longer, the dumped process (vold, the
hwcomposer, gralloc, light, power and vibrator HALs, `system_suspend`)
died of SIGPIPE when the requester gave up, and vold's death rebooted
Android (vold has `reboot_on_failure`), which stopped the container.
Yama's `ptrace_scope=2` is not the cause: `debuggerd -b` of a HAL, run
by hand, succeeded and the HAL survived. So in a virtual machine
`antumbra-waydroid` sets `ro.hw_timeout_multiplier=10`, as emulators do,
and the run checks it once Android has booted; the phone keeps Android's
own timeouts (`known-issues.md`, "Android apps"). With the multiplier
set from the start, Android's init reached `sys.boot_completed=1` in
about 15 minutes (666 to 1557 seconds of the guest's uptime), with no
service dying on the way.

Booted is not set up, though. Unlocking Android's user, which makes
Waydroid write the apps' desktop entries, takes minutes more under
emulation, and before it finished Android's display went to sleep and
Waydroid froze the container (`suspend_action = freeze`, its default).
Frozen, Android never told the session it was ready (no app entries in
the app grid), drew no window, never ran F-Droid, and every `lxc-attach`
blocked, which made console commands time out. So in a virtual machine
`antumbra-waydroid` also sets `persist.waydroid.suspend=false`. Set by
hand in a running VM, the container stayed running, the 13 apps'
entries appeared within 8 minutes, and `waydroid show-full-ui` drew
Android's interface. On the phone Waydroid keeps freezing an Android
nobody is using, to save power; there the unlock comes seconds after the
boot.
Installing F-Droid then takes minutes more: `antumbra-fdroid-install`
waits up to 15 minutes after `waydroid app install` for Android to list
the package.

To check the `android` Persistent Storage feature by hand: run with
`--keep-disk`, create Persistent Storage and turn on both Android
switches, install an app from F-Droid, power off, start again with
`--keep-disk`, unlock with Android on and see the app; unlock with "Keep
Android apps and data" off and see a fresh Android.

What the VM cannot tell about Android: performance and memory use on the
phone, whether Android's own timeouts hold there (the VM scales them
tenfold), the 32-bit half of the `arm64` images, the Adreno GPU under
Android (the VM renders in software), audio and the microphone, the
on-screen layout at the phone's density, and suspend with Android
running.

## Persistent Storage

`tests/vm-smoke.sh --persistence` creates Persistent Storage, and
`tests/vm-smoke.sh --persistence -- --keep-disk` (the next run, on the
same disk overlay) unlocks it. The mode implies `--through-welcome` and
excludes the Android modes. Both write the Welcome screen's settings
through the Welcome screen's own module, run as the greeter user (the
same files, byte for byte, as the Welcome screen writes: a passphrase
typed through QMP into GTK password rows under software emulation would
test the keyboard path rather than Persistent Storage), wait for the
root applier as the Welcome screen does, then press "Start Antumbra",
which starts the session as after a logout, and run the usual session
and network checks.

The first run (fresh disk) checks that the partition had no volume,
chooses "Create" with a screen-lock passphrase and administration on,
and checks that the volume is LUKS2 with argon2id, unlocked and mounted,
with `~/Persistent`, the Welcome settings and the network connections
bound from it; that this boot's settings were applied and
saved on the volume, owned by the greeter user, without the passphrase's
hash; that no Persistent Storage passphrase was left behind, and no
staging directory of the applier's (`settings/staged`, and
`.antumbra-welcome-staging` on the volume); that unlocking the volume
while it is open still refuses a wrong passphrase (both runs); that
administration and the passphrase are in force; and that a file written
to `~/Persistent` lands on the volume. The second run (`--keep-disk`)
checks that the partition holds a LUKS volume, opens it read-only first
to check what the first run stored (administration on, no passphrase
hash, the file in `Persistent`, no staging directory of the applier's),
tries "Unlock" with the right passphrase while `passwd` fails (bound to
`/bin/false`), which must reach the Welcome screen as an unexpected
error with Persistent Storage locked again by then and, read-only again,
nothing of that attempt on the volume, tries "Unlock" with a wrong passphrase
(the error reaches the Welcome screen's wait, `welcome-done` and the
passphrase are gone so that it can start again), then chooses "Unlock"
with the right one, no screen-lock passphrase and administration off
(the wrong attempt's report, still there, must not be taken for this
one's), and checks that the
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

## What the later VM runs found

The runs of the images with Android apps, the camera and Persistent
Storage found these in the system (S) and in the harness (H):

| Symptom in the VM | Cause | Fix |
|---|---|---|
| S: `antumbra-tor-connect direct` and `bridges` always ended in an error | it asked Tor to save its configuration, which Tor may not write | settings applied without SAVECONF |
| S: the applier's private copy of the Welcome settings (passphrase hash included) lived until the network was up | removed only at exit | removed as soon as it has been used |
| S: an error at power-off from Android's post-stop hook | it asked for a unit systemd refuses during shutdown | skipped while the system stops |
| S: Android never finished booting | system_server's Watchdog gave native stack dumps 2 seconds; under emulation each outlasted that and the dumped process died of SIGPIPE, vold's death rebooting Android | `ro.hw_timeout_multiplier=10` in a VM |
| S: no Android app entries, no Android window, F-Droid never ran, `lxc-attach` blocked | Waydroid froze the container when Android's display slept, before Android had unlocked its user | `persist.waydroid.suspend=false` in a VM |
| S: F-Droid's installer gave up | it waited 2 minutes after `waydroid app install`; under emulation the installation takes longer | waits up to 15 minutes |
| S: `/dev/fb0` and the render node stayed open to every user after Android stopped | udev's change events restore no mode for framebuffers and did not restore the render node's | modes recorded before the boot's first container start and put back at stop |
| S: the file indexer restarted every 3 seconds for the whole session | its first start outlasted systemd's timeout under load, leaving a database every later start refused | the indexer is off (hook 52) |
| H: Snapshot's preview was not ready after 30 seconds | the first frame takes about three minutes under emulation | the check waits for the picture |
| H: one slow command made every later check time out | the console's shell kept running it | a timed-out command is interrupted; console timeouts follow `--timeout-scale` |
| H: the full-UI check passed on a picture of the wallpaper | it counted colours | most of the screen must change |
| H: the hot-plugged device's UUID check failed on 133 bytes | it counted the bytes of an `lxc-attach` error | it reads until Android answers and judges the content |

## What the VM cannot tell you

Anything that needs the phone's hardware: the display panel, touch, the
modem policy (`antumbra-modem-radio-off`), the Wi-Fi driver and its
firmware, audio routing, the cameras themselves (CAMSS, the sensors, the
pop-up motor, image quality, whether PipeWire can hold the CAMSS graph),
the bootloader (slot B, AVB), battery and thermal behaviour.
`docs/hardware-validation.md` keeps that list.
