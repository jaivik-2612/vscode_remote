# SPDX-License-Identifier: GPL-3.0-or-later
"""The Android container's run-time configuration (runs on the build host):
the device cgroup rules as LXC 6 compiles them, the generic kernel command
line and the hardware serial number masks, closing Waydroid's devices once
Android stops, and the extracted images' pins."""
import importlib.machinery
import importlib.util
import os
import re
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
ANDROID = os.path.join(ROOT, "config", "rootfs-android")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def hook56():
    return read("config", "hooks", "56-session-android.sh")


def config_3_additions():
    """The lines hook 56 appends to Waydroid's config_3 template."""
    m = re.search(r'cat >> "\$\{CONFIGS\}/config_3" <<\'EOF\'\n(.*?)\nEOF\n', hook56(), re.S)
    return [l for l in m.group(1).splitlines() if l and not l.startswith("#")]


def post_stop_after_hook56():
    """Waydroid's config_base post-stop line, edited by hook 56's sed."""
    expr = re.search(r"^sed -i '(s\|\^lxc\\\.hook\\\.post-stop[^']*)' \"\$\{CONFIGS\}/config_base\"$", hook56(), re.M).group(1)
    return subprocess.run(["sed", expr], input="lxc.hook.post-stop = /dev/null\n", capture_output=True, text=True, check=True).stdout.splitlines()


