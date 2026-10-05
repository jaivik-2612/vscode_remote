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
    settle push, which could not move it at its stop and failed).
35. `status` is `-r--------`, and `pulse_up`, `restore_closed`, `open`,
    `finish_open` and `close` exist only when the module was loaded with
    `debug_knobs=1`.
