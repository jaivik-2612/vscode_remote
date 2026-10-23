# Installing Antumbra for Android on the OnePlus 7T Pro

> **DRAFT. Untested.** Nobody has followed these steps yet. They combine the
> LineageOS wiki's procedure for `hotdog`, Magisk's documentation and
> Antumbra's own parts, none of which has run on the phone. Expect changes
> before the first install, and read everything before starting.

The procedure unlocks the bootloader (which erases the phone), installs
official LineageOS 23.2, installs Magisk, then the Antumbra module, then the
Welcome app as device owner, and ends with a packet capture that checks that
only Tor leaves the phone.

## What cannot be undone

- **The bootloader stays unlocked for good.** Never try to relock it while
  anything but stock OxygenOS is installed: on this phone that can leave it
  unable to boot. A warning that the bootloader is unlocked shows at every
  boot; it is expected.
- **Unlocking erases the phone**, and so does formatting data before
  LineageOS. Back up first; there is no way to bring the data back.
- **Recovery from a failed flash** needs OnePlus's MSM Download Tool, which
  runs only on Windows, and puts the phone into Qualcomm's emergency download
  mode (EDL). On macOS or Linux there is no such recovery.

## Requirements

**Phone**

- A OnePlus 7T Pro model HD1910, HD1911, HD1913 or HD1917 (exact match;
  LineageOS's list). The T-Mobile 7T Pro 5G McLaren (HD1925) is a different
  phone and is not supported. LineageOS's firmware steps are not for
  carrier-branded variants. Check the model on the box or the label as well
  as in Settings: a phone that once ran another system can show another
  model there.
- The latest Android 12 (OxygenOS 12) firmware before LineageOS is installed
  (section 3). LineageOS requires it, even though LineageOS 23.2 is Android
  16.
- Charged above 60%.
- **No SIM card from LineageOS's first boot on** (decision D3: no SIM,
  Wi-Fi only). LineageOS switches mobile data on for a SIM it has not seen
  before, and a SIM connects over the mobile network without any saved
  network or any app: before the module exists, and in any later boot
  without it, that traffic leaves in the clear (`threat-model.md`, *When
  the module does not run*).

**Computer**

- Preferably Windows 10 or 11 with administrator rights: the fastboot
  drivers, and the MSM Download Tool if a recovery is needed. macOS or Linux
  work for every normal step, but offer no recovery from a failed flash.
- Android SDK Platform-Tools (`adb`, `fastboot`), current version, from
  Google.
- A USB-C data cable (some cables carry only power).
- For the capture (section 9): Wireshark (on Windows with Npcap); a way
  to share an Internet connection to the phone through the computer
  (a hotspot) or a network whose traffic the computer can record; Python 3
  and a copy of this repository, for the leak analyser
  (`antumbra/android/ci/leak_analyser.py`, standard library only); `curl`.

**Time**

Two sittings, with the phone usable between them:

1. Unlock, LineageOS and basic checks.
2. Magisk, the module, Welcome and the capture.

Allow 5 to 6 hours in all without failures. If the unlock is refused
(section 2), the detour through OxygenOS 11 erases the phone again and needs
a further full day.

**Files**, downloaded before starting, each with its SHA-256 written down and
checked:

| File | From | Check |
|---|---|---|
| `lineage-23.2-<date>-nightly-hotdog-signed.zip`, and the same build's `boot.img`, `dtbo.img`, `vbmeta.img`, `recovery.img` | https://download.lineageos.org/devices/hotdog/builds | the SHA-256 the page lists (also in https://download.lineageos.org/api/v2/devices/hotdog/builds); keep a copy, since LineageOS keeps only the last few builds |
| Magisk v31.0 APK | https://github.com/topjohnwu/Magisk/releases/tag/v31.0 | SHA-256 to be recorded when it is staged (W15); not another version |
| `antumbra-module-<version>.zip` | Antumbra's release | its SHA-256 and signature; keep an unpacked copy on the computer: section 9 needs its `bin/arm64-v8a/tor` |
| Welcome APK, the build decision D9 chose (release or testOnly, section 8) | Antumbra's release | its SHA-256 and signature |
| Only if the unlock is refused: OnePlus's full rollback package to OxygenOS 11 for the model, and the latest OxygenOS 12 full package | OnePlus | SHA-256 recorded when staged; whether OnePlus still serves `hotdog` packages is **[unknown]** |

