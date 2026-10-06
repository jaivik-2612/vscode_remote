# Hardware validation checklist

For the first boots of Antumbra on a OnePlus 7T Pro HD1913. Record the
result of each item with the build id from `/etc/antumbra-release`.

## Build for testing

Use a debug build for the first attempts (`ANTUMBRA_DEBUG=1`): it keeps
kernel messages visible and does not quiet the console, and it is refused
by `release.sh` so it cannot leak into a release. `flash.sh` takes a
release directory, so flash a debug build by hand (`flashing.md`, "By
hand") with `build/out/boot.img`, `build/out/userdata.simg` and the
port's DTBO and vbmeta from `build/cache/device-assets/`, after backing
up slot B as described there. Keep the slot-B backup. Items 46-55 need an
image built with `ANTUMBRA_ANDROID=1`; item 43 compares the default
libcamera with an image built with `ANTUMBRA_LIBCAMERA_LOCAL=1`.

## Boot chain

1. `fastboot` accepts the boot image; the phone shows the orange state
   screen and the kernel starts (display stays dark until the panel driver
   binds; the first boot can take a minute).
2. The initramfs finds the live partition (`/run/antumbra/loop-device`
   exists after boot; `findmnt /` shows `overlay`).
3. dm-verity: `dmsetup table` shows a verity device for the squashfs; a
   build with `ANTUMBRA_VERITY=0` boots too.
4. `qbootctl -n b` reports the slot successful after the first full boot.
5. Reboot loops: if the kernel panics early, slot B's retry counter falls
   and after seven attempts the bootloader switches to slot A. Confirm the
   counter behaviour and restore with `fastboot set_active b`.

## Display, input, session

6. The panel comes up at 1440x3120, 60 Hz; the greeter's phoc runs with
   scale 3 (`/etc/antumbra/phoc.ini`).
7. Touch works in the Welcome screen; squeekboard appears for text fields.
8. "Start Antumbra" leads to the Phosh session as `amnesia` (check
   `loginctl` for the session and `journalctl -t antumbra-welcome`). The
   Welcome screen and the shell show Antumbra's dark theme (purple
   accent, Roboto); the shell and its lock screen show the eclipse
   wallpaper (the Welcome screen's window is opaque); record whether the
   top bar's items clear the display's rounded corners
   (`known-issues.md`, "Interface").
9. The screen locks on the power button when a passphrase was set and
   unlocks with it; `antumbra-auto-shutdown.timer` is active while locked
   (`systemctl list-timers`) and fires from suspend (set a short
   `OnActiveSec` in a drop-in to test the RTC alarm wake-up).
10. Long press of the power button powers off within about 5 seconds.

## Network and Tor

11. Before the Welcome screen finishes, `ip link` shows no `wlan0`
    (drivers blocked); afterwards `wlan0` exists with a locally
    administered, non-permanent MAC (`ethtool -P wlan0`).
12. `cat /run/antumbra/selfcheck.status`: every line `OK`. Pay attention
    to `qrtr-access`, `modem-radio`, `modem-registration`, `firewall`.
13. `/run/antumbra/modem-mode` says `low-power` or `persistent-low-power`
    and `not-registered`; `qmicli -d qrtr://0 --nas-get-serving-system`
    (as root) agrees. Re-check after a few hours and after a modem crash
    (`dmesg | grep remoteproc`).
14. Wi-Fi connects through Phosh's settings; `nmcli` shows no hostname
    sent; a hidden-network profile is refused.
15. Tor bootstraps (`antumbra-tor-connect status`), `htpdate` sets the
    clock (`/run/htpdate/success`), Tor Browser opens
    `https://check.torproject.org` from inside the `tbb` namespace
    (`ip netns pids tbb`).
16. Leak tests as `amnesia`: `curl http://1.1.1.1` fails; `curl
    --socks5-hostname 127.0.0.1:9050 https://check.torproject.org` works;
    `ping 1.1.1.1` fails; `dig @1.1.1.1 example.com` fails; `getent hosts
    example.com` resolves through Tor's DNSPort. `journalctl -k | grep
    Dropped` shows the rejected attempts.
17. Bridges: enter an obfs4 line with an IPv4 address on the Welcome
    screen and confirm `obfs4proxy` (lyrebird) runs as `debian-tor` and
    Tor bootstraps (`antumbra-tor-connect status`). Do the same with a
    webtunnel line and with a meek_lite line (from the Welcome screen of
    a new session, or as root with `antumbra-tor-connect bridges -`): no
    webtunnel or meek_lite bridge has connected on the phone yet. Start
    refuses, saying why, a snowflake line and an obfs4 line whose address
    is IPv6 (`[2001:db8::5]:443`).

## Amnesia

18. `cat /proc/swaps` lists only `/dev/zram0`.
19. No writable mount of a flash partition (`findmnt -o SOURCE,OPTIONS`).
20. Shutdown returns to the initramfs: `/run/initramfs/shutdown` exists
    while running; on power-off the console (debug build) shows the
    pre-shutdown hook unmounting `/oldroot` and dropping caches.
21. After a reboot nothing from the previous session is on the device
    (`/sys/fs/pstore` empty, `journalctl --list-boots` shows one boot).

## Persistent Storage

22. Create it from the Welcome screen; reboot; unlock it; `~/Persistent`
    is the volume (`findmnt /home/amnesia/Persistent`), Wi-Fi profiles
    persist, and `/var/lib/antumbra/settings/persistent`, the volume's
    Welcome settings, holds this boot's choices and no `tails.password`
    (the Welcome screen does not read them back; `known-issues.md`).
23. A wrong passphrase is refused: the Welcome screen shows the error and
    lets you start again. Started then without Persistent Storage, the
    session is amnesic and the volume is not open (`ls /dev/mapper` as
    root shows no `antumbra_data`).

## Power and radios

24. `lsmod` shows no `bluetooth`, `hci_uart`, `btqca`, `nxp_nci*`.
25. No USB gadget: a PC sees no network or serial device when the phone
    is plugged in; charging works.
26. Suspend (s2idle) and resume keep Wi-Fi and the MAC address.
27. Battery drain overnight with the screen off, Wi-Fi on, modem in
    low-power mode: record the percentage.

## Pop-up camera motor

Kernel patch `0102` (motor safety). The motor follows the front sensor's
runtime power state, so it can be driven without a camera app: as root,
`echo on > /sys/bus/i2c/drivers/imx471/*/power/control` powers the IMX471
and raises the camera, and `echo auto` to the same file lets it idle and
retract. `/sys/bus/platform/devices/camera-popup/status` (root only) shows
the Hall readings, the last course and the sleep state; the driver logs
each course (`dmesg | grep camera-popup`).

28. Lifecycle: `on` raises the camera and `status` shows `endpoint=1
    error=0`; `auto` retracts it. Repeat about 20 times and keep the
    `open stopped: steps=… elapsed_us=…` and `close stopped: …` lines.
    Every normal course must end with `endpoint=1 error=0`, `steps` below
    44160 and `elapsed_us` below `course_cap_us` from `status`. A normal
    course ending in error -34 (microstep budget spent) or -110
    (wall-clock cap) means the budget cuts real courses short.
29. With a camera application (GNOME Snapshot, item 40): the camera
    rises when the preview starts and retracts when it stops, when the
    application is killed with SIGKILL and when the stream fails to
    start.
30. Suspend with the camera down (`auto`, then `rtcwake -m freeze -s 20`):
    no `open stopped`, `close stopped` or `automatic open failed` line
    between `Freezing user space processes` and `Restarting tasks`, where
    the I2C bus to the Hall sensors goes down; the camera stays down and
    `status` shows `sleeping=0` afterwards.
31. Suspend with the camera up (`on`, which looks like a stream held
    across sleep): after `PM: suspend entry` but before `Freezing user
    space processes`, `camera not closed at system sleep` and a `close
    stopped … endpoint=1 error=0`; the camera is down while the phone
    sleeps; after `Restarting tasks`, `raising the camera again for a
    stream held across sleep` and an `open stopped … endpoint=1`. `auto`
    then retracts it. If the retract before sleep fails (`could not
    retract the camera at system sleep` or `cannot read the Hall sensors
    at system sleep`) while no stream holds the camera, the retract is
    retried after resume: `camera not closed at resume` and a `close
    stopped … endpoint=1`. Record any such run.
32. Power-off and reboot with the camera up (`on`, then `systemctl
    poweroff`; again with `systemctl reboot`): the camera retracts before
    the phone goes off (`camera not closed at reboot or power-off` on a
    debug build's console).
33. Boot with the camera up: raise it (`on`), then force a PMIC hard reset
    (power and volume up held until the phone restarts), which runs no
    kernel code. On the next boot, before any camera use, `dmesg` shows
    `camera not closed at probe` and the camera retracts.
34. Hall thresholds on this unit: record `hall_up` and `hall_down` with
    the camera closed and fully raised. The driver's thresholds come from
    one HD1913: closed needs |up| < 50 and |down| >= 340 (that unit read
    about -13 and -369), fully open needs |up| >= 300 and |down| <= 50.
    Readings near a limit mean refused courses or false endpoints on this
    unit. A closed |down| between 340 and 349 matters most: such a camera
    counts as seated, and `auto` must leave it without motion and with
    `error=0` (the driver no longer gives a seated camera the 320-microstep
    settle push, which could not move it at its stop and failed). Also
    record the reading, and whether the camera is flush, after `auto`
    handles a camera reading |down| 340-349 that is short of its stop (for
    example after an interrupted open): without the settle push such a
    camera stays where it is.
35. `status` is `-r--------`, and `pulse_up`, `restore_closed`, `open`,
    `finish_open` and `close` exist only when the module was loaded with
    `debug_knobs=1`.

## Camera userspace

GNOME Snapshot through the camera portal and PipeWire's libcamera node
(`camera.md`). The commands run as `amnesia` in the session; `cam` is not
in the phone image, so the cameras are listed through PipeWire.

36. `dpkg-query -W gnome-snapshot libcamera0.7 libcamera-ipa
    libspa-0.2-libcamera pipewire wireplumber`: libcamera 0.7.1 from
    trixie-backports (or `0.7.2-1~antumbra1` from a build with
    `ANTUMBRA_LIBCAMERA_LOCAL=1`, both libcamera packages at the same
    version), PipeWire 1.6.9, WirePlumber 0.5.12; `megapixels` is not
    installed.
37. `wpctl status` lists four cameras under the video sources, all created
    by libcamera (`pw-dump` shows `"device.api": "libcamera"` for each).
38. The WirePlumber rule: `udevadm info -q property -n /dev/video0` shows
    `ID_V4L_PRODUCT=Qualcomm Camera Subsystem`, and `pw-dump` has no
    device or node with `"device.api": "v4l2"`. If CAMSS's raw nodes do
    appear, record their `device.product.name` and `device.sysfs.path`.
39. First start of Snapshot: Phosh asks "Allow app to Use the Camera?".
    Deny: Snapshot shows no camera and the front camera stays down. The
    answer is remembered for the session; reset it with `busctl --user
    call org.freedesktop.impl.portal.PermissionStore
    /org/freedesktop/impl/portal/PermissionStore
    org.freedesktop.impl.portal.PermissionStore DeletePermission sss
    devices camera ''`, start Snapshot again and allow: the preview
    appears.
40. Front camera in Snapshot: the camera rises before the first preview
    frame and retracts when Snapshot switches to a rear camera, when it
    quits and when it is killed (`pkill -9 snapshot`); `dmesg | grep
    camera-popup` shows one `open stopped` and one `close stopped` per
    course, each with `endpoint=1 error=0`. This is item 29 with
    Snapshot.
41. Orientation and mirroring: with the phone held upright, the front
    preview is upright and mirrored, and the saved picture is upright.
    Record what Snapshot does with each of the four cameras.
42. Each rear camera previews and saves a picture to `~/Pictures/Camera/`;
    the front camera saves a 1748x1748 picture. Nothing shows that a rear
    camera is in use.
43. Exposure and white balance settle within a few seconds indoors and in
    daylight on all four cameras. With a local libcamera build, compare
    against the default build, and check that libcamera no longer warns
    about a missing camera sensor helper for the four sensors
    (`journalctl -b --user | grep -i helper`).
44. PipeWire as the only user of CAMSS: start and stop the front camera 20
    times and switch between all four cameras 20 times; `dmesg | grep -i
    -E 'camss|csid|vfe'` shows no reset timeout and the cameras keep
    working. If a camera stops working, record the messages and whether
    only a reboot recovers it.
45. Suspend while Snapshot streams from the front camera (power button,
    wake after a minute): the camera retracts before the phone sleeps
    (items 30 and 31); after resume Snapshot streams again with the camera
    raised, or shows an error with the camera down. The camera is never
    left raised without a stream.

## Android apps

Only for images built with `ANTUMBRA_ANDROID=1` (`architecture.md`,
section 11.1). The VM covers the network and the setup
(`vm-testing.md`, "Android apps"), not the hardware.

46. With "Android apps" off at the Welcome screen: `ls -l /dev/*binder`
    shows mode 0600, owner root; `ip -4 addr show waydroid-tor` shows
    10.200.2.1/30; the self-check's `firewall-android`, `android-bridge`,
    `binder` and `android-off` lines are OK.
47. With it on: Android's full UI opens from the "Android" launcher.
    Record the time from Start to `waydroid shell getprop
    sys.boot_completed` printing 1, and the memory used (`free -m` before
    and after), with and without Tor Browser open. `journalctl -t
    antumbra-waydroid` has `Android container checked: Tor only, N
    hardware identifiers hidden in its view` from the start-host hook;
    record N.
48. The `arm64` images' 32-bit half runs: `waydroid shell getprop
    ro.product.cpu.abilist` lists `armeabi-v7a`, and `waydroid shell ps -A`
    shows both `zygote64` and `zygote`.
49. Graphics: Android renders on the GPU (`waydroid shell dumpsys
    SurfaceFlinger | grep GLES` names Mesa's Adreno driver, not
    SwiftShader); text at density 480 is readable; touch and Android's
    keyboard work in Android apps; Android windows fit Phosh's screen.
50. Network: F-Droid refreshes its index; an Android browser installed
    from F-Droid shows Tor at <https://check.torproject.org>; on the host,
    `ss -tnp` shows Android's connections only as 10.200.2.2 to
    10.200.2.1:9041 (`tor`), and the counters in `nft list chain ip
    antumbra-nat android` grow. The `.onion` block is in Android's network
    namespace: `nsenter --target "$(lxc-info -P /var/lib/waydroid/lxc -n
    waydroid -pH)" --net nft list table ip antumbra_onion` shows `ip daddr
    127.192.0.0/10 reject`.
51. Audio: an Android app plays through the speakers; recording works
    only after Android's microphone prompt is allowed.
52. Suspend and resume with Android running: Android, Wi-Fi and Tor come
    back; compare overnight battery drain with Android on and off.
53. `waydroid session stop`: the container stops and stays stopped;
    within a minute `waydroid-container.service` is inactive, the binder
    devices and `/dev/dma_heap/*` are 0600 again, and `/dev/dri/renderD128`
    and `/dev/fb0` have udev's modes again (compare `stat -c '%n %a %G'`
    with a boot without Android). The "Android" launcher starts Android
    again.
54. "Keep Android apps and data": install an app, reboot, unlock with the
    switch on and find it; unlock with the switch off and get a fresh
    Android.
55. What apps see: record `uname -a`, `/proc/cpuinfo`,
    `getprop ro.product.model` and the GPU strings inside Android, for
    `threat-model.md`. No serial number: on the host, `/proc/cmdline` has
    `androidboot.serialno=`; inside Android, `cat /proc/cmdline` has
    none, `getprop ro.serialno` and `getprop ro.boot.serialno` do not show
    it, and `/sys/devices/soc0/serial_number`, the UFS device's
    `string_descriptors/serial_number` and every SCSI disk's `vpd_pg80`,
    `vpd_pg83` and `wwid` read empty (the host's `find /sys/devices
    \( -name serial_number -o -name serial -o -name 'vpd_pg8[03]' -o
    -name wwid -o -name cid -o -name uuid -o -name eeprom \) -type f`
    lists them; with Persistent Storage unlocked, its `dm/uuid` too).
    The other identifiers `threat-model.md` lists as masked, inside
    Android: `cat /sys/bus/nvmem/devices/*/nvmem | wc -c` prints 0 and
    `ls -A` of each `/sys/bus/nvmem/devices/*` and `/sys/class/rtc/rtc0`
    prints nothing (on the host, `ls /sys/bus/nvmem/devices` should show
    `qfprom0`; record its size, `wc -c < /sys/bus/nvmem/devices/qfprom0/nvmem`,
    and whether reading it works at all or is refused by the SoC's
    access control); `cat /proc/driver/rtc` prints nothing; every
    partition's `uevent` (`/sys/class/block/sd*[0-9]/uevent`) reads empty;
    `cat /sys/class/net/*/address` shows only `00:16:3e:f9:d3:03` and
    zeros, and `/sys/class/ieee80211` is empty. And record on the host,
    for `threat-model.md`: `cat /sys/class/rtc/rtc0/since_epoch` next to
    `date +%s` once the clock is set (is the RTC a count since the PMIC's
    first power-up, and does `hwclock --systohc` fail?), `lsblk -o
    NAME,PARTUUID` (do the factory partitions' GUIDs match those of
    OnePlus's factory images, or are they this phone's own?), and
    `find /sys/devices -type f -perm -004 \( -name '*serial*' -o -name
    '*uuid*' -o -name '*_id' -o -name 'cid' \)` for anything else of
    the kind.
