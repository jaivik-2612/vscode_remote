# Termux preview: setting up the phone

Open this page in the OnePlus 7T Pro's own browser; no GitHub account is
needed. It holds the official download links and the commands for setup
steps 7 to 9. To run a grey box: tap its copy button (top right), switch
to Termux, long-press the screen, tap **Paste**, then press Enter. Paste
each box whole.

## What the preview is, and what it is not

A **look-and-feel preview** of Antumbra: Debian's real Phosh shell and
GNOME apps with Antumbra's theme, icons and settings, running inside
Android through **Termux** (a Linux terminal app), **proot-distro** in it
(Linux programs without root) and **Termux:X11** (an app that shows Linux
windows). It shows the real size on the screen, the fonts, the icons, the
tap targets and typing with real fingers.

It is **not** Antumbra the operating system. Android stays installed and
nothing on the phone changes. There is no Tor, no amnesia, no firewall,
no Welcome screen as a real login screen, no Persistent Storage, no
Android apps, no camera and no battery reading. The main processor draws
everything, not the graphics chip, so its speed says nothing about the
phone's speed under Antumbra.

Antumbra's session has run inside a plain X server on a build computer
([the nested-Phosh experiment](experiment/README.md)), never yet on a
phone; step 9 is the first check there.

> **Privacy: the preview is not private.**
> It uses Android's normal network, not Tor, and proot-distro sets its
> DNS to Google's (8.8.8.8).
>
> - Do not sign in to anything inside it, and do not use it for browsing.
> - Keep nothing personal in Termux. Do not give it access to your
>   files (do not run `termux-setup-storage`).
> - Install Termux and its add-ons only from the links on this page.
> - Once the apps are installed, switch **Install unknown apps** off
>   again for your browser (Settings, search for "unknown apps"). Turn
>   it on again only while installing next week's add-on from this page.
> - Send the screenshots to Claude. Do not post them in this repository.

## Step 7: Termux (5 min)

1. Open the release page
   <https://github.com/termux/termux-app/releases/tag/v0.118.3>
   (v0.118.3, marked "Latest"; ignore the "v0.119.0-beta" pre-releases).
   Under **Assets**, tap
   `termux-app_v0.118.3+github-debug_arm64-v8a.apk` (33.5 MB).
2. If the browser warns that the file may be harmful, choose to download
   it anyway, then open it. Android says the browser may not install
   unknown apps: tap **Settings**, turn on **Allow from this source**, go
   back and tap **Install**.
3. Open Termux once. It unpacks its base system (nothing is downloaded)
   for a few seconds, until a line ending in `$` appears.
4. Battery: search Settings for "battery optimization" (the path differs
   between OxygenOS versions), show **All apps**, pick **Termux** and
   choose **Don't optimize**.

**Do not mix sources.** Play Store and F-Droid builds are signed with
other keys, and Termux and its add-ons work together only when all come
from one place. Uninstall any other Termux first (this erases its files).

