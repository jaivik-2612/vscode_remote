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
