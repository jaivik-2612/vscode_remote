# Hardware validation checklist

For the first boots of Antumbra on a OnePlus 7T Pro HD1913. Record the
result of each item with the build id from `/etc/antumbra-release`.

## Build for testing

Use a debug build for the first attempts (`ANTUMBRA_DEBUG=1`): it keeps
kernel messages visible and does not quiet the console, and it is refused
by `release.sh` so it cannot leak into a release. Keep the slot-B backup
from `flash.sh`.

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
   `loginctl` for the session and `journalctl -t antumbra-welcome`).
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
17. Bridges: enter an obfs4 line on the Welcome screen and confirm
    `obfs4proxy` (lyrebird) runs as `debian-tor`.

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
    persist, Welcome settings persist.
23. A wrong passphrase is refused and the session still starts amnesic.

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
29. Once a camera app ships: the camera rises when the preview starts
    and retracts when it stops, when the app is killed with SIGKILL and
    when the stream fails to start.
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
    then retracts it.
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
    unit.
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
    course, each with `endpoint=1 error=0`. This is item 29 with a real
    application.
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
    and after), with and without Tor Browser open.
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
    antumbra-nat android` grow.
51. Audio: an Android app plays through the speakers; recording works
    only after Android's microphone prompt is allowed.
52. Suspend and resume with Android running: Android, Wi-Fi and Tor come
    back; compare overnight battery drain with Android on and off.
53. `waydroid session stop`: the container stops, the binder devices are
    0600 again, and `/dev/dri/renderD128`, `/dev/dma_heap/*` and
    `/dev/fb0` have udev's modes again.
54. "Keep Android apps and data": install an app, reboot, unlock with the
    switch on and find it; unlock with the switch off and get a fresh
    Android.
55. What apps see: record `uname -a`, `/proc/cpuinfo`,
    `getprop ro.product.model` and the GPU strings inside Android, for
    `threat-model.md`.