def load_antumbra_waydroid():
    path = os.path.join(ANDROID, "usr", "local", "lib", "antumbra-waydroid")
    loader = importlib.machinery.SourceFileLoader("antumbra_waydroid", path)
    spec = importlib.util.spec_from_loader("antumbra_waydroid", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


# --- LXC 6.0's device cgroup, as src/lxc/cgroups/cgroup2_devices.c compiles it ----------------
# The list starts as an allowlist (everything blocked); only a bare "a" rule
# switches the list type (allow: deny list, everything allowed) and clears
# the rules so far. In an allowlist, deny rules are skipped; in a deny list,
# allow rules are. With no rule left, no program is attached at all.

def lxc_device_allowed(lines, dev_type, major, minor):
    rules = [re.match(r"^lxc\.cgroup2\.devices\.(allow|deny) = (.*)$", l) for l in lines]
    rules = [(m.group(1) == "allow", m.group(2).strip()) for m in rules if m]
    allow_all, kept = False, []
    for allow, spec in rules:
        if spec == "a":
            allow_all, kept = allow, []
            continue
        kept.append((allow, spec))
    if not rules or (not kept and allow_all):
        return True
    for allow, spec in kept:
        if allow == allow_all:
            continue
        t, numbers = spec.split()[:2]
        ma, mi = numbers.split(":")
        if t in ("a", dev_type) and ma in ("*", str(major)) and mi in ("*", str(minor)):
            return allow
    return allow_all


class DeviceCgroupTest(unittest.TestCase):
    def test_android_gets_every_device_but_cameras(self):
        lines = config_3_additions()
        for name, dev in (("/dev/null", (1, 3)), ("/dev/zero", (1, 5)), ("binder (misc)", (10, 50)),
                          ("/dev/fuse", (10, 229)), ("render node", (226, 128)), ("/dev/tty", (5, 0))):
            self.assertTrue(lxc_device_allowed(lines, "c", *dev), f"{name} would be blocked in the container")
        for minor in (0, 1, 5):
            self.assertFalse(lxc_device_allowed(lines, "c", 81, minor), f"/dev/video (81:{minor}) would be allowed")

    def test_model_matches_lxc(self):
        # The case of the finding: a lone deny blocks everything.
        self.assertFalse(lxc_device_allowed(["lxc.cgroup2.devices.deny = c 81:* rwm"], "c", 1, 3))
        self.assertTrue(lxc_device_allowed([], "c", 81, 0))
        self.assertTrue(lxc_device_allowed(["lxc.cgroup2.devices.allow = a"], "c", 81, 0))

    def test_runtime_checks_require_the_order(self):
        m = load_antumbra_waydroid()
        good = generated_config(m)
        self.assertEqual(m.lxc_problems(good, []), [])
        swapped = good.replace("lxc.cgroup2.devices.allow = a\nlxc.cgroup2.devices.deny = c 81:* rwm",
                               "lxc.cgroup2.devices.deny = c 81:* rwm\nlxc.cgroup2.devices.allow = a")
        self.assertNotEqual(swapped, good)
        self.assertTrue(any("device rules" in p for p in m.lxc_problems(swapped, [])))
        deny_only = good.replace("lxc.cgroup2.devices.allow = a\n", "")
        self.assertTrue(any("device rules" in p for p in m.lxc_problems(deny_only, [])))
        start_host = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host")
        self.assertIn("'lxc.cgroup2.devices.allow = a' 'lxc.cgroup2.devices.deny = c 81:* rwm'", start_host)


def generated_config(m, masks=()):
    """A container configuration as "waydroid upgrade" generates it from the
    edited templates, plus antumbra-waydroid's mask entries MASKS."""
    text = "\n".join(["lxc.rootfs.path = /var/lib/waydroid/rootfs",
                      "lxc.cap.keep = audit_control sys_nice setpcap sys_admin net_admin mknod",
                      *post_stop_after_hook56(),
                      "lxc.net.0.type = veth", "lxc.net.0.link = waydroid-tor",
                      *config_3_additions()]) + "\n"
    if masks:
        text += "\n" + m.MASKS_MARK + "\n" + "".join(e + "\n" for e in masks)
    return text


START_HOST = ("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host")

# A sysfs and procfs laid out as on the phone (and the VM), with every kind
# of identifier antumbra-waydroid hides; paths relative to the fake root.
QFPROM = "sys/devices/platform/soc@0/784000.efuse/qfprom0"
RTC = "sys/devices/platform/soc@0/c440000.spmi/spmi-0/0-00/c440000.spmi:pmic@0:rtc@6000/rtc/rtc0"
SCSI = "sys/devices/platform/soc@0/1d84000.ufshc/host0/target0:0:0/0:0:0:0"
BATTERY = "sys/devices/platform/soc@0/a8c000.i2c/i2c-1/1-0055/power_supply/bq27411-0"
MASKED_FILES = ["sys/devices/soc0/serial_number",
                "sys/devices/soc0/uevent",                                  # next to serial_number
                "sys/devices/platform/soc@0/1d84000.ufshc/string_descriptors/serial_number",
                f"{SCSI}/vpd_pg80", f"{SCSI}/vpd_pg83", f"{SCSI}/wwid",
                f"{SCSI}/block/sda/sda5/uevent",                            # a partition's: PARTUUID
                "sys/devices/pci0000:00/0000:00:02.0/virtio1/block/vda/serial",
                "sys/devices/virtual/block/dm-1/dm/uuid",                   # Persistent Storage's LUKS UUID
                "sys/devices/platform/soc@0/8804000.mmc/mmc_host/mmc0/mmc0:aaaa/cid",
                "sys/devices/platform/soc@0/a90000.i2c/i2c-0/0-0050/eeprom",
                f"{BATTERY}/serial_number", f"{BATTERY}/uevent",            # POWER_SUPPLY_SERIAL_NUMBER
                "proc/driver/rtc"]
HIDDEN_DIRS = [QFPROM, RTC]
LEFT_ALONE = ["sys/devices/soc0/machine", f"{SCSI}/block/sda/uevent", f"{SCSI}/block/sda/size",
              f"{SCSI}/block/sda/sda5/size", f"{SCSI}/uevent", "sys/devices/virtual/block/dm-1/dm/name",
              f"{BATTERY}/capacity", "proc/cmdline"]


def fake_sysfs(root):
    """Lay out the fake sysfs and procfs under ROOT."""
    inside = [f"{QFPROM}/nvmem", f"{QFPROM}/cells/gpu-speed-bin@133,5", f"{QFPROM}/uevent", f"{QFPROM}/type",
              f"{RTC}/since_epoch", f"{RTC}/date", f"{RTC}/time", f"{RTC}/wakealarm", f"{RTC}/uevent",
              f"{SCSI}/block/sda/sda5/partition"]
    for rel in MASKED_FILES + LEFT_ALONE + inside:
        os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
        with open(os.path.join(root, rel), "w") as f:
            f.write("x\n")
    os.makedirs(os.path.join(root, "sys", "devices", "virtual", "serial"))              # a directory: not an identifier
    os.symlink("../soc0", os.path.join(root, "sys", "devices", "platform", "soc0"))      # links are not followed
    os.symlink("../../soc0/serial_number", os.path.join(root, "sys", "devices", "virtual", "uuid"))


def start_host_identifiers(root):
    """The start-host hook's own list of identifiers (its identifiers=
    block, run by dash with /sys/devices and /proc under ROOT): sorted
    (kind, path) pairs, paths as in the container."""
    m = re.search(r'^identifiers="\$\(\n(.*?)\n\)"$', read(*START_HOST), re.M | re.S)
    block = m.group(1).replace("/sys/devices", f"{root}/sys/devices").replace("/proc/driver/rtc", f"{root}/proc/driver/rtc")
    out = subprocess.run(["dash", "-c", block], capture_output=True, text=True, check=True).stdout
    pairs = [line.split(" ", 1) for line in out.splitlines() if line]
    return sorted({(kind, path[len(root):]) for kind, path in pairs})


class IdentifiersTest(unittest.TestCase):
    def setUp(self):
        self.m = load_antumbra_waydroid()

    def test_generic_kernel_command_line(self):
        self.assertIn(self.m.CMDLINE_ENTRY, config_3_additions())
        self.assertEqual(self.m.CMDLINE_SRC, "/usr/share/antumbra/android/cmdline")
        cmdline = read("config", "rootfs-android", "usr", "share", "antumbra", "android", "cmdline")
        self.assertNotIn("androidboot", cmdline)
        self.assertNotIn("serial", cmdline)
        start_host = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host")
        self.assertIn(f"CMDLINE={self.m.CMDLINE}", start_host)
        self.assertIn('lxc.mount.entry = ${CMDLINE} proc/cmdline none bind,create=file 0 0', start_host)
        without = generated_config(self.m).replace(self.m.CMDLINE_ENTRY + "\n", "")
        self.assertTrue(self.m.lxc_problems(without, []))

    def test_identifiers_are_found_and_masked(self):
        with tempfile.TemporaryDirectory() as root:
            fake_sysfs(root)
            files, dirs = self.m.identifier_paths(os.path.join(root, "sys"), os.path.join(root, "proc"))
            self.assertEqual(files, sorted("/" + rel for rel in MASKED_FILES))
            self.assertEqual(dirs, sorted("/" + rel for rel in HIDDEN_DIRS))
            masks = self.m.mask_entries(files, dirs)
            self.assertIn("lxc.mount.entry = /dev/null sys/devices/soc0/serial_number none bind,ro,optional 0 0", masks)
            self.assertIn("lxc.mount.entry = /dev/null proc/driver/rtc none bind,ro,optional 0 0", masks)
            self.assertIn(f"lxc.mount.entry = tmpfs {QFPROM} tmpfs ro,nosuid,nodev,noexec,mode=0555,size=4k,optional 0 0", masks)
            good = generated_config(self.m, masks)
            self.assertEqual(self.m.lxc_problems(good, masks), [])
            for entry, path in ((masks[0], files[0][1:]), (masks[-1], dirs[-1][1:])):
                missing = good.replace(entry + "\n", "")
                self.assertEqual(self.m.lxc_problems(missing, masks), [f"the container configuration does not mask {path}"])
        with self.assertRaises(SystemExit):
            self.m.mask_entries(["/sys/devices/a b/serial"])
        with self.assertRaises(SystemExit):
            self.m.mask_entries([], ["/run/antumbra"])

    def test_a_device_gone_during_the_scan_is_skipped(self):
        # A device unplugged while antumbra-waydroid looks: its files vanish
        # between the directory listing and the lstat.
        real_lstat = os.lstat

        def lstat(path, *a, **kw):
            if str(path).endswith("/vda/serial"):
                raise FileNotFoundError(path)
            return real_lstat(path, *a, **kw)

        with tempfile.TemporaryDirectory() as root:
            fake_sysfs(root)
            with mock.patch.object(self.m.os, "lstat", lstat):
                files, dirs = self.m.identifier_paths(os.path.join(root, "sys"), os.path.join(root, "proc"))
        self.assertEqual(files, sorted("/" + rel for rel in MASKED_FILES if not rel.endswith("/vda/serial")))
        self.assertEqual(dirs, sorted("/" + rel for rel in HIDDEN_DIRS))

    def test_start_host_hook_finds_the_same_identifiers(self):
        # The hook's own scan, run on the same tree, lists exactly what
        # antumbra-waydroid masks, and looks for the entries it writes.
        with tempfile.TemporaryDirectory() as root:
            fake_sysfs(root)
            files, dirs = self.m.identifier_paths(os.path.join(root, "sys"), os.path.join(root, "proc"))
            self.assertEqual(start_host_identifiers(root), sorted([("file", f) for f in files] + [("dir", d) for d in dirs]))
        hook = read(*START_HOST)
        f, d = self.m.mask_entries(["/sys/x"], ["/sys/y"])
        self.assertIn('entry="' + f.replace("sys/x", "${path#/}") + '"', hook)
        self.assertIn('entry="' + d.replace("sys/y", "${path#/}") + '"', hook)

    def test_start_host_hook_looks_for_the_same_names(self):
        hook = read(*START_HOST)
        finds = re.findall(r"find /sys/devices \\\( (.*?) \\\) -type f", hook)
        self.assertEqual(len(finds), 3, finds)
        for names, want in zip(finds, (self.m.MASKED_NAMES, self.m.UEVENT_MARKERS, self.m.HIDDEN_DIR_MARKERS)):
            self.assertEqual(sorted(re.findall(r"-name (\S+)", names)), sorted(want))
        self.assertEqual(re.findall(r"if \[ -f (/proc/\S+) \]; then printf 'file %s\\n' \1; fi", hook),
                         ["/proc/" + p for p in self.m.MASKED_PROC])

    def test_masks_are_optional_and_replaced_not_stacked(self):
        with tempfile.TemporaryDirectory() as d:
            self.m.LXC_CONFIG = os.path.join(d, "config")
            with open(self.m.LXC_CONFIG, "w") as f:
                f.write(generated_config(self.m))
            self.m.add_masks(self.m.mask_entries(["/sys/devices/soc0/serial_number", "/sys/devices/x/serial"]))
            self.m.add_masks(self.m.mask_entries(["/sys/devices/soc0/serial_number"], ["/sys/devices/y/rtc/rtc0"]))
            with open(self.m.LXC_CONFIG) as f:
                text = f.read()
        self.assertEqual(text.count(self.m.MASKS_MARK), 1)
        self.assertEqual(text.count("sys/devices/soc0/serial_number"), 1)
        self.assertNotIn("sys/devices/x/serial", text)     # a device gone since: its mask goes too
        masks = text[text.index(self.m.MASKS_MARK):].splitlines()[1:]
        self.assertEqual(len(masks), 2)
        self.assertTrue(all(re.search(r",optional 0 0$", line) for line in masks), masks)

    def test_masks_are_written_again_before_each_container_start(self):
        # Devices come and go: the container service writes the masks for
        # what is there before it starts, and it stops with the container.
        dropin = read("config", "rootfs-android", "etc", "systemd", "system", "waydroid-container.service.d", "antumbra.conf")
        self.assertEqual(re.findall(r"(?m)^ExecStartPre=(.*)$", dropin), ["/usr/local/lib/antumbra-waydroid --masks"])
        source = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid")
        self.assertIn('if sys.argv[1:] == ["--masks"]:\n        masks_main()', source)


class AndroidStopTest(unittest.TestCase):
    def test_stopped_session_stays_stopped(self):
        unit = read("config", "rootfs-android", "usr", "lib", "systemd", "user", "antumbra-android-session.service")
        self.assertRegex(unit, r"(?m)^RemainAfterExit=yes$")
        path = read("config", "rootfs-android", "usr", "lib", "systemd", "user", "antumbra-android-session.path")
        self.assertRegex(path, r"(?m)^PathExists=/run/antumbra/android-ready$")

    def test_post_stop_hook_runs_before_waydroids_failing_one(self):
        # LXC runs post-stop hooks in order and stops at the first failure;
        # Waydroid's "/dev/null" always fails.
        self.assertEqual(post_stop_after_hook56(), ["lxc.hook.post-stop = /usr/local/lib/antumbra-waydroid-post-stop",
                                                    "lxc.hook.post-stop = /dev/null"])
        m = load_antumbra_waydroid()
        late = generated_config(m).replace(
            "lxc.hook.post-stop = /usr/local/lib/antumbra-waydroid-post-stop\nlxc.hook.post-stop = /dev/null",
            "lxc.hook.post-stop = /dev/null\nlxc.hook.post-stop = /usr/local/lib/antumbra-waydroid-post-stop")
        self.assertTrue(any("post-stop" in p for p in m.lxc_problems(late, [])))

    def test_post_stop_stops_the_container_service(self):
        lib = os.path.join(ANDROID, "usr", "local", "lib")
        hook = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-post-stop")
        self.assertIn("systemctl --no-block start antumbra-waydroid-stopped.service", hook)
        self.assertRegex(hook, r"(?m)^exit 0$")
        unit = read("config", "rootfs-android", "usr", "lib", "systemd", "system", "antumbra-waydroid-stopped.service")
        self.assertIn("ExecStart=/usr/local/lib/antumbra-waydroid-stopped", unit)
        stopped = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-stopped")
        self.assertIn("systemctl stop waydroid-container.service", stopped)
        for name in ("antumbra-waydroid-post-stop", "antumbra-waydroid-stopped"):
            self.assertTrue(os.access(os.path.join(lib, name), os.X_OK), name)

    def test_devices_closed_when_the_service_stops(self):
        dropin = read("config", "rootfs-android", "etc", "systemd", "system", "waydroid-container.service.d", "antumbra.conf")
        stops = re.findall(r"(?m)^ExecStopPost=(.*)$", dropin)
        self.assertIn("/bin/chmod 0600 /dev/binder /dev/hwbinder /dev/vndbinder", stops)
        # udev has no rule for dma_heap (no MODE, so a change event changes
        # nothing): Waydroid's 0777 must be undone explicitly.
        udev_rules = ""
        for top in ("rootfs", "rootfs-android"):
            for d in ("etc/udev/rules.d", "usr/lib/udev/rules.d"):
                p = os.path.join(ROOT, "config", top, d)
                for n in (os.listdir(p) if os.path.isdir(p) else []):
                    udev_rules += read("config", top, d, n)
        if 'SUBSYSTEM=="dma_heap"' not in udev_rules:
            self.assertFalse([s for s in stops if "subsystem-match=dma_heap" in s], "a udev trigger cannot restore dma_heap's mode")
            self.assertIn("-/usr/bin/find /dev/dma_heap -mindepth 1 -maxdepth 1 -type c -exec /bin/chmod 0600 {} +", stops)


class ImagePinsTest(unittest.TestCase):
    def test_every_extracted_image_is_pinned(self):
        lock = dict(l.split("=", 1) for l in read("device", "oneplus-hotdog", "sources.lock").splitlines()
                    if "=" in l and not l.startswith("#"))
        for variant in ("ARM64", "ARM64_ONLY"):
            for kind in ("SYSTEM", "VENDOR"):
                self.assertRegex(lock.get(f"WAYDROID_{variant}_{kind}_IMG_SHA256", ""), r"^[0-9a-f]{64}$", f"{variant} {kind}")


if __name__ == "__main__":
    unittest.main()