If LineageOS 24 (Android 17) has reached `hotdog` by then, the project
decides in its W12 check whether to install 24.0 directly; the module then
needs a release made for it.

## 0. On the stock phone, before anything is erased

1. Note the model, the OxygenOS version and whether the phone came from a
   carrier (Settings, About device). Screenshots shared for support must not
   show the IMEI or the serial number.
2. **If it runs OxygenOS 10 or 11, do not update it** before the unlock
   (section 1): OnePlus 7-series phones on OxygenOS 12 have refused to unlock.
3. Check calls, SMS and Wi-Fi on the stock system, as LineageOS asks. If a
   SIM and a mobile "phone mode" might ever be wanted, make one VoLTE (or
   Wi-Fi calling) call on the stock system now: some phones need it once to
   set up IMS, and it cannot be done later without going back to stock.
   Then power off and take the SIM card out; it stays out (Requirements).
4. Back up whatever is needed. Remove every account (Google, OnePlus)
   so that factory-reset protection does not lock the phone.
5. Settings, About device: tap *Build number* seven times. Developer
   options: turn on *OEM unlocking* (if it is missing, the phone may be a
   carrier variant: stop here) and *USB debugging*.
6. Restart into the bootloader (power off, then hold Volume Up + Volume Down
   + Power) and photograph the screen, including the `DEVICE STATE` line.

## 1. Unlock the bootloader

