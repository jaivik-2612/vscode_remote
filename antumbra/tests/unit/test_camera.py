# SPDX-License-Identifier: GPL-3.0-or-later
"""Static checks of the camera userspace (runs on the build host).

The WirePlumber rules must parse and must match on a key PipeWire's V4L2
udev monitor provides; the package lists and pins must give the image
Snapshot with libcamera 0.7 and the PipeWire camera plugin built against it;
every input of the optional libcamera rebuild must be pinned; the VM's
virtual camera must stay out of the phone's kernel; the OnePlus camera
scanner must find what it is meant to find. See docs/camera.md.
"""
import bz2
import contextlib
import gzip
import importlib.util
import io
import json
import lzma
import os
import random
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import unittest.mock
import zipfile

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
WP_RULE = os.path.join(ROOT, "config", "rootfs", "etc", "wireplumber", "wireplumber.conf.d", "90-antumbra-camera.conf")
VM_HOOK = os.path.join(ROOT, "config", "hooks", "72-vm-camera.sh")
LIBCAMERA = os.path.join(ROOT, "device", "oneplus-hotdog", "libcamera")
LOCK = os.path.join(ROOT, "device", "oneplus-hotdog", "sources.lock")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def package_list(name):
    pkgs = []
    for line in read(os.path.join(ROOT, "config", "packages", name + ".list")).splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            pkgs.append(line)
    return pkgs


# ---------------------------------------------------------------------------
# A small parser for PipeWire's relaxed JSON (SPA-JSON): '#' comments,
# '=' or ':' between key and value, optional commas, bare words.
# ---------------------------------------------------------------------------
def spa_json_tokens(text):
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace() or c in ",:=":
            i += 1
        elif c == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "{}[]":
            yield c
            i += 1
        elif c == '"':
            j, out = i + 1, []
            while text[j] != '"':
                if text[j] == "\\":
                    j += 1
                out.append(text[j])
                j += 1
            yield ("str", "".join(out))
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in ',:={}[]"#':
                j += 1
            yield ("word", text[i:j])
            i = j


def spa_json_parse(text):
    """The top level of a .conf file is an object without braces."""
    toks = list(spa_json_tokens(text))
    pos = 0

    def value():
        nonlocal pos
        t = toks[pos]
        pos += 1
        if t == "{":
            return members("}")
        if t == "[":
            items = []
            while toks[pos] != "]":
                items.append(value())
            pos += 1
            return items
        if t in ("}", "]"):
            raise ValueError(f"unexpected {t!r}")
        kind, s = t
        if kind == "word":
            return {"true": True, "false": False, "null": None}.get(s, s)
        return s

    def members(end):
        nonlocal pos
        obj = {}
        while pos < len(toks) and toks[pos] != end:
            key = toks[pos]
            if key in ("{", "}", "[", "]"):
                raise ValueError(f"expected a key, got {key!r}")
            pos += 1
            obj[key[1]] = value()
        if end is not None:
            if pos >= len(toks):
                raise ValueError(f"missing {end!r}")
            pos += 1
        return obj

    result = members(None)
    if pos != len(toks):
        raise ValueError("trailing tokens")
    return result


def wp_matches(match, props):
    """WirePlumber's rule semantics: every key of one match object must
    match; a value starting with '~' is an (unanchored) regular expression."""
    for k, v in match.items():
        have = props.get(k)
        if have is None:
            return False
        if isinstance(v, str) and v.startswith("~"):
            if not re.search(v[1:], have):
                return False
        elif str(v) != have:
            return False
    return True


def disabled_by(conf, props):
    for rule in conf.get("monitor.v4l2.rules", []):
        if any(wp_matches(m, props) for m in rule["matches"]):
            if rule["actions"]["update-props"].get("device.disabled") is True:
                return True
    return False


# What PipeWire 1.6.9's V4L2 udev monitor reports (v4l2-udev.c) for a CAMSS
# video node on the phone, for vimc in the VM and for a USB webcam.
CAMSS = {"device.api": "v4l2", "api.v4l2.path": "/dev/video3",
         "device.product.name": "Qualcomm Camera Subsystem",
         "device.sysfs.path": "/devices/platform/soc@0/acb3000.camss/video4linux/video3"}
CAMSS_NO_PRODUCT = {k: v for k, v in CAMSS.items() if k != "device.product.name"}
VIMC = {"device.api": "v4l2", "api.v4l2.path": "/dev/video0", "device.product.name": "vimc",
        "device.sysfs.path": "/devices/platform/vimc.0/video4linux/video0"}
WEBCAM = {"device.api": "v4l2", "api.v4l2.path": "/dev/video4", "device.bus": "usb",
          "device.product.name": "USB2.0 HD UVC WebCam",
          "device.sysfs.path": "/devices/platform/soc@0/a600000.usb/xhci-hcd.0.auto/usb1/1-1/1-1:1.0/video4linux/video4"}


