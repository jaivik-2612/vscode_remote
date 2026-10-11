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

**Computer**

- Preferably Windows 10 or 11 with administrator rights: the fastboot
  drivers, and the MSM Download Tool if a recovery is needed. macOS or Linux
  work for every normal step, but offer no recovery from a failed flash.
- Android SDK Platform-Tools (`adb`, `fastboot`), current version, from
  Google.
- A USB-C data cable (some cables carry only power).
- For the capture (section 9): Wireshark (on Windows with Npcap), and a way
  to share an Internet connection to the phone through the computer
  (a hotspot) or a network whose traffic the computer can record.

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
| `antumbra-module-<version>.zip` | Antumbra's release | its SHA-256 and signature |
| Welcome APK | Antumbra's release | its SHA-256 and signature |
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
   unless the check below needs it: until the module is installed, the phone
   talks to LineageOS's and Google's servers in the clear, and any saved
   network stays on flash until the module's first boot deletes it.
2. Check the camera and, if wanted, calls. A Wi-Fi check, if done, uses a
   network that may learn that a LineageOS phone was there.
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
   - If the version offers *Superuser access*, set it to **Disabled** once
     the module is installed. Antumbra does not rely on it.
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
   Wi-Fi networks live only in RAM, and the network stays closed until the
   Welcome screen's Start. USB (adb) keeps working: it does not go through
   the network.
4. Check, without root:

   ```sh
   adb shell getprop antumbra.fw.armed     # 16 hex digits: the live firewall
   ```

   An empty answer means the firewall is not live: stop, and collect the
   module's log before the next restart (it is kept in RAM).

## 8. Welcome as device owner

The phone must have no account at this point (`dpm` refuses otherwise).

```sh
adb install Welcome.apk                 # a debug build needs: adb install -t
adb shell dpm set-device-owner org.antumbra.welcome/.AdminReceiver
```

Welcome becomes the home screen at once, locks the screen to itself, applies
its policies and turns Wi-Fi off until Start. Whether the phone's Welcome is a
removable test build or a release build is decided before RC1 (`queue.md`):
a release device owner can only be removed by a factory reset, and replaced
only by an app signed with the same key.

Restart, then:

1. The Welcome screen shows no red banner (a banner means the add-on is not
   running or Welcome is not the device owner).
2. Choose *Connect to Tor directly* (or bridges), keep *New Wi-Fi hardware
   address* on, leave *Administration* and *Unsafe Browser* off, and press
   *Start Antumbra*. Without Administration, USB debugging switches off for
   the session.
3. Join the capture network in Settings, Wi-Fi.
4. The status screen shows Tor's progress and the tracker filter's counters.

## 9. The capture

Record the phone's traffic on the computer's hotspot (or the network the
computer can record) from before the phone joins it until Tor has connected
and a few apps have been opened. Then judge every packet with the CI's leak
analyser, giving it the consensus the phone's tor downloaded and the phone's
address on the capture network:

```sh
python3 -B antumbra/android/ci/leak_analyser.py analyse --scenario phone \
    --pcap phone.pcap --consensus cached-microdesc-consensus \
    --guest <the phone's address> --out phone.json
python3 -B antumbra/android/ci/leak_analyser.py report --in phone.json \
    --json leak-report.json --md leak-report.md
```

The consensus is `/data/adb/antumbra/state/tor/cached-microdesc-consensus`,
readable only as root: in an Administration session, grant the shell root in
Magisk for this one copy, then revoke it. Every flow must be a Tor relay or
directory, a configured bridge, or link-level (ARP, DHCP). Anything else is
a leak: stop using the phone on networks until it is understood. A root
`tcpdump` on the phone's `wlan0` is a weaker fallback when no computer
capture is possible; it does not see what the firmware sends by itself.

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
4. Check `antumbra.fw.armed` (section 7) before joining a network.

Restarting after step 1 without step 2 starts the phone without the module,
and so without the firewall. The phone then has no saved network and Welcome
keeps Wi-Fi off, but a network joined by hand connects in the clear. Until
Welcome has an update flow of its own, the Magisk app must be reachable for
step 2.

**Major upgrades** (for example 23.2 to 24) are not offered by the Updater;
they go through `adb sideload` from a computer
(https://wiki.lineageos.org/devices/hotdog/upgrade/). The sideload replaces
the boot image, so Magisk and the firewall are gone until Magisk is
installed again (section 6, with the new build's `boot.img`) in the same
sitting, before any network is used. The module needs a release made for the
new Android version.

**Module updates** are installed by hand from Antumbra's release (section
7), after checking the SHA-256 and the signature. Magisk never fetches them.

## If something goes wrong

- **The phone does not boot after the module was installed:** with USB
  debugging on, `adb shell magisk --remove-modules` removes every module and
  restarts. Otherwise Magisk's Safe Mode (Magisk's FAQ: hold Volume Down from
  some seconds before the boot animation and release it when the animation
  appears) disables every module. **Safe Mode leaves the modules disabled for
  later boots too, and with them the firewall**: use it only to remove or fix
  the module, then turn the module back on in the Magisk app and restart.
- **Back to stock LineageOS:** remove the module in the Magisk app and
  restart; the module's removal script puts back the Settings it changed.
  Saved Wi-Fi networks are not restored (there are none on flash).
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
  `../ci/README.md`