From the LineageOS wiki (https://wiki.lineageos.org/devices/hotdog/install):

```sh
adb -d reboot bootloader
fastboot devices                  # must list the phone
fastboot oem unlock
```

Confirm on the phone with the volume and power keys. The phone erases itself
and restarts. If `fastboot devices` lists nothing: on Windows, check the
driver in Device Manager; on Linux, the USB permissions; everywhere, the
cable and the port.

Afterwards, set Android up again without any account, and turn on Developer
options and USB debugging again.

## 2. If the unlock is refused

OnePlus 7-series phones on OxygenOS 12 have answered `fastboot oem unlock`
with:

```
FAILED (remote: 'Device cannot be unlocked for technical reason.')
```

The reports are for the OnePlus 7 Pro (GM1913); whether the 7T Pro does the
same is **[unknown]**. If it happens:

1. Stop. Install no update and no other OxygenOS version yet.
2. Roll back to OxygenOS 11 with OnePlus's full rollback package for the
   model, as a local install (Settings, About device, the version card,
   Local install; Developer options must be on). This erases the phone.
3. Set Android up without any account, turn on OEM unlocking and USB
   debugging again, and unlock (section 1).
4. Go back to the latest OxygenOS 12 with its full package (section 3).

A step-by-step version of this branch, with the expected output of each
command, is part of the install runbook (W14).

## 3. The Android 12 firmware

LineageOS for `hotdog` needs the latest Android 12 (OxygenOS 12) firmware on
the phone before it is installed ("check the Android version, not the vendor
OS version"). A phone that was unlocked on OxygenOS 10 or 11 is now updated
to it:

- Install the latest OxygenOS 12 full package as a local install. An A/B
  update writes only the slot Android is not running from, so install the
  same full package a second time to put it in both slots (each install moves
  Android to the other slot; `adb shell getprop ro.boot.slot_suffix` shows
  which). Whether OxygenOS accepts installing the build it already runs is
  **[unknown]**.
- Restart once more and wait a few minutes after the last install, so the
  update finishes merging before fastboot is used.

LineageOS builds for `hotdog` carry the firmware partitions themselves, so
later LineageOS updates keep the firmware in step. The wiki's firmware-update
page (https://wiki.lineageos.org/devices/hotdog/fw_update) flashes the
Android 12 firmware images to both slots from LineageOS Recovery's fastboot
mode; it is the fallback if the firmware turns out to be older than required.

## 4. Install official LineageOS 23.2

From the LineageOS wiki, in this order. Do not continue after anything fails.
Check first that the SIM tray is empty: LineageOS's first boot would
otherwise go online over mobile data, in the clear.

1. Flash the boot-stack partitions of the downloaded build:

   ```sh
   adb -d reboot bootloader
   fastboot flash dtbo dtbo.img
   fastboot flash vbmeta vbmeta.img
   fastboot reboot bootloader
   ```

2. Flash LineageOS Recovery and start it:

   ```sh
   fastboot flash recovery recovery.img
   ```

   Then choose *Recovery* in the bootloader's menu (volume keys to move,
   power to select). LineageOS Recovery shows the LineageOS logo; another
   recovery means a step was missed.
3. In recovery: *Factory Reset*, *Format data / factory reset*. This erases
   everything, again. Back to the main menu.
4. *Apply update*, *Apply from ADB*, then:

   ```sh
   adb -d sideload lineage-23.2-<date>-nightly-hotdog-signed.zip
   ```

   A signature failure means the file is damaged or not official: download
   it again. adb may stop at 47% with `adb: failed to read command: Success`
   (or `No error`, or `Undefined error: 0`); that is normal.
5. When asked whether to reboot to recovery to install add-ons: *No*. Install
   no Google Apps or other add-ons.
6. *Reboot system now*. The first boot can take up to 15 minutes.

## 5. First boot and basic checks

1. Skip every account in the setup wizard. **Do not join a Wi-Fi network**
   unless the check below needs it, and keep the SIM out: until the module
   is installed, the phone talks to LineageOS's and Google's servers in the
   clear, and any saved network stays on flash until the module's first
   boot deletes it.
2. Check the camera. A Wi-Fi check, if done, uses a network that may learn
   that a LineageOS phone was there. Calls were checked on the stock system
   (section 0); if they must be checked on LineageOS too, do it only after
   section 7, with the firewall live: power off, insert the SIM, start,
   check `antumbra.fw.armed`, make the call, power off and take the SIM out
   again. The firewall then refuses the SIM's mobile data outside Tor, but
   the carrier learns that this SIM was in this phone. Whether VoLTE
   registers behind the firewall is **[unknown]**.
3. Settings, About phone: tap *Build number* seven times; turn on *USB
   debugging* in Developer options. Leave *Rooted debugging* off.
4. Write down the LineageOS build date; releases name the build they were
   checked against.

## 6. Magisk v31.0

Following Magisk's installation guide
(https://github.com/topjohnwu/Magisk/blob/v31.0/docs/install.md). Use
v31.0, the version Antumbra has read and tested against, not the newest.

1. Install the Magisk APK whose SHA-256 was checked:

   ```sh
   adb install Magisk-v31.0.apk
   adb push boot.img /sdcard/Download/boot.img     # the same build's boot.img
   ```

2. In the Magisk app: *Install*, *Select and Patch a File*, choose
   `boot.img`. Then:

   ```sh
   adb pull /sdcard/Download/magisk_patched-<...>.img magisk_patched.img
   adb -d reboot bootloader
   fastboot flash boot magisk_patched.img
   fastboot reboot
   ```

   Patch the image on this phone only, never use one patched elsewhere.
3. Open the Magisk app and accept its environment fix; the phone restarts.
4. Magisk settings:
   - *Multiuser mode*: **Device owner only**. In Magisk, "owner" means
     Android's first user (user 0), not the device-owner app. This denies
     root to every other Android user, which is where sessions run from W8.
   - If the version offers *Superuser access*, set it to **ADB only** for
     the install (sections 7 to 9 may need a root shell over the cable,
     and Magisk asks on the phone each time) and to **Disabled** at the end
     of section 9. Antumbra does not rely on it.
   - *Check for updates*: off.
   - Grant root to no app.

## 7. The Antumbra module

1. Copy the checked module zip to the phone:

   ```sh
   adb push antumbra-module-<version>.zip /sdcard/Download/
   ```

2. In the Magisk app: *Modules*, *Install from storage*, choose the zip.
   The installer refuses any phone that is not a `hotdog` running LineageOS
   on Android 16, and any file whose SHA-256 differs from the zip's list.
3. Restart. From now on the firewall is armed before Android starts, saved
   Wi-Fi networks live only in RAM, mobile data is stored as off for every
   SIM Android knows, and the network stays closed until the Welcome
   screen's Start. USB (adb) keeps working for now: it does not go through
   the network (it ends in section 8).
4. Check, without root:

   ```sh
   adb shell getprop antumbra.fw.armed     # 16 hex digits: the live firewall
   ```

   An empty answer means the firewall is not live: stop, and collect the
   module's log before the next restart (it is kept in RAM):
   `adb exec-out su -c 'cat /data/adb/antumbra/log/module.log' > module.log`
   (Magisk asks on the phone whether to grant the shell root).

**Phone mode stays shut until PH3 (WEL8).** As installed, the Welcome
screen shows *Calls and texts* and *Mobile data, through Tor* as "Not
available yet", and the module keeps the cellular radio and mobile data
off in every session, whatever is chosen: the per-phone gate, the
root-only file `/data/adb/antumbra-cell`, does not exist. Only PH3 opens
it:

- For PH3's measurement (with the SIM PIN-locked, D3), write it as root
  while adb still answers: here, before section 8, or in the install
  sitting with the testOnly build's hook. The module reads it at its next
  turn; a session started before that keeps the radio off until the next
  start. Type each command as it stands: the outer double quotes hand the
  whole line to the phone, and the single quotes hand it to `su` as one
  command, so that root writes the file. (Without them the phone's shell,
  which is not root, would try to write the file itself, fail, and never
  run `su`.)

  ```sh
  adb shell "su -c 'echo phone > /data/adb/antumbra-cell && chmod 0600 /data/adb/antumbra-cell'"
  adb shell "su -c 'ls -l /data/adb/antumbra-cell; cat /data/adb/antumbra-cell'"
  ```

  The second command must show `-rw-------`, `root root` and `phone`.
- Keep it only for outcome A, or B once FW6 passes, and only if MOD11's
  checks in PH3 read as expected. Otherwise delete it
  (`adb shell "su -c 'rm -f /data/adb/antumbra-cell'"`); without adb, take
  the SIM out, remove the module in the Magisk app (its removal deletes
  the gate), restart and install the module again. A gate deleted during
  a session holds for the rest of it: written again, it counts from the
  next start.
- Never write `data` on the phone: mobile data through Tor waits for FW9
  and CI12, and until a release says otherwise the module reads `data` as
  `phone` on a phone anyway.

**The SIM PIN.** Android asks for it at each start on its own screen,
which comes up over the Welcome screen; Welcome cannot type it, and its
red warning that the add-on is not running cannot be seen behind that
screen. So decide from what you know at that moment. Type the PIN only
after a start you know to be normal: nothing (Antumbra, LineageOS or
Magisk) was updated since the last start whose Welcome screen showed no
red warning, and you did not hold a volume key while the phone started
(that is Magisk's Safe Mode, which starts it without the add-on and its
firewall). Otherwise do not type it: if you need help, use only the PIN
screen's emergency call button, and restart the phone.

- After an update, make the first start without the SIM card: with no SIM
  there is no PIN screen, and the Welcome screen shows whether the add-on
  runs. If it shows no red warning, power off, put the SIM card back and
  start again: that start counts as normal.
- If the PIN screen lets you back to the Welcome screen without the PIN,
  check first that it shows no red warning. Whether it can be left on this
  phone is not known yet: PH3 and PH4 record it here, and this text
  follows.

DOC4 rewrites the rest of this guide's SIM text.

## 8. Welcome as device owner

The phone must have no account at this point (`dpm` refuses otherwise).

**adb ends here.** Welcome switches USB debugging off the moment it becomes
the device owner, and keeps it off at every boot and in every session,
Administration included (`../welcome/README.md`, Device-owner policies). Do
everything that needs adb before this step.

Which Welcome build the phone gets is decision D9, taken before RC1
(`queue.md`):

- **A release build** can only be removed by a factory reset, and replaced
  only by an app signed with the same key. adb stays off for good:

  ```sh
  adb install Welcome.apk
  adb shell dpm set-device-owner org.antumbra.welcome/.AdminReceiver   # adb goes away here
  ```

- **A testOnly build** can be removed again over adb. It honours a test hook
  that keeps USB debugging on in every session, across restarts, until it
  is switched off; set it before `dpm`, or it is too late. Use it only for
  the install sitting, for the consensus copy in section 9: adb on an
  unlocked, rooted phone is a way in for anyone who holds it.

  ```sh
  adb install -t Welcome.apk
  adb shell setprop debug.antumbra.keep_adb 1        # before set-device-owner
  adb shell dpm set-device-owner org.antumbra.welcome/.AdminReceiver
  ```

Welcome becomes the home screen at once, locks the screen to itself, applies
its policies and turns Wi-Fi off and locks it until Start.

Restart. The Welcome screen must show no red banner (a banner means the
add-on is not running or Welcome is not the device owner). Start the session
in section 9, so that the capture sees it from the beginning.

## 9. The capture

The capture is PH1's acceptance test: only Tor leaves the phone. The
computer records the phone's traffic on its hotspot (or on a network it can
record) from before the phone joins it, through Tor's connection, to a
quarter of an hour of use. The CI's leak analyser then judges every packet.

Before starting, on the computer: the hotspot set up, Wireshark ready on
the hotspot's network interface, this repository, and the unpacked module
zip (its `bin/arm64-v8a/tor` names the fallback directories tor contacts
before it has a consensus).

1. **The phone** shows the Welcome screen of a fresh start: restart it if a
   session already ran, so that the capture sees tor's bootstrap.
2. **The computer** starts recording. Write down the time in UTC.
3. **The phone:** choose *Connect to Tor directly* (or bridges: keep the
   lines in a file `bridges.txt` on the computer), keep *New Wi-Fi hardware
   address* on, leave *Administration* off (the capture tests the everyday
   setting; Administration does not bring adb back either) and press *Start
   Antumbra*.
4. Join the hotspot in Settings, Wi-Fi. Write down the phone's IP address
   on it (Settings, Wi-Fi, the network, its details).
5. Wait until the status screen shows Tor connected, then use the phone for
   about 15 minutes: Settings, the Updater, the apps LineageOS ships.
6. **The consensus the phone's tor used**, which tells the analyser which
   addresses are Tor relays. A consensus from another time can lack relays
   this session used. Either:
   - **(a) copied from the phone in this same session, before any
     restart** (tor's data directory is in RAM and is gone at the next
     start), possible only while adb is on (a testOnly Welcome with the
     test hook, section 8). Magisk's *Superuser access* is still on *ADB
     only* (section 6); Magisk asks on the phone whether to grant the shell
     root: grant it, for this copy only.

     ```sh
     adb exec-out su -c 'cat /data/adb/antumbra/state/tor/cached-microdesc-consensus' \
         > cached-microdesc-consensus
     adb shell ip addr > ip-addr.txt          # the phone's addresses, for --expect-guest
     head -n 2 cached-microdesc-consensus     # network-status-version 3 microdesc
     ```

   - **(b) from the Tor Project's archive, CollecTor**, which keeps every
     hourly consensus as the directory authorities published it. Take every
     hourly one from the full hour 3 hours before step 2 (a consensus is
     valid for 3 hours) to the end of the capture, in UTC, and join them
     into one file. The last 4 days or so are in
     https://collector.torproject.org/recent/relay-descriptors/microdescs/consensus-microdesc/,
     older months in
     https://collector.torproject.org/archive/relay-descriptors/microdescs/
     (one `microdescs-YYYY-MM.tar.xz` per month). For a capture from 14:20
     to 14:55 UTC on 27 January 2027:

     ```sh
     base=https://collector.torproject.org/recent/relay-descriptors/microdescs/consensus-microdesc
     for h in 11 12 13 14; do
         curl -fsS --proto =https -O "$base/2027-01-27-$h-00-00-consensus-microdesc"
     done
     cat 2027-01-27-1[1-4]-00-00-consensus-microdesc > cached-microdesc-consensus
     ```

7. **The computer:** stop recording, save the capture as `phone.pcapng`, and
   write down the time in UTC.
8. **Judge it:**

   ```sh
   python3 -B antumbra/android/ci/leak_analyser.py analyse --scenario phone \
       --network lan --judge-from-start --require-tor-traffic \
       --pcap phone.pcapng --guest <the phone's address> \
       --consensus cached-microdesc-consensus \
       --tor-binary <unpacked module zip>/bin/arm64-v8a/tor \
       --out phone.json        # add: --bridges bridges.txt, --expect-guest ip-addr.txt
   echo "exit status: $?"
   python3 -B antumbra/android/ci/leak_analyser.py report --in phone.json \
       --json leak-report.json --md leak-report.md
   ```

   `--network lan` attributes frames to the phone by its addresses, not by
   the emulator's layout; `--judge-from-start` judges every packet in the
   capture (the phone joined the network after the firewall was live, so
   nothing in it comes from before); `--require-tor-traffic` refuses a
   capture without Tor traffic; `--bridges` when the session used bridges;
   `--expect-guest` (after (a)) makes the result `blind` if the phone had an
   address the capture never saw, for example on mobile data.

   **Only `phone: pass` with exit status 0 counts.** Every flow is then a
   Tor relay or directory, a configured bridge, or link-level (ARP, DHCP to
   the hotspot). `fail` (exit 1) is a leak: stop using the phone on
   networks until it is understood. `blind` (exit 3): the capture cannot
   prove anything (no Tor traffic, or a missed interface); record again.
   `error` (exit 2): an input is missing or unreadable. `info` means the
   command lacked `--judge-from-start`: nothing was judged.
9. **The DHCP host name.** Android 15 and later send the device's name in
   DHCP (option 12), from below the firewall, unless Welcome's restriction
   holds (`threat-model.md`). The analyser judges it: a DHCP message with a
   host name is a LEAK (`dhcp-hostname`) and makes the verdict `fail`. To
   see it by hand:

   ```sh
   grep '"hostname"' phone.json       # must print nothing
   ```

   A line here, naming the phone or its model, is a finding to report. The
   vendor class `android-dhcp-16` is expected.
10. **Close the session's openings:** after (a), revoke the shell in
    Magisk's *Superuser* list and switch the test hook off
    (`adb shell setprop debug.antumbra.keep_adb 0`; debugging goes off at
    the next restart). In every case set Magisk's *Superuser access* to
    **Disabled**.

A root `tcpdump` on the phone's `wlan0` (only while adb is on) is a weaker
fallback when no computer capture is possible; it does not see what the
firmware sends by itself. It is judged the same way.

Also note for the project: the time from power-on to the Welcome screen, the
battery over the following 24 hours, and whether the clock is right.

## Updates

**Weekly LineageOS updates**, the Antumbra way:

1. Settings, System, Updater: download and install the update. Do not
   restart yet.
2. Magisk app: *Install*, **Install to inactive slot (After OTA)**. This puts
   Magisk, and with it the module and the firewall, into the slot the update
   was written to.
3. Restart from the Magisk app.
4. Before joining a network, check that the Welcome screen shows no red
   banner: Welcome reads `antumbra.fw.armed` (section 7), and adb is off
   once Welcome is the device owner.

Restarting after step 1 without step 2 starts the phone without the module,
and so without the firewall. The phone then has no saved network and Welcome
keeps Wi-Fi off, but a network joined by hand connects in the clear, and so
would a SIM with mobile data on (Requirements). Until Welcome has an update
flow of its own, the Magisk app must be reachable for step 2: it is, after
Start.

**Major upgrades** (for example 23.2 to 24) are not offered by the Updater;
they go through `adb sideload` from a computer, in LineageOS Recovery, whose
adb does not depend on Android's USB debugging
(https://wiki.lineageos.org/devices/hotdog/upgrade/). The sideload replaces
the boot image, so Magisk and the firewall are gone until Magisk is
installed again (section 6, with the new build's `boot.img`) in the same
sitting, before any network is used. With Welcome as device owner, Android's
adb is off: move `boot.img` and the patched image with USB file transfer
instead of `adb push` and `adb pull`. The module needs a release made for
the new Android version.

**Module updates** are installed by hand from Antumbra's release (section
7), after checking the SHA-256 and the signature. Magisk never fetches them.

## If something goes wrong

- **The phone does not boot after the module was installed:** while USB
  debugging is on (before section 8, or with the test hook),
  `adb shell magisk --remove-modules` removes every module and restarts.
  Otherwise Magisk's Safe Mode (Magisk's FAQ: hold Volume Down from some
  seconds before the boot animation and release it when the animation
  appears) disables every module. **The Safe Mode boot has no firewall**
  (Magisk runs no module and no boot script in it). The modules stay
  disabled for later boots too; those boots are armed by the module's early
  arm script and have no network at all until the module is on again. Use
  Safe Mode only to remove or fix the module, then turn the module back on
  in the Magisk app and restart. Keep the phone off every network meanwhile.
- **Back to stock LineageOS:** two steps, since Welcome stays the device
  owner when the module goes, and without `antumbra.fw.armed` it keeps Wi-Fi
  off and locked: the phone has no Wi-Fi at all, not stock behaviour, until
  Welcome is removed.
  1. Remove the module in the Magisk app and restart; the module's removal
     script puts back the Settings it changed. Saved Wi-Fi networks are not
     restored (there are none on flash), and mobile data stays off for each
     SIM Android knew (switch it on in Settings if wanted).
  2. Remove Welcome. A testOnly build, while the test hook keeps adb on:

     ```sh
     adb shell setprop debug.antumbra.keep_adb 0
     adb shell dpm remove-active-admin org.antumbra.welcome/.AdminReceiver
     adb uninstall org.antumbra.welcome
     ```

     A release build, or a testOnly build without adb: only a factory reset
     (Settings, System, Reset options, *Erase all data*, or LineageOS
     Recovery's *Factory reset*). It also erases the Magisk app and every
     module; Magisk's patched boot image stays until the build's own
     `boot.img` is flashed (`fastboot flash boot boot.img`).
- **A failed flash:** do not relock the bootloader. LineageOS Recovery and
  fastboot can usually repair it; otherwise the MSM Download Tool on Windows.

## Sources

- https://wiki.lineageos.org/devices/hotdog/ and its install, firmware-update,
  update and upgrade pages
- https://download.lineageos.org/api/v2/devices/hotdog/builds
- Magisk v31.0: `docs/install.md` and `docs/guides.md` in its repository, and
  its changelog
- The unlock refusal and the OxygenOS 11 detour: the archived Debian
  project's research (`../../docs/flashing.md`)
- Antumbra's parts: `../module/README.md`, `../welcome/README.md`,
  `../ci/README.md`, `../ci/leak_analyser.py` (its usage text)
- Tor consensuses: CollecTor,
  https://collector.torproject.org/recent/relay-descriptors/microdescs/consensus-microdesc/
  and https://collector.torproject.org/archive/relay-descriptors/microdescs/
  (both listed on 2026-10-11)
