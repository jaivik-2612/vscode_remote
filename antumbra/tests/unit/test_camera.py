# SPDX-License-Identifier: GPL-3.0-or-later
"""Static checks of the camera userspace (runs on the build host).

The WirePlumber rules must parse and must match on a key PipeWire's V4L2
udev monitor provides; the package lists and pins must give the image
Snapshot with libcamera 0.7 and the PipeWire camera plugin built against it;
every input of the optional libcamera rebuild must be pinned; the VM's
virtual camera must stay out of the phone's kernel; the OnePlus camera
scanner must find what it is meant to find. See docs/camera.md.
"""
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
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
        self.assertEqual(self.nopc.scan(self.tmp, False, set()), [])

    def test_skip(self):
        self.touch("build", "cache", "CAMERA_ICP.elf")
        self.assertEqual(self.nopc.scan(self.tmp, False, {os.path.join(self.tmp, "build", "cache")}), [])


if __name__ == "__main__":
    unittest.main()