**Never install a Termux "update" from anywhere else.** Termux's own
README says the GitHub builds are "signed with a test key that has been
shared with community", and that "Everyone is able to use it to forge a
malicious Termux update installable over the GitHub build"
([Termux README](https://github.com/termux/termux-app#github)). So take
Termux files only from github.com/termux, never from other sites or people.

## Step 8: phone facts (3 min)

Paste this into Termux. It reads Android's system properties, needs no
root, and never prints the serial number or the IMEI.

```sh
(
f() { v=$(/system/bin/getprop "$2"); printf '%-17s %s\n' "$1" "${v:-(empty)}"; }
echo '--- Antumbra phone facts ---'
f 'Model'            ro.product.model
f 'OxygenOS build'   ro.build.display.id
f 'Android version'  ro.build.version.release
f 'Android level'    ro.build.version.sdk
f 'Screen density'   ro.sf.lcd_density
f 'Slot (info only)' ro.boot.slot_suffix
f 'Verified boot'    ro.boot.verifiedbootstate
f 'Flash locked'     ro.boot.flash.locked
f 'Device state'     ro.boot.vbmeta.device_state
echo '--- end ---'
)
```

| Line | What it means |
|---|---|
| Model | for example HD1913. The label or the box decides: a phone that once ran another system can show a different model here |
| Android level | 29 = Android 10, 30 = Android 11, 31 = Android 12, 32 = Android 12L |
| Screen density | the phone's built-in density (changing Display size does not alter it) |
| Slot (info only) | `_a` or `_b`, the half of the phone Android runs from. **For information only**: it changes with every OxygenOS install, so it is read again on install day |
| Verified boot | `green` = bootloader locked, `orange` = unlocked |
| Flash locked, Device state | `1` and `locked`, or `0` and `unlocked` |

Some builds hide the `ro.boot` values from apps and show `(empty)`. That
is fine: the bootloader-screen photo (step 6) answers the same questions.

**Take a screenshot of the output and send it to Claude.**

## Step 9: Termux:X11 check (10 min)

1. Open the release page
   <https://github.com/termux/termux-x11/releases/tag/nightly> and under
   **Assets** tap `termux-x11-universal-sharedUid-debug.apk` (about
   14 MB; "universal" includes arm64). Take **sharedUid**, not
   `termux-x11-universal-debug.apk`: it runs as part of Termux, so
   Android does not slow Termux down while Termux:X11 is on screen, and it
   works only with Termux from GitHub. "Nightly" is rebuilt from time to
   time; the page always has the newest.
2. Install it as in step 7, then set Termux:X11 to **Don't optimize** as
   well, if it appears in the battery list.
3. In Termux, update it and install the X server's command and a small
   display-information tool (a few minutes; `--force-confnew` takes the
   new version of any settings file instead of asking):

   ```sh
   pkg upgrade -y -o Dpkg::Options::=--force-confnew &&
     pkg install -y x11-repo &&
     pkg install -y termux-x11-nightly xorg-xdpyinfo
   ```

4. Start the X server in the background:

   ```sh
   termux-x11 :0 >"$PREFIX/tmp/x11-check.log" 2>&1 &
   ```

5. Open the **Termux:X11** app: a black screen is expected, as nothing
   draws on it yet. Go back to Termux (the recent-apps view).
6. Paste the check and **send a screenshot of its output to Claude**:

   ```sh
   (
   x=$(xdpyinfo -display :0 2>&1) || { printf '%s\n' "$x" | tail -n 3; echo 'No X server on :0: check 9.3, then repeat 9.4 and 9.5'; exit 1; }
   echo '--- Termux:X11 check ---'
   for e in XFIXES XInputExtension Present MIT-SHM DRI3; do
     if printf '%s\n' "$x" | grep -qE "^ +$e\$"; then echo "$e: yes"; else echo "$e: NO"; fi
   done
   xdpyinfo -display :0 -ext XInputExtension -ext MIT-SHM |
     grep -E '^(XInputExtension|MIT-SHM) version|shared pixmaps' | sed 's/ opcode:.*//'
   printf '%s\n' "$x" | grep -E '^vendor string|^X.Org version|dimensions|resolution'
   echo '--- end ---'
   )
   ```

   The preview needs XFIXES, XInputExtension (version 2 or later),
   Present and MIT-SHM; DRI3 is optional. Claude reads the rest.
7. Stop it: in the Termux:X11 notification tap **Exit**, then in Termux:

   ```sh
   pkill -f termux-x11
   ```

## Coming next week (nothing to do yet)

- **Termux:Widget** (step 12, home-screen shortcuts): its official link.
- **The background-process fix** (step 13). Android 12 stops background
  "child" processes once all apps together run more than 32 of them, and
  also ones that use a lot of processor time: the "phantom process
  killer". Termux then shows `[Process completed (signal 9) - press
  Enter]`. The preview runs about ten such processes. The fix is done
  from Termux itself through **Wireless debugging**, with no computer and
  no root. What it needs depends on the Android level from step 8: 30,
  nothing; 31, two commands; 32, one setting.
  **It must be undone before any OxygenOS update or install**; the undo
  command will be kept in this section. If you plan the F.22 reinstall
  (step 10), do it before the fix.
- **The preview installer** (step 14): one line to paste into Termux. It
  can be run again safely and writes a short log to screenshot. It
  installs Debian trixie inside Termux, started with `--isolated` so that
  it cannot see your photos or phone storage, then Phosh, the apps and
  Antumbra's theme: probably 1 to 2 GB of downloads.

## If something goes wrong

- **`pkg` fails** with "Failed to fetch", "404", "Hash Sum mismatch" or a
  mirror "under maintenance": a Termux download server (mirror) is out of
  step. Run `termux-change-repo`, choose **Mirror group**, then **All
  mirrors**, and paste the command again.
- **"App not installed"** for Termux:X11: Termux did not come from GitHub
  (step 7). Uninstall every Termux app and install both from this page.
- **Termux:X11 stays black**: normal here, nothing draws on it in this
  check. Text with a **PREFERENCES** button instead means the app has not
  reached the X server: go back to Termux and repeat 9.4 and 9.5.
- **The check says "No X server"**, or Termux:X11 closes: send a
  screenshot of the server's last messages:

  ```sh
  tail -n 20 "$PREFIX/tmp/x11-check.log"
  ```

- **`[Process completed (signal 9) - press Enter]`**: Android stopped
  Termux in the background (see "Coming next week"). Press Enter and
  start again from where it stopped.
- **Docker Hub pull limits** are not involved yet: nothing on this page
  downloads from there. They can matter for next week's installer, if it
  fetches Debian from Docker Hub through proot-distro.
