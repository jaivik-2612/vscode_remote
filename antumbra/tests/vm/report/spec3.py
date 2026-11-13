#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The content of the test page for the final runs of 6 Oct 2026 (f1-f4); writes the
spec that make_report2.py turns into the page. The template for the next page: copy
it, then change the runs, the texts and the screenshots.

usage: spec3.py [--work DIR] [--notes NOTES_JSON] [-o OUT_JSON] COMMIT BUNDLE_JSON_OR_- UNIT_COUNT GENPD_LOG
  --work      the VM runs' directory (default: build/work/qemu-virt of this checkout);
              run X's report and screenshots are read from run-X/smoke/ under it
  --notes     a JSON object mapping a run id to a note shown with that run;
              its "_android_run" names the Android run shown (default f4)
  -o          where the spec goes (default: spec3.json in the current directory)
  BUNDLE_JSON the test bundle's name, size, parts, prefix, sha256 and dir, or - for none
  GENPD_LOG   the output of tests/kernel/genpd-sleep-vm.sh
"""
import argparse
import json
import os

ap = argparse.ArgumentParser(description="Write the spec of the QEMU test page (make_report2.py).")
ap.add_argument("commit")
ap.add_argument("bundle")
ap.add_argument("unit_count")
ap.add_argument("genpd_log")
ap.add_argument("--work", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                               "..", "..", "..", "build", "work", "qemu-virt"))
ap.add_argument("--notes")
ap.add_argument("-o", "--out", default="spec3.json")
a = ap.parse_args()
W = os.path.abspath(a.work)
commit = a.commit
bundle = None if a.bundle == "-" else json.load(open(a.bundle))
unit_count = a.unit_count
notes = json.load(open(a.notes)) if a.notes else {}
# The Android run shown: "_android_run" in NOTES_JSON (default f4).
A = notes.pop("_android_run", "f4")


def shot(run, name):
    return os.path.join(W, f"run-{run}", "smoke", name)


spec = {
    "intro": ("The final runs on QEMU's arm64 virt machine: the new interface, the pop-up selfie camera's software and "
              "kernel safety, Persistent Storage, and Android apps over Tor. One image (Android apps built in), five runs "
              "on it, each booted from a fresh disk; the same kernel sources, root filesystem hooks, squashfs and "
              "dm-verity tree as the phone image."),
    "runs": [
        {"id": "f1", "short": "Base, theme, camera", "title": "Privacy checks, the interface, the camera",
         "what": "Boot to power-off, the Welcome screen, Tor-only networking, a tour of the session, and the camera path on QEMU's virtual camera (vimc).",
         "report": f"{W}/run-f1/smoke/report.json"},
        {"id": "f2", "short": "Android's network", "title": "Android's Tor-only network, without Android",
         "what": "A stand-in container on Android's bridge: DHCP, probes to the Internet, the local network and the host, DNS, .onion, IPv6, and the start-up hook's refusals.",
         "report": f"{W}/run-f2/smoke/report.json"},
        {"id": "f3a", "short": "Persistent Storage", "title": "Creating Persistent Storage",
         "what": "The Welcome screen creates the encrypted volume; its features, the saved settings and a file in ~/Persistent are checked.",
         "report": f"{W}/run-f3a/smoke/report.json"},
        {"id": "f3b", "short": "Persistent Storage", "title": "Unlocking it on the next boot",
         "what": "The same disk, booted again: a wrong passphrase is refused, the right one unlocks it, and the first run's settings and file are back.",
         "report": f"{W}/run-f3b/smoke/report.json"},
        {"id": A, "short": "Android apps", "title": "Android apps switched on",
         "what": "The Welcome screen's Android switch on: the container starts on Tor's bridge, hides the phone's identifiers, installs F-Droid, and stops cleanly.",
         "report": f"{W}/run-{A}/smoke/report.json"},
    ],
    "genpd_log": os.path.abspath(a.genpd_log),
    "genpd_intro": ("The pop-up camera's motor must never move while the system is suspending or resuming, when the sensors "
                    "that tell where it is are off. This test runs on the VM's kernel with a stand-in power domain and "
                    "camera that follow the safety patch's rules. Cases 6 and 7 run the first version of those rules on "
                    "purpose and must show the two faults review found in it. The phone's own motor driver is not run here."),
    "unit": {"root": unit_count, "text": "unit tests pass; lint and the interface self-test pass"},
    "added_intro": "Everything below was added, reviewed by independent agents in several rounds, fixed, and tested in this VM.",
    "features": [
        {"title": "Interface", "items": [
            "A dark tonal palette from one deep-violet seed, lavender accent, Roboto, rounded cards and quick-settings tiles.",
            "A thin gesture pill, a dock of Tor Browser, Files, Camera and Console, and new wallpapers.",
            "Styled through Phosh's own stylesheets: nothing reaches Tor Browser's window, which a unit test checks."]},
        {"title": "Pop-up selfie camera", "items": [
            "GNOME Snapshot on libcamera and PipeWire, which raise the front camera when it streams and lower it when it stops.",
            "A kernel patch that lowers the camera before sleep and power-off, never moves it mid-suspend, retries a failed lowering, and caps how long the motor can run.",
            "An optional build of the port's patched libcamera 0.7.2 with this phone's sensor data."]},
        {"title": "Android apps over Tor", "items": [
            "Waydroid with LineageOS 20 (Android 13) and F-Droid, every download pinned by hash and signature; off by default, one switch on the Welcome screen.",
            "The container's traffic goes only to Tor; the start-up hook refuses to start it otherwise, and .onion lookups cannot reach another app.",
            "The phone's serial numbers and other hardware identifiers are hidden from Android; amnesic unless you keep it in Persistent Storage."]},
    ],
    "oneplus": [
        "OxygenOS's camera app, which drives the pop-up camera on Android, can't be included: its licence forbids "
        "redistributing it, and it only runs on Qualcomm's own camera driver stack, which a mainline Linux kernel does not have. "
        "It would not run inside Android apps here either.",
        "The pop-up camera works without it. The motor is driven by the kernel, so any camera app works: when an app starts "
        "streaming from the front camera, the camera rises; when it stops, the camera retracts. GNOME Snapshot is the camera app "
        "in the image. No OnePlus software is in the image, and a scanner in the build checks that, including inside archives "
        "and Android images.",
    ],
    "runs_intro": "Each run's checks, grouped by phase. Open a run to see every check and what it found.",
    "findings_intro": ("Independent agents reviewed each part, each finding was checked by a second agent trying to refute it, "
                       "and every fix was verified again. These are the problems that would have reached a user."),
    "findings": [
        {"sev": "high", "problem": "Android could never start: one device rule in the container's configuration blocked every device, binder included.",
         "fix": "Allow every device, then deny only cameras.", "where": "Android runtime"},
        {"sev": "high", "problem": "Android apps could read the phone's serial numbers (kernel command line, SoC, UFS storage).",
         "fix": "A generic command line for Android; every serial-number file, the chip's fuse dump and the clock's raw counter masked, and each mask checked in the container's own view before it starts.",
         "where": "Android runtime"},
        {"sev": "high", "problem": "Creating or unlocking Persistent Storage failed for everyone (an older bug no test exercised).",
         "fix": "The applier finds its tools, stages the Welcome settings before unlocking and saves them last.", "where": "Welcome settings"},
        {"sev": "high", "problem": "After an unlock the Welcome settings were hidden: no network for the session, and the screen-lock passphrase lost.",
         "fix": "Same as above, with a VM test that creates the volume and unlocks it on the next boot.", "where": "Welcome settings"},
        {"sev": "medium", "problem": "The greeter account could make root copy any root-only file to a world-readable place.",
         "fix": "Greeter files are never followed as links, and copies are made in a root-only directory and renamed into place.", "where": "Welcome settings"},
        {"sev": "medium", "problem": "Android apps could find the phone's own Wi-Fi address: those addresses were refused at once, all others timed out.",
         "fix": "The phone's own addresses look like any other local address to Android.", "where": "Android network"},
        {"sev": "medium", "problem": "A .onion lookup inside Android could be answered by another Android app listening on the same port.",
         "fix": "The start-up hook rejects Tor's .onion addresses inside Android's network.", "where": "Android network"},
        {"sev": "medium", "problem": "Android could not be stopped during a session, and its devices stayed open to every user afterwards.",
         "fix": "Stopping Android closes its devices again; checked in the VM.", "where": "Android runtime"},
        {"sev": "medium", "problem": "After a failed close and an interrupted suspend, the pop-up camera could rise with no app using it.",
         "fix": "The motor follows whether an app holds the camera, not the power domain's bookkeeping.", "where": "Kernel patch"},
        {"sev": "medium", "problem": "A failed lowering before sleep was never retried: the camera could stay raised after waking.",
         "fix": "The lowering is retried after resume when no app wants the camera.", "where": "Kernel patch"},
        {"sev": "high", "problem": "Images built from a checkout not owned by root carried system files and directories owned by that user (/etc and /usr among them).",
         "fix": "The build stages the overlays root-owned with fixed modes; lint checks the staged copies, so it also passes on a fresh clone.", "where": "Build"},
        {"sev": "medium", "problem": "The Welcome screen invited snowflake bridges, which were then refused, and accepted meek_lite bridges, for which Tor had no transport.",
         "fix": "Snowflake is refused at Start with the reason (it needs UDP, which the firewall does not give Tor); meek_lite gets its transport; a test keeps the accepted list and Tor's transports equal.", "where": "Bridges"},
        {"sev": "medium", "problem": "Bridges pasted one per line reached Tor as only the first bridge.",
         "fix": "Line breaks are stored as separators; the field's title names the bridges that work and the separator.", "where": "Bridges"},
        {"sev": "medium", "problem": "The release manifest always said the images contain no device firmware, even when the build had added it.",
         "fix": "The build records whether firmware went in; the manifest says so, lists it, and warns that it may not be published.", "where": "Build"},
        {"sev": "low", "problem": "Bridges with IPv6 addresses were accepted, though IPv6 is off and could never reach them.",
         "fix": "Refused at Start with the reason.", "where": "Bridges"},
        {"sev": "low", "problem": "After an unexpected failure once the volume was unlocked, a retry was let in with any passphrase.",
         "fix": "A failed attempt locks the volume again; a retry needs the passphrase, and an amnesic retry is refused until a restart.", "where": "Welcome settings"},
        {"sev": "low", "problem": "The check that keeps the theme out of Tor Browser's window let some selectors through.",
         "fix": "The check strips :not() and refuses @import.", "where": "Interface"},
    ],
    "vm_found_intro": "Booting the image found these, some in the system and some in the tests themselves.",
    "vm_found": [
        {"run": "Android boot", "problem": "Android never finished booting under emulation: its Watchdog asked for stack dumps of vold and the hardware services with a 2-second limit, each dump took longer, the dumped process died, and vold's death restarted Android.",
         "fix": "In a virtual machine Android's timeouts are scaled (ro.hw_timeout_multiplier=10), as emulators do; the phone keeps Android's own.", "kind": "VM setup"},
        {"run": "Android boot", "problem": "Booted, Android still showed no window and no app icons: Waydroid froze it when its display went to sleep, before it had finished setting up its user.",
         "fix": "In a virtual machine Waydroid does not freeze Android; on the phone it still freezes an Android nobody is using, to save power.", "kind": "VM setup"},
        {"run": "Android boot", "problem": "After Android stopped, the screen's framebuffer and the GPU stayed open to every program: anything could have read what was on screen.",
         "fix": "Their modes are recorded before Android's first start and put back when it stops.", "kind": "System"},
        {"run": "Android boot", "problem": "The file indexer timed out on its first start under load, broke its own database and restarted every 3 seconds for the rest of the session.",
         "fix": "Switched off: on an amnesic phone it rebuilt its index in memory at every boot.", "kind": "System"},
        {"run": "Android boot", "problem": "F-Droid's installer gave up two minutes after asking Android to install it; under emulation the installation takes longer.",
         "fix": "It waits up to 15 minutes, and the harness keeps its log if F-Droid is missing.", "kind": "System"},
        {"run": "Android network", "problem": "antumbra-tor-connect always ended in an error after Tor had taken the setting: it asked Tor to save its configuration, which Tor may not write.",
         "fix": "Settings applied without saving; nothing about Tor is kept between sessions anyway.", "kind": "System"},
        {"run": "Persistent Storage", "problem": "The applier kept its private copy of the Welcome settings, passphrase hash included, until after the network came up.",
         "fix": "Removed as soon as it has been used.", "kind": "System"},
        {"run": "Android boot", "problem": "At power-off Android's clean-up asked for a service systemd refuses during shutdown, and logged an error.",
         "fix": "Skipped while the system stops; the shutdown closes Android's devices itself.", "kind": "System"},
        {"run": "Android network", "problem": "The stand-in container never got an address: its DHCP script sat on /run, which the image mounts without execute rights.",
         "fix": "The script moved to /root; /run stays non-executable.", "kind": "Test"},
        {"run": "Camera", "problem": "Snapshot's preview takes about three minutes to appear under full emulation.",
         "fix": "The check waits for the picture instead of a fixed 30 seconds.", "kind": "Test"},
        {"run": "Android boot", "problem": "One slow command on the VM's console made every later check time out.",
         "fix": "The harness interrupts a timed-out command and carries on; its timeouts follow the timeout scale.", "kind": "Test"},
        {"run": "Android boot", "problem": "The check that Android's interface was drawn passed on a picture of the wallpaper.",
         "fix": "Most of the screen must now change; F-Droid's window gets the same check.", "kind": "Test"},
        {"run": "Base", "problem": "Sockets Tor opened and closed within a second had no owner in the socket list.",
         "fix": "Sockets are matched to Tor by the user the kernel records for them.", "kind": "Test"},
    ],
    "caveats_intro": "Things to know before using it, from the documentation in the repository.",
    "caveats": [
        "Snowflake bridges don't work (they need UDP, which Antumbra's firewall does not give Tor); use obfs4 or webtunnel. webtunnel and meek_lite are accepted but have not connected on the phone yet.",
        "File search in Files is by name only: the file indexer is off.",
        "Nothing here has run on the phone yet. The kernel patch for the motor, the camera software, Android's graphics and the identifier masks each have checks in docs/hardware-validation.md that only the phone can answer.",
        "The pop-up camera has no drop protection: the accelerometer sits behind the sensor processor, which Antumbra switches off. Don't keep the selfie camera open while walking, and don't push a raised camera down by hand.",
        "Camera quality is limited: the front camera captures 1748x1748 only, colour and exposure come from libcamera's software processing, and a camera failure can need a reboot. The rear cameras have no physical indicator.",
        "The camera prompt does not protect against programs you run yourself: Tor Browser can reach the cameras without asking until its own confinement profile exists (planned).",
        "Android apps are experimental and off by default. They run Android 13 (LineageOS 20, the newest official Waydroid build), not Android 14, with no Google apps; F-Droid is the store, and Android's security patches stay at the pinned build until Antumbra updates it.",
        "Android is a weaker sandbox than the rest of Antumbra: its root is the system's root, without SELinux, and while it runs any program of yours can talk to its system services. Use it only for apps you trust.",
        "Android apps reach the Internet only through Tor and share one Tor identity. Calls, WebRTC, games and VPN apps fail because UDP is blocked; IPv6 and .onion addresses don't work inside Android. Apps you log in to still identify you.",
        "Android has no camera; its microphone is gated only by Android's own prompt. Android apps use Android's keyboard, and there is no clipboard sharing.",
        "Android costs about 1 GB of download and flash and 1-1.5 GB of RAM while running (estimates), which is tight next to Tor Browser on the 8 GB model.",
        "Android forgets everything at shutdown unless you keep it in Persistent Storage, which then also keeps Android's own usage history.",
        "The interface is closer to Android 14 but Phosh is not Android: no back-swipe, no home-screen widgets or lock-screen shortcuts, colours do not follow the wallpaper, and lock-screen notifications are hidden for privacy.",
    ],
    "run_intro": [
        "The bundle holds the kernel, the initramfs, the compressed disk image and a script that starts QEMU with the same "
        "devices as these runs. It needs qemu-system-aarch64 (QEMU 8 or later) and about 6 GB of free disk; with KVM or "
        "Apple's Hypervisor framework it runs at near-native speed, without them under emulation as here.",
        "The debug console in this build gives a root shell on the VM's second console; release builds have none.",
    ],
    "commands": [],
    "built": [],
}
if bundle:
    spec["run_intro"].insert(0, f"The bundle {bundle['name']} ({bundle['size']}) comes in {bundle['parts']} parts; join them, check the SHA-256, unpack and run.")
    spec["commands"] = [
        ("Join and check", f"cat {bundle['prefix']}.part* > {bundle['name']}\nsha256sum {bundle['name']}\n# expect {bundle['sha256']}"),
        ("Unpack and start", f"tar xf {bundle['name']}\ncd {bundle['dir']}\n./run.sh"),
    ]
spec["built"] = [
    ("Source", f"claude/tails-mobile-privacy-os-c71ate at {commit}"),
    ("Kernel", "Linux 6.17.0-sm8150-hotdog-clean-antumbra-virt (the port's sources, Antumbra's patches 0101 and 0102)"),
    ("Root filesystem", "Debian 13 trixie arm64, 1052 packages; Phosh 0.46; Tor; Tor Browser 16.0a13; Waydroid 1.6.3 with LineageOS 20 arm64_only images; F-Droid 2.0.1"),
    ("Camera stack", "GNOME Snapshot 48, libcamera 0.7.1 and PipeWire 1.6.9 from trixie-backports"),
    ("Machine", "QEMU virt, cortex-a72, 3 CPUs, 4 GB (6 GB with Android), full emulation (TCG)"),
]
spec["shots"] = [
    [shot("f1", "display.png"), "The Welcome screen with the new theme"],
    [shot(A, "welcome-android.png"), "Android apps on the Welcome screen, off by default"],
    [shot("f1", "tour-apps.png"), "The app grid and the dock"],
    [shot("f1", "tour-quick-settings.png"), "Quick settings"],
    [shot("f1", "camera-portal-prompt.png"), "The camera asks before the first use"],
    [shot("f1", "camera-preview.png"), "Snapshot streaming from the VM's test camera"],
]
for extra in ("android-full-ui.png", "android-fdroid.png"):
    if os.path.exists(shot(A, extra)):
        spec["shots"].append([shot(A, extra), {"android-full-ui.png": "Android's own interface inside Antumbra", "android-fdroid.png": "F-Droid running inside Antumbra"}[extra]])
for r in spec["runs"]:
    if r["id"] in notes:
        r["note"] = notes[r["id"]]
json.dump(spec, open(a.out, "w"), indent=1)
print(f"{a.out} written:", len(spec["shots"]), "shots")