class WirePlumberRuleTest(unittest.TestCase):
    def setUp(self):
        self.conf = spa_json_parse(read(WP_RULE))

    def test_hides_every_camss_node(self):
        self.assertTrue(disabled_by(self.conf, CAMSS))
        # the sysfs-path alternative still matches without a product name
        self.assertTrue(disabled_by(self.conf, CAMSS_NO_PRODUCT))

    def test_leaves_other_cameras_alone(self):
        self.assertFalse(disabled_by(self.conf, VIMC))
        self.assertFalse(disabled_by(self.conf, WEBCAM))

    def test_does_not_match_on_keys_added_after_creation(self):
        # api.v4l2.cap.* is set by the V4L2 device object after WirePlumber
        # has applied the rules, so a match on it would never fire.
        text = read(WP_RULE)
        keys = re.findall(r"^\s*([a-z][\w.-]*)\s*=", text, re.M)
        self.assertFalse([k for k in keys if k.startswith("api.v4l2.cap")])

    def test_libcamera_monitor_not_disabled(self):
        self.assertNotIn("monitor.libcamera", read(WP_RULE).split("monitor.v4l2.rules")[1])
        self.assertNotIn("wireplumber.profiles", self.conf)

    def test_vm_rule_hides_vimc_only(self):
        hook = read(VM_HOOK)
        m = re.search(r"91-antumbra-camera-vm\.conf <<'CONF'\n(.*?)\nCONF\n", hook, re.S)
        self.assertIsNotNone(m)
        vm = spa_json_parse(m.group(1))
        self.assertTrue(disabled_by(vm, VIMC))
        self.assertFalse(disabled_by(vm, WEBCAM))


class PackagesTest(unittest.TestCase):
    def test_snapshot_replaces_megapixels(self):
        apps = package_list("apps")
        for p in ("gnome-snapshot", "libcamera-ipa", "libspa-0.2-libcamera"):
            self.assertIn(p, apps)
        self.assertNotIn("megapixels", apps)

    def test_backports_pin_covers_the_camera_stack(self):
        prefs = read(os.path.join(ROOT, "config", "rootfs", "etc", "apt", "preferences.d", "antumbra-backports"))
        stanza = next(s for s in prefs.split("\n\n") if "libcamera*" in s)
        for pattern in ("libcamera*", "gstreamer1.0-libcamera", "libspa-0.2-*", "pipewire*", "wireplumber"):
            self.assertIn(pattern, stanza)
        self.assertIn("Pin: release n=trixie-backports", stanza)

    def test_vm_debug_list(self):
        self.assertEqual(package_list("vm-debug"), ["libcamera-tools"])
        self.assertIn("vm-debug", read(os.path.join(ROOT, "build", "rootfs.sh")))


class LocalLibcameraTest(unittest.TestCase):
    def lock(self, key):
        m = re.search(rf"^{key}=(.*)$", read(LOCK), re.M)
        self.assertIsNotNone(m, key)
        return m.group(1)

    def test_lock_entries(self):
        self.assertRegex(self.lock("LIBCAMERA_DSC_SHA256"), r"^[0-9a-f]{64}$")
        dsc = os.path.basename(self.lock("LIBCAMERA_DSC_URL"))
        self.assertEqual(dsc, os.path.basename(self.lock("LIBCAMERA_DSC_SNAPSHOT_URL")))
        upstream = re.match(r"libcamera_(.+)\.dsc$", dsc).group(1)
        local = self.lock("LIBCAMERA_LOCAL_VERSION")
        # sorts below Debian's own 0.7.2-1 and above backports' 0.7.1
        self.assertTrue(local.startswith(upstream + "~antumbra"), local)
        self.assertTrue(self.lock("PORT_LIBCAMERA_BASE_URL").startswith(
            "https://raw.githubusercontent.com/Sr-0w/hotdog-linux-bringup/v0.2.0-alpha.2/"))

    def test_every_port_file_is_pinned(self):
        pinned = {}
        for line in read(os.path.join(LIBCAMERA, "patches.sha256")).splitlines():
            sha, name = line.split("  ", 1)
            self.assertRegex(sha, r"^[0-9a-f]{64}$")
            pinned[name] = sha
        series = [p for p in read(os.path.join(LIBCAMERA, "patches.list")).splitlines() if p]
        self.assertEqual(series, sorted(series))
        self.assertEqual([p[:4] for p in series], [f"{n:04d}" for n in range(3, 11)])
        for p in series:
            self.assertIn(p, pinned)
        tuning = sorted(n for n in pinned if n.endswith(".yaml"))
        self.assertEqual(tuning, ["imx471.yaml", "imx481.yaml", "imx586.yaml", "s5k3m5.yaml"])
        self.assertEqual(set(pinned), set(series) | set(tuning))

    def test_packaging_diff_touches_only_debian(self):
        diff = read(os.path.join(LIBCAMERA, "antumbra-packaging.diff"))
        files = re.findall(r"^\+\+\+ b/(\S+)", diff, re.M)
        self.assertEqual(files, ["debian/control", "debian/rules"])


class KernelFragmentTest(unittest.TestCase):
    def test_vimc_only_in_the_vm(self):
        virt = read(os.path.join(ROOT, "device", "qemu-virt", "kernel", "virt.config"))
        for line in ("CONFIG_MEDIA_TEST_SUPPORT=y", "CONFIG_V4L_TEST_DRIVERS=y", "CONFIG_VIDEO_VIMC=m"):
            self.assertIn(line, virt.splitlines())
        phone = read(os.path.join(ROOT, "device", "oneplus-hotdog", "kernel", "antumbra.config"))
        self.assertNotIn("VIMC", phone)

    def test_vm_camera_hook_guarded_like_the_debug_console(self):
        # Same condition as hook 70: a debug build of the qemu-virt profile.
        guard = '[ -z "${ANTUMBRA_DEBUG:-}" ] || [ "${ANTUMBRA_DEVICE:-}" != "qemu-virt" ]'
        self.assertIn(guard, read(os.path.join(ROOT, "config", "hooks", "70-debug-console.sh")))
        hook = read(VM_HOOK)
        self.assertIn(guard, hook)
        # the guard comes before anything is written
        self.assertLess(hook.index(guard), hook.index("cat >"))
        self.assertIn("\nvimc\n", hook)
        rootfs = read(os.path.join(ROOT, "build", "rootfs.sh"))
        self.assertIn('if [ -n "${ANTUMBRA_DEBUG}" ] && [ "${ANTUMBRA_DEVICE}" = "qemu-virt" ]; then\n        LISTS+=(vm-debug)', rootfs)


class VmHarnessTest(unittest.TestCase):
    """The parts of the VM camera checks that run on data: the pw-dump
    parser that runs in the guest, and the colour-bar classifier."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("antumbra_vm", os.path.join(ROOT, "tests", "vm", "antumbra_vm.py"))
        cls.vm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.vm)

    def test_pw_dump_parser(self):
        dump = [
            {"id": 40, "type": "PipeWire:Interface:Device", "info": {"props": {
                "device.api": "libcamera", "media.class": "Video/Device", "device.product.name": "Sensor B",
                "device.name": "libcamera_device.platform_vimc.0_Sensor_B", "api.libcamera.path": "platform/vimc.0 Sensor B"}}},
            {"id": 41, "type": "PipeWire:Interface:Device", "info": {"props": {
                "device.api": "v4l2", "media.class": "Video/Device", "device.product.name": "vimc",
                "device.name": "v4l2_device.platform-vimc.0-video-index0"}}},
            {"id": 50, "type": "PipeWire:Interface:Node", "info": {"state": "running", "props": {
                "media.class": "Video/Source", "device.id": 40, "node.name": "libcamera_input.platform_vimc.0_Sensor_B"}}},
            {"id": 51, "type": "PipeWire:Interface:Node", "info": {"state": "suspended", "props": {
                "media.class": "Video/Source", "api.v4l2.path": "/dev/video0", "node.name": "v4l2_input.platform-vimc.0-video-index0"}}},
            {"id": 52, "type": "PipeWire:Interface:Node", "info": {"state": "idle", "props": {
                "media.class": "Audio/Sink", "node.name": "speakers"}}},
            {"id": 53, "type": "PipeWire:Interface:Client", "info": {"props": {"application.name": "x"}}},
        ]
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "pw.json")
            with open(src, "w") as f:
                json.dump(dump, f)
            script = os.path.join(d, "parse.py")
            with open(script, "w") as f:
                f.write(self.vm.PW_CAMERAS)
            out = subprocess.run([sys.executable, script, src], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out.splitlines(), [
            'device libcamera "Sensor B" libcamera_device.platform_vimc.0_Sensor_B',
            'device v4l2 "vimc" v4l2_device.platform-vimc.0-video-index0',
            "node libcamera running libcamera_input.platform_vimc.0_Sensor_B",
            "node v4l2 suspended v4l2_input.platform-vimc.0-video-index0",
        ])

    def test_colour_bars(self):
        class FakeVM:
            def __init__(self, colours):
                self.colours = colours

            def pixels(self):
                w, h = 80, 40
                row = b"".join(bytes(self.colours[x * len(self.colours) // w]) for x in range(w))
                return w, h, row * h
        # vimc's 75% bars: white, yellow, cyan, green, magenta, red, blue, black
        bars = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0), (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]
        seen = self.vm.colour_bars(FakeVM(bars))
        self.assertEqual(sorted(k for k, v in seen.items() if v >= 0.1),
                         ["blue", "cyan", "green", "magenta", "red", "yellow"])
        # the theme's dark surfaces and light accent are none of those hues
        theme = self.vm.colour_bars(FakeVM([(0x1c, 0x1b, 0x1f), tuple(self.vm.WELCOME_ACCENT), (255, 255, 255)]))
        self.assertEqual(sum(theme.values()), 0)

    def test_access_monitor_is_posix_sh(self):
        if not shutil.which("dash"):
            self.skipTest("dash not installed")
        with tempfile.NamedTemporaryFile("w", suffix=".sh") as f:
            f.write(self.vm.ACCESS_MONITOR)
            f.flush()
            subprocess.run(["dash", "-n", f.name], check=True)

    def test_oneplus_scanner_positive_control(self):
        # The fixture the camera checks build in the guest, built here: the
        # scanner must print exactly NOPC_FIXTURE_HITS for it.
        path = os.environ.get("PATH", "") + ":/usr/sbin:/sbin"
        for tool in ("mke2fs", "zstd"):
            if not shutil.which(tool, path=path):
                self.skipTest(f"{tool} not installed")
        with tempfile.TemporaryDirectory() as d:
            script = os.path.join(d, "fixture.py")
            with open(script, "w") as f:
                f.write(self.vm.NOPC_FIXTURE)
            r = subprocess.run([sys.executable, script, os.path.join(d, "nopc")], capture_output=True, text=True,
                               env=dict(os.environ, PATH=path))
            self.assertEqual((r.returncode, r.stdout), (0, "fixture ready\n"), r.stderr)
            scan = os.path.join(d, "nopc", "scan")
            r = subprocess.run([sys.executable, os.path.join(ROOT, "tests", "no-oneplus-camera.py"), scan],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, r.stderr)
            self.assertEqual(sorted(r.stdout.splitlines()), sorted(h.format(scan=scan) for h in self.vm.NOPC_FIXTURE_HITS))


class GuestScanTest(unittest.TestCase):
    """Step 5 of the VM camera checks: the scanner run over the guest's
    root file system. It reads the head of every file and Waydroid's
    images, so its time grows with the image and with emulation: its limit
    follows the harness's timeout scale and the measured size of the root
    file system, and the guest kills it before the console gives up on it
    (a scan left running would answer the next command)."""

    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("antumbra_vm", os.path.join(ROOT, "tests", "vm", "antumbra_vm.py"))
        cls.vm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.vm)

    def run_checks(self, scale=1, df="  1270  61934", scan="scan: exit 0 after 812 s"):
        calls = []
        hits = [h.format(scan="/tmp/antumbra-nopc/scan") for h in self.vm.NOPC_FIXTURE_HITS]

        def sh(cmd, timeout=120):
            calls.append((cmd, timeout))
            if cmd.startswith("df "):
                return (0, df) if df is not None else (1, "df: no such file or directory")
            if "--xdev /" in cmd:
                return 0, scan
            if "antumbra-nopc-fixture.py /tmp/antumbra-nopc" in cmd:
                return 0, "\n".join(["fixture ready"] + hits + ["scanner exit 1"])
            return None, ""
        saved = self.vm.put_file
        self.vm.put_file = lambda sh, path, data: True
        try:
            rep = self.vm.Report()
            self.vm.oneplus_scan_checks(rep, lambda s: s * scale, sh)
        finally:
            self.vm.put_file = saved
        results = {name: (ok, detail) for name, ok, detail, _ in rep.results}
        scans = [(cmd, timeout) for cmd, timeout in calls if "--xdev /" in cmd]
        self.assertEqual(len(scans), 1)
        m = re.search(r"\btimeout -k (\d+) (\d+) python3 /tmp/antumbra-no-oneplus-camera\.py --xdev /", scans[0][0])
        self.assertIsNotNone(m, f"the guest scan does not run under timeout: {scans[0][0]}")
        return results, int(m.group(2)), int(m.group(1)), scans[0][1]

    def test_limit_scales_with_the_timeout_scale_and_the_image(self):
        _, limit, kill, console = self.run_checks()
        # the --android image (1270 MiB of squashfs, 62 000 inodes): well
        # above the verifier's 850 s estimate under emulation
        self.assertGreaterEqual(limit, 1500)
        self.assertGreater(console, limit + kill)
        _, limit2, kill2, console2 = self.run_checks(scale=2)
        self.assertEqual(limit2, 2 * limit)
        self.assertGreater(console2, limit2 + kill2)
        _, bigger, _, _ = self.run_checks(df="  2540  124000")
        self.assertGreater(bigger, limit)
        # no size: the limit for an image twice the --android one
        _, unknown, _, _ = self.run_checks(df=None)
        self.assertEqual(unknown, bigger)

    def test_verdicts(self):
        control = "camera: the scanner finds a OnePlus camera APK inside an ext4 image and inside a zstd-compressed XAPK"
        results, _, _, _ = self.run_checks()
        self.assertEqual(results[self.vm.ONEPLUS_SCAN], (True, "none found in 812 s"))
        self.assertTrue(results[control][0])
        results, limit, _, _ = self.run_checks(scan="scan: exit 1 after 700 s\n/usr/lib/libarcsoft_beauty.so")
        self.assertEqual(results[self.vm.ONEPLUS_SCAN], (False, "/usr/lib/libarcsoft_beauty.so"))
        # killed at its limit: a failure that says so, and the positive
        # control still runs on a clean console
        results, limit, _, _ = self.run_checks(scan="scan: exit 124 after 1672 s\n/usr/a.apk: cannot inspect (zip: x)")
        self.assertFalse(results[self.vm.ONEPLUS_SCAN][0])
        self.assertTrue(results[self.vm.ONEPLUS_SCAN][1].startswith(f"the scan was stopped at its limit ({limit} s) after 1672 s"),
                        results[self.vm.ONEPLUS_SCAN][1])
        self.assertTrue(results[control][0])
        # killed by SIGKILL: timeout dies by it too, and the console's
        # interactive bash prints "Killed" before the status line. After
        # its limit (timeout's -k 30): stopped at its limit, with the
        # findings after the status line.
        results, limit, kill, _ = self.run_checks(scan=f"Killed\nscan: exit 137 after {limit + 30} s\n/usr/a.apk: cannot inspect (zip: x)")
        self.assertEqual(results[self.vm.ONEPLUS_SCAN],
                         (False, f"the scan was stopped at its limit ({limit} s) after {limit + kill} s: /usr/a.apk: cannot inspect (zip: x)"))
        self.assertTrue(results[control][0])
        # before its limit (the OOM killer, say): not "stopped at its limit"
        results, _, _, _ = self.run_checks(scan="Killed\nscan: exit 137 after 300 s")
        self.assertEqual(results[self.vm.ONEPLUS_SCAN], (False, "scanner exit 137"))
        # a status line anywhere else is no status line
        results, _, _, _ = self.run_checks(scan="Killed\nscan: exit 0 after 300 s and more")
        self.assertFalse(results[self.vm.ONEPLUS_SCAN][0])
        self.assertTrue(results[self.vm.ONEPLUS_SCAN][1].startswith("no status from the scan: Killed"), results[self.vm.ONEPLUS_SCAN])
        # no status line: the scan did not run as asked
        results, _, _, _ = self.run_checks(scan="python3: can't open file")
        self.assertFalse(results[self.vm.ONEPLUS_SCAN][0])


class CameraAccessDocsTest(unittest.TestCase):
    """Wherever the docs describe the planned Tor Browser confinement for the
    cameras (devices and PipeWire's socket), they must also name the camera
    portal and its permission store: the portal hands any host program a
    connected PipeWire file descriptor over the session bus once the
    session's single decision for host programs is yes, and any session
    process can write that decision."""

    def paragraphs(self, text):
        # blank-line paragraphs, split further at list items and table rows
        for block in re.split(r"\n\s*\n", text):
            yield from (" ".join(p.split()) for p in re.split(r"\n(?=\s*(?:[-*] |\d+\. |\|))", block))

    def test_planned_confinement_covers_the_camera_portal(self):
        # Also: the profile is an allow-list (deny rules for the portal next
        # to a broad session-bus allow leave the systemd user manager and
        # D-Bus activation open), and PipeWire listens on two sockets.
        found = 0
        for name in sorted(os.listdir(os.path.join(ROOT, "docs"))):
            if not name.endswith(".md"):
                continue
            for p in self.paragraphs(read(os.path.join(ROOT, "docs", name))):
                if re.search(r"PipeWire('s)? sockets?\b|pipewire-0", p):
                    found += 1
                    self.assertIn("camera portal", p, f"{name}: {p[:200]}")
                    self.assertIn("permission store", p.lower(), f"{name}: {p[:200]}")
                    self.assertIn("allow-list", p, f"{name}: {p[:200]}")
                    self.assertRegex(p, r"pipewire-0-manager|pipewire-0\*", f"{name}: {p[:200]}")
                    self.assertIn("systemd user manager", p, f"{name}: {p[:200]}")
                    self.assertIn("D-Bus activation", p, f"{name}: {p[:200]}")
        # camera.md, roadmap.md, known-issues.md, threat-model.md
        self.assertGreaterEqual(found, 4)

    def test_deny_rules_are_not_presented_as_enough(self):
        camera = " ".join(read(os.path.join(ROOT, "docs", "camera.md")).split())
        section = camera[camera.index("## Who can use the cameras"):camera.index("## Why there is no OnePlus Camera")]
        self.assertIn("Deny rules alone are not enough", section)
        self.assertIn("StartTransientUnit", section)
        self.assertNotIn("Better, the profile allows", section)
        # The VM's portal check runs unconfined; it must run under the
        # profile once there is one.
        for doc in ("camera.md", "vm-testing.md"):
            self.assertIn("aa-exec -p", read(os.path.join(ROOT, "docs", doc)), doc)


class OnePlusScannerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("nopc", os.path.join(ROOT, "tests", "no-oneplus-camera.py"))
        cls.nopc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.nopc)

    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def apk(self, name, package):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            # binary manifests store strings as UTF-16LE
            z.writestr("AndroidManifest.xml", b"\x03\x00\x08\x00" + package.encode("utf-16-le"))
        path = os.path.join(self.tmp, name)
        with open(path, "wb") as f:
            f.write(buf.getvalue())
        return path

    def touch(self, *parts):
        path = os.path.join(self.tmp, *parts)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close()
        return path

    def test_finds_oneplus_camera_software(self):
        hits = {
            self.touch("system", "priv-app", "OnePlusCamera", "OnePlusCamera.apk"),
            self.touch("vendor", "lib64", "camera.qcom.so"),
            self.touch("vendor", "lib64", "com.qti.chi.override.so"),
            self.touch("vendor", "firmware", "CAMERA_ICP.elf"),
            self.touch("lib", "libarcsoft_beauty_shot.so"),
            self.apk("renamed.apk", "com.oneplus.camera"),
        }
        self.assertEqual(set(self.nopc.scan(self.tmp, False, set())), hits)

    def test_ignores_free_software(self):
        self.touch("usr", "lib", "aarch64-linux-gnu", "libcamera.so.0.7")
        self.touch("usr", "share", "libcamera", "ipa", "simple", "imx471.yaml")
        self.touch("usr", "lib", "firmware", "qcom", "sm8150", "oneplus", "hotdog", "venus.mbn")
        self.apk("F-Droid.apk", "org.fdroid.fdroid")
        self.apk("OpenCamera.apk", "net.sourceforge.opencamera")   # free software, not op*camera*
        self.assertEqual(self.nopc.scan(self.tmp, False, set()), [])

    def test_skip(self):
        self.touch("build", "cache", "CAMERA_ICP.elf")
        self.assertEqual(self.nopc.scan(self.tmp, False, {os.path.join(self.tmp, "build", "cache")}), [])

    def main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = self.nopc.main(list(argv))
        return rc, out.getvalue()

    def test_a_root_it_cannot_read_fails(self):
        # A mistyped path must not report a clean image.
        missing = os.path.join(self.tmp, "missing")
        os.symlink(missing, os.path.join(self.tmp, "dangling"))
        for argv in ([missing], ["--xdev", missing], [os.path.join(self.tmp, "dangling")]):
            with self.subTest(argv=argv):
                rc, out = self.main(*argv)
                self.assertEqual(rc, 1, out)
                self.assertEqual(out, f"{argv[-1]}: cannot inspect (No such file or directory)\n")
        self.assertEqual(self.main(self.tmp), (0, ""))

    def test_a_directory_it_cannot_list_fails(self):
        # (root may list any directory, so the refusal is simulated)
        locked = os.path.dirname(self.touch("locked", "CAMERA_ICP.elf"))
        gone = os.path.dirname(self.touch("gone", "x"))
        real = os.scandir

        def scandir(path="."):
            if os.path.normpath(path) == locked:
                raise PermissionError(13, "Permission denied", path)
            if os.path.normpath(path) == gone:   # removed while the scan ran
                raise FileNotFoundError(2, "No such file or directory", path)
            return real(path)
        with unittest.mock.patch("os.scandir", scandir):
            self.assertEqual(self.nopc.scan(self.tmp, False, set()), [f"{locked}: cannot list (Permission denied)"])
            self.assertEqual(self.nopc.scan(locked, False, set()), [f"{locked}: cannot list (Permission denied)"])
            self.assertEqual(self.nopc.scan(gone, False, set()), [f"{gone}: cannot list (No such file or directory)"])

    # --- Packages in bundles, archives, compressed files and disk images ------
    def write(self, rel, data):
        path = os.path.join(self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def scan(self, path=None):
        return set(self.nopc.scan(path or self.tmp, False, set()))

    def tool(self, name):
        path = shutil.which(name, path=os.environ.get("PATH", "") + ":/usr/sbin:/sbin")
        if not path:
            self.skipTest(f"{name} not installed")
        return path

    def test_finds_packages_in_bundles(self):
        camera = apk_bytes("com.oneplus.camera")
        # XAPK: the package name in manifest.json, and the APK inside
        xapk = self.write("camera.xapk", zip_bytes([("manifest.json", json.dumps({"package_name": "com.oneplus.camera"}).encode()),
                                                    ("base.apk", camera), ("icon.png", b"\x89PNG")]))
        hits = {xapk, xapk + "!/base.apk"}
        # APKS (bundletool, SAI): split APKs under splits/, nothing in toc.pb
        apks = self.write("camera.apks", zip_bytes([("toc.pb", b"\x0a\x00"), ("splits/base-master.apk", camera),
                                                    ("splits/base-arm64_v8a.apk", apk_bytes("com.oneplus.camera", split=True))]))
        hits |= {apks + "!/splits/base-master.apk", apks + "!/splits/base-arm64_v8a.apk"}
        # APKM (APKMirror): info.json and the APKs
        apkm = self.write("camera.apkm", zip_bytes([("info.json", json.dumps({"pname": "com.oneplus.camera"}).encode()),
                                                    ("base.apk", camera)]))
        hits |= {apkm, apkm + "!/base.apk"}
        # An app bundle: its manifest is protobuf, the name in UTF-8
        hits.add(self.write("camera.aab", zip_bytes([("base/manifest/AndroidManifest.xml", b"\x0a\x12com.oneplus.camera")])))
        # A lone split APK under any name
        hits.add(self.write("split_config.arm64_v8a.apk", apk_bytes("com.oneplus.camera", split=True)))
        self.assertEqual(self.scan(), hits)

    def test_finds_compressed_and_archived_files(self):
        camera = apk_bytes("com.oneplus.camera")
        hits = {
            # by name, also with a compression suffix
            self.write("vendor/lib64/camera.qcom.so.xz", lzma.compress(b"\x7fELF" + bytes(64))),
            self.write("vendor/lib64/libmpbase.so.zst", b"\x28\xb5\x2f\xfd"),
            self.write("app/OPCamera.apk.gz", gzip.compress(camera)),
            # by content: a renamed APK compressed four ways
            self.write("data/a.bin.gz", gzip.compress(camera)),
            self.write("data/a.bin.xz", lzma.compress(camera)),
            self.write("data/a.bin.bz2", bz2.compress(camera)),
        }
        tar = self.write("data/vendor.tar", tar_bytes([("vendor/lib64/camera.qcom.so", b"\x7fELF"), ("vendor/etc/a.txt", b"text")]))
        hits.add(tar + "!/vendor/lib64/camera.qcom.so")
        txz = self.write("data/apps.tar.xz", lzma.compress(tar_bytes([("app/x.apk", camera)])))
        hits.add(txz + "!/app/x.apk")
        zf = self.write("data/blobs.zip", zip_bytes([("lib/libcamxexternalformatutils.so", b"\x7fELF"), ("README", b"text")]))
        hits.add(zf + "!/lib/libcamxexternalformatutils.so")
        if shutil.which("zstd"):
            zst = self.write("data/a.bin.zst", subprocess.run(["zstd", "-q", "-c"], input=camera, capture_output=True,
                                                              check=True).stdout)
            tzst = self.write("data/apps.tar.zst", subprocess.run(["zstd", "-q", "-c"], input=tar_bytes([("app/y.apk", camera)]),
                                                                  capture_output=True, check=True).stdout)
            hits |= {zst, tzst + "!/app/y.apk"}
        self.assertEqual(self.scan(), hits)

    def test_finds_firmware_in_an_initramfs(self):
        # An early uncompressed archive, then the main one compressed, as
        # initramfs-tools writes them.
        early = cpio_bytes([("kernel/x86/microcode/AuthenticAMD.bin", b"ucode data")])
        main = cpio_bytes([("usr/lib/firmware/qcom/sm8150/CAMERA_ICP.elf", b"\x7fELF"), ("init", b"#!/bin/sh\n"),
                           ("usr/lib/modules/x.apk", apk_bytes("com.oneplus.camera"))])
        img = self.write("boot/initrd.img", early + bytes(512) + gzip.compress(main))
        self.assertEqual(self.scan(), {img + "!/usr/lib/firmware/qcom/sm8150/CAMERA_ICP.elf", img + "!/usr/lib/modules/x.apk"})

    def android_tree(self, root, oneplus=True):
        """A small /system tree, like Waydroid's images; with ONEPLUS, a
        renamed OnePlus camera APK and an APEX whose payload image holds
        another one. Returns the paths (inside the image) that must be found."""
        def put(rel, data):
            path = os.path.join(root, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as f:
                f.write(data)
        rnd = random.Random(7)
        put("system/app/F-Droid/F-Droid.apk", apk_bytes("org.fdroid.fdroid"))
        put("system/app/Camera2/Camera2.apk", apk_bytes("com.android.camera2"))
        put("system/framework/framework.jar", zip_bytes([("classes.dex", rnd.randbytes(70000))], zipfile.ZIP_STORED))
        put("system/lib64/libbig.so", rnd.randbytes(300 * 1024 + 123))   # indirect blocks on 1 KiB ext2
        with open(os.path.join(root, "system", "lib64", "libholes.so"), "wb") as f:
            for i in range(17):      # holes: an ext4 extent tree with an index level, block map holes
                f.seek(i * 65536)    # (none at the end: mke2fs -d loses a final hole with inline_data)
                f.write(rnd.randbytes(4096 if i < 16 else 100))
        put("system/etc/tiny.txt", b"inline candidate\n")
        put("system/usr/share/doc.txt.gz", gzip.compress(b"documentation\n" * 100))
        for i in range(300):
            put(f"system/usr/many/file{i:04d}.txt", f"{i}\n".encode())
        payload_src = os.path.join(self.tmp, "payload-src")
        inner, data = ("app/Inner/Inner.apk", apk_bytes("com.oneplus.camera")) if oneplus else ("etc/x.txt", b"x\n")
        os.makedirs(os.path.dirname(os.path.join(payload_src, inner)))
        with open(os.path.join(payload_src, inner), "wb") as f:
            f.write(data)
        if oneplus:
            put("system/app/Renamed/Renamed.apk", apk_bytes("com.oneplus.camera"))
        payload = os.path.join(self.tmp, "apex_payload.img")
        subprocess.run([self.tool("mke2fs"), "-q", "-F", "-t", "ext4", "-d", payload_src, payload, "1M"], check=True,
                       capture_output=True)
        with open(payload, "rb") as f:
            put("system/apex/com.android.foo.apex", zip_bytes([("AndroidManifest.xml", apk_manifest("com.android.foo")),
                                                               ("apex_payload.img", f.read())], zipfile.ZIP_STORED))
        os.unlink(payload)
        shutil.rmtree(payload_src)
        return {"/system/app/Renamed/Renamed.apk",
                "/system/apex/com.android.foo.apex!/apex_payload.img!/app/Inner/Inner.apk"} if oneplus else set()

    def images(self, src):
        """{image path: mkfs description}: ext2/3/4 variants, a sparse image
        and uncompressed EROFS variants of SRC."""
        mke2fs = self.tool("mke2fs")
        out = {}
        variants = {
            "ext4.img": ["-t", "ext4"],                                       # 64bit, metadata_csum, extents
            "waydroid.img": ["-t", "ext4", "-O", "^64bit,^metadata_csum"],     # the Waydroid images' features
            "ext2-1k.img": ["-t", "ext2", "-b", "1024"],                       # block maps, indirect blocks
            "inline.img": ["-t", "ext4", "-O", "inline_data", "-I", "256"],    # small files and dirs in the inode
        }
        for name, opts in variants.items():
            path = os.path.join(self.tmp, "images", name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            subprocess.run([mke2fs, "-q", "-F", *opts, "-d", src, path, "16M"], check=True, capture_output=True)
            out[path] = " ".join(opts)
        # hashed directories (dir_index)
        htree = os.path.join(self.tmp, "images", "htree.img")
        shutil.copy(os.path.join(self.tmp, "images", "ext4.img"), htree)
        rc = subprocess.run([self.tool("e2fsck"), "-fyD", htree], capture_output=True).returncode
        self.assertIn(rc, (0, 1))
        out[htree] = "e2fsck -D"
        if shutil.which("img2simg"):
            sparse = os.path.join(self.tmp, "images", "ext4.simg")
            subprocess.run(["img2simg", os.path.join(self.tmp, "images", "waydroid.img"), sparse], check=True, capture_output=True)
            out[sparse] = "img2simg"
        if shutil.which("mkfs.erofs"):
            # (chunks smaller than the holes in libholes.so: erofs-utils 1.7.1
            # writes chunk tables that even its own fsck.erofs extracts wrongly)
            for name, opts in {"erofs.img": [], "erofs-ext.img": ["-Eforce-inode-extended"],
                               "erofs-noinline.img": ["-Enoinline_data"], "erofs-chunks.img": ["--chunksize=65536"]}.items():
                path = os.path.join(self.tmp, "images", name)
                subprocess.run(["mkfs.erofs", "--quiet", *opts, path, src], check=True, capture_output=True)
                out[path] = "mkfs.erofs " + " ".join(opts)
        return out

    def test_finds_oneplus_camera_apps_in_android_images(self):
        src = os.path.join(self.tmp, "src")
        inside = self.android_tree(src)
        images = self.images(src)
        shutil.rmtree(src)
        expected = {img + "!" + p for img in images for p in inside}
        self.assertEqual(self.scan(os.path.join(self.tmp, "images")), expected)

    def test_waydroid_like_images_are_clean(self):
        src = os.path.join(self.tmp, "src")
        self.assertEqual(self.android_tree(src, oneplus=False), set())
        self.images(src)
        shutil.rmtree(src)
        self.assertEqual(self.scan(), set())

    def test_image_readers_return_every_file(self):
        # The scanner sees every file of an image with its exact content.
        src = os.path.join(self.tmp, "src")
        self.android_tree(src)
        want = {}
        for dirpath, _, files in os.walk(src):
            for name in files:
                with open(os.path.join(dirpath, name), "rb") as f:
                    want[os.path.relpath(os.path.join(dirpath, name), src)] = f.read()
        for img, how in self.images(src).items():
            with open(img, "rb") as f:
                kind = self.nopc.sniff(f.read(self.nopc.HEAD))
                if kind == "sparse":
                    f = self.nopc.buffered(self.nopc.sparse_image(f))
                    kind = self.nopc.sniff(self.nopc.read_at(f, 0, self.nopc.HEAD))
                fs = self.nopc.Ext(f) if kind == "ext" else self.nopc.Erofs(f)
                got, stack = {}, [("", fs.root())]
                while stack:
                    path, d = stack.pop()
                    for name, child in fs.listdir(d):
                        p = (path + "/" + name.decode()).lstrip("/")
                        if child.is_dir():
                            stack.append((p, child))
                        elif child.is_reg():
                            got[p] = self.nopc.buffered(fs.open(child)).read()
                got.pop("lost+found", None)
                self.assertEqual(sorted(got), sorted(want), how)
                for p in want:
                    self.assertEqual(got[p], want[p], f"{how}: {p}")

    def test_fails_closed_on_what_it_cannot_read(self):
        unreadable = [
            self.write("super.img", bytes(4096) + b"gDla" + struct.pack("<I", 52) + bytes(200)),
            self.write("payload.bin", b"CrAU" + struct.pack(">Q", 2) + bytes(200)),
            self.write("damaged.gz", b"\x1f\x8b\x08\x00" + bytes(40)),
        ]
        # an encrypted member: set the flag in the local and central headers
        z = bytearray(zip_bytes([("lib/x.so", b"\x7fELF data")]))
        for sig, off in ((b"PK\x03\x04", 6), (b"PK\x01\x02", 8)):
            i = z.index(sig)
            z[i + off] |= 1
        unreadable.append(self.write("encrypted.zip", bytes(z)))
        # containers nested more than MAX_DEPTH deep
        nested = apk_bytes("org.example")
        for _ in range(getattr(self.nopc, "MAX_DEPTH", 8) + 2):
            nested = gzip.compress(nested)
        unreadable.append(self.write("nested.gz", nested))
        src = os.path.join(self.tmp, "src")
        os.makedirs(src)
        with open(os.path.join(src, "x.apk"), "wb") as f:
            f.write(apk_bytes("com.oneplus.camera"))
        with open(os.path.join(src, "notes.txt"), "w") as f:
            f.write("compressible\n" * 10000)
        img = os.path.join(self.tmp, "full.img")
        subprocess.run([self.tool("mke2fs"), "-q", "-F", "-t", "ext4", "-d", src, img, "4M"], check=True, capture_output=True)
        with open(img, "rb") as f:
            unreadable.append(self.write("truncated.img", f.read(64 * 1024)))
        os.unlink(img)
        if shutil.which("mkfs.erofs"):
            subprocess.run(["mkfs.erofs", "--quiet", "-zlz4", os.path.join(self.tmp, "compressed.erofs"), src],
                           check=True, capture_output=True)
            unreadable.append(os.path.join(self.tmp, "compressed.erofs"))
        shutil.rmtree(src)
        hits = self.scan()
        for path in unreadable:
            self.assertTrue([h for h in hits if h.startswith(path) and "cannot inspect" in h], (path, hits))
        if shutil.which("mkfs.erofs"):
            self.assertTrue([h for h in hits if "compressed.erofs: cannot inspect" in h and "compressed EROFS file" in h], hits)

    def test_no_false_alarm_on_ext_magic_in_other_data(self):
        # A file with the ext2 magic at its offset but no superblock around it
        data = bytearray(random.Random(3).randbytes(8192))
        data[1080:1082] = b"\x53\xef"
        self.write("blob.bin", bytes(data))
        self.write("notes.txt", b"070701 is not a cpio header on its own\n" * 10)
        self.assertEqual(self.scan(), set())


def apk_manifest(package):
    # binary manifests store strings as UTF-16LE
    return b"\x03\x00\x08\x00" + package.encode("utf-16-le")


def apk_bytes(package, split=False):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("AndroidManifest.xml", apk_manifest(package) + (b"s\x00p\x00l\x00i\x00t\x00" if split else b""))
        z.writestr("classes.dex", b"dex\n035\x00" + bytes(64))
    return buf.getvalue()


def zip_bytes(members, compression=zipfile.ZIP_DEFLATED):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression) as z:
        for name, data in members:
            z.writestr(name, data)
    return buf.getvalue()


def tar_bytes(members):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for name, data in members:
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def cpio_bytes(members):
    """A newc cpio archive of regular files."""
    out = []
    for ino, (name, data, mode) in enumerate([(n, d, 0o100644) for n, d in members] + [("TRAILER!!!", b"", 0)], 1):
        nb = name.encode() + b"\x00"
        fields = [ino, mode, 0, 0, 1, 0, len(data), 0, 0, 0, 0, len(nb), 0]
        out.append(b"070701" + b"".join(b"%08X" % v for v in fields) + nb + bytes(-(110 + len(nb)) % 4)
                   + data + bytes(-len(data) % 4))
    return b"".join(out)


if __name__ == "__main__":
    unittest.main()
