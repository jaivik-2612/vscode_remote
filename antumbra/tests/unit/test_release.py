# SPDX-License-Identifier: GPL-3.0-or-later
"""What build/release.sh says about the images it packages, and the stamps
that let it say so, run for real on stand-ins: release.sh on a made-up
build/out (random boot and userdata images, kernel stamps, build-flags),
rootfs.sh's firmware record on small firmware trees, squashfs.sh on a tiny
tree (where mksquashfs and veritysetup are installed), and the dm-verity
check of bootimg.sh (up to a stand-in mkbootimg) and vm-bundle.sh.
See docs/building.md and docs/legal.md, "Firmware"."""
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BUILD = os.path.join(ROOT, "build")
VERSION = "0.0.0-test"
NAME = f"antumbra-{VERSION}-oneplus-hotdog"
KREL = "6.17.0-antumbra"
ROOTHASH = "ab" * 32


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def lock_value(key):
    m = re.search(rf"^{key}=(.*)$", read(os.path.join(ROOT, "device", "oneplus-hotdog", "sources.lock")), re.M)
    return m.group(1)


class BuildOut(unittest.TestCase):
    """A temporary ANTUMBRA_OUT, ANTUMBRA_WORK and ANTUMBRA_CACHE."""

    def setUp(self):
        self.t = tempfile.mkdtemp(prefix="antumbra-release-")
        self.out = os.path.join(self.t, "out")
        self.flags = {"ANTUMBRA_DEVICE": "oneplus-hotdog", "ANTUMBRA_DEBUG": "", "ANTUMBRA_MINIMAL": "",
                      "ANTUMBRA_ANDROID": "", "ANTUMBRA_LIBCAMERA_LOCAL": "", "DEVICE_FIRMWARE": "",
                      "KERNEL_RELEASE": KREL, "ANTUMBRA_VERITY": "1"}

    def tearDown(self):
        shutil.rmtree(self.t)

    def write_flags(self, out=None):
        write(os.path.join(out or self.out, "rootfs", "build-flags"),
              "".join(f"{k}={v}\n" for k, v in self.flags.items() if v is not None))

    def env(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith("ANTUMBRA_")}
        env.update(ANTUMBRA_OUT=self.out, ANTUMBRA_WORK=os.path.join(self.t, "work"),
                   ANTUMBRA_CACHE=os.path.join(self.t, "cache"), ANTUMBRA_VERSION=VERSION,
                   SOURCE_DATE_EPOCH="0", T=self.t, ROOT=ROOT)
        env.update(extra)
        return env

    def run_script(self, script, *args, **env):
        return subprocess.run(["bash", os.path.join(BUILD, script), *args], env=self.env(**env),
                              capture_output=True, text=True, timeout=300)


class ReleaseManifestTest(BuildOut):
    def setUp(self):
        for tool in ("zstd", "split", "sha256sum"):
            if not shutil.which(tool):
                self.skipTest(f"{tool} missing")
        super().setUp()
        self.boot = os.urandom(8192)
        write(os.path.join(self.out, "boot.img"), self.boot)
        write(os.path.join(self.out, "userdata.simg"), os.urandom(16384))
        write(os.path.join(self.t, "cache", "device-assets", "dtbo.img"), os.urandom(512))
        write(os.path.join(self.t, "cache", "device-assets", "vbmeta-disabled.img"), os.urandom(512))
        write(os.path.join(self.out, "kernel", "profile"), f"ANTUMBRA_DEVICE=oneplus-hotdog\nKERNEL_RELEASE={KREL}\n")
        write(os.path.join(self.out, "kernel", "kernel.release"), KREL + "\n")
        write(os.path.join(self.out, "rootfs", "packages.txt"), "base-files 13.8\ntor 0.4.8.16-1\n")
        self.rel = os.path.join(self.out, "release", NAME)

    def firmware_list(self, text):
        write(os.path.join(self.out, "rootfs", "firmware.sha256"), text)

    def release(self):
        self.write_flags()
        return self.run_script("release.sh")

    def manifest(self):
        return read(os.path.join(self.rel, "MANIFEST.md"))

    def assert_refused(self, r, message):
        self.assertNotEqual(r.returncode, 0, "release.sh packaged the images")
        self.assertIn(message, r.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.rel, "MANIFEST.md")))

    def test_without_firmware_the_manifest_says_none(self):
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        m = self.manifest()
        self.assertIn("The images contain no device firmware that is not licensed for redistribution", m)
        self.assertNotIn("Device firmware", m)
        self.assertNotIn("do not publish", r.stderr)
        with open(os.path.join(self.rel, f"{NAME}-boot.img"), "rb") as f:
            self.assertEqual(f.read(), self.boot)
        sums = read(os.path.join(self.rel, "SHA256SUMS"))
        for name in ("MANIFEST.md", f"{NAME}-userdata.simg", f"{NAME}-dtbo.img"):
            self.assertIn(f"  {name}\n", sums)
        # The sparse image ships as it is (its squashfs is already compressed),
        # byte for byte, with its hash in the manifest; fastboot flashes it directly.
        with open(os.path.join(self.out, "userdata.simg"), "rb") as f:
            simg = f.read()
        with open(os.path.join(self.rel, f"{NAME}-userdata.simg"), "rb") as f:
            self.assertEqual(f.read(), simg)
        self.assertIn(hashlib.sha256(simg).hexdigest(), m)
        self.assertIn("reads the rest at every boot from the phone's own partitions", m)

    def test_firmware_is_listed_and_warned_about(self):
        self.flags["DEVICE_FIRMWARE"] = "1"
        listing = (f"{'1' * 64}  ./ath10k/WCN3990/hw1.0/firmware-5.bin\n"
                   f"{'2' * 64}  ./qcom/sm8150/oneplus/hotdog/adsp.mbn\n")
        self.firmware_list(listing)
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        m = self.manifest()
        self.assertIn("The userdata image contains proprietary device firmware", m)
        self.assertIn("must not be published", m)
        self.assertNotIn("no device firmware that is not licensed", m)
        self.assertIn(f"## Device firmware (/lib/firmware, 2 files, not redistributable)\n\n```\n{listing}```\n", m)
        self.assertIn("this release contains your device firmware", r.stderr)

    def test_build_flags_without_a_firmware_record_are_refused(self):
        # build-flags from a rootfs.sh that did not record the firmware.
        self.flags["DEVICE_FIRMWARE"] = None
        self.assert_refused(self.release(), "does not record whether device firmware is in the image")

    def test_firmware_without_its_list_is_refused(self):
        self.flags["DEVICE_FIRMWARE"] = "1"
        self.assert_refused(self.release(), "firmware.sha256 missing")
        self.firmware_list("")
        self.assert_refused(self.release(), "firmware.sha256 missing")

    def test_squashfs_not_completed_on_this_tree_is_refused(self):
        # rootfs.sh ran again, and squashfs.sh has not (or failed): the
        # images in build/out are not from the tree build-flags describes.
        self.flags["ANTUMBRA_VERITY"] = None
        self.assert_refused(self.release(), "does not record ANTUMBRA_VERITY")

    def test_dm_verity_state_is_stated(self):
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dm-verity: on\n", self.manifest())
        self.flags["ANTUMBRA_VERITY"] = "0"
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("dm-verity: off (built with ANTUMBRA_VERITY=0;", self.manifest())

    def test_minimal_build_is_stated(self):
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("minimal build", self.manifest())
        self.flags["ANTUMBRA_MINIMAL"] = "1"
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("This is a minimal build (ANTUMBRA_MINIMAL=1), made to validate the build pipeline: it has only "
                      "the base, network and amnesia package lists, and no Phosh, applications or Tor Browser.\n\n## Files\n",
                      self.manifest())

    def test_local_libcamera_comes_with_the_source_offer(self):
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("libcamera", self.manifest().split("## Pinned inputs")[0])
        self.flags["ANTUMBRA_LIBCAMERA_LOCAL"] = "1"
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        m = self.manifest()
        self.assertIn(f"This build includes libcamera {lock_value('LIBCAMERA_LOCAL_VERSION')}, rebuilt with the hotdog-linux-bringup patches", m)
        self.assertIn("must also offer that modified source", m)

    def test_android_apps_are_named_with_their_pins(self):
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        m = self.manifest()
        self.assertNotIn("Android apps", m)
        self.assertNotIn("WAYDROID_", m)
        self.flags["ANTUMBRA_ANDROID"] = "1"
        r = self.release()
        self.assertEqual(r.returncode, 0, r.stderr)
        m = self.manifest()
        self.assertIn("This build includes Android apps", m)
        self.assertIn(f"WAYDROID_ARM64_SYSTEM_SHA256={lock_value('WAYDROID_ARM64_SYSTEM_SHA256')}\n", m)
        self.assertIn("FDROID_APK_SHA256=", m)


# rootfs.sh's record_device_firmware, defined from the script (not its main
# part), with common.sh's warn and ANTUMBRA_FIRMWARE_DIR.
FIRMWARE_DRIVER = r"""
set -euo pipefail
source "$ROOT/build/lib/common.sh"
eval "$(sed -n '/^record_device_firmware() {/,/^}/p' "$ROOT/build/rootfs.sh")"
record_device_firmware "$T/firmware" "$T/firmware.sha256"
printf 'DEVICE_FIRMWARE=%s\n' "$DEVICE_FIRMWARE"
"""


class DeviceFirmwareRecordTest(BuildOut):
    def setUp(self):
        super().setUp()
        self.fw = os.path.join(self.t, "firmware")
        os.makedirs(self.fw)
        self.listing = os.path.join(self.t, "firmware.sha256")

    NO_FIRMWARE = "ANTUMBRA_FIRMWARE_DIR holds no firmware files"

    def record(self, firmware_dir=False):
        """DEVICE_FIRMWARE as the driver prints it; its warnings in
        self.warnings. FIRMWARE_DIR: ANTUMBRA_FIRMWARE_DIR given or not."""
        env = self.env(ANTUMBRA_FIRMWARE_DIR=self.fw) if firmware_dir else self.env()
        r = subprocess.run(["bash", "-c", FIRMWARE_DRIVER, "rootfs.sh"], env=env, capture_output=True, text=True,
                           timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.warnings = r.stderr
        return r.stdout

    def test_empty_tree_is_no_firmware(self):
        self.assertEqual(self.record(), "DEVICE_FIRMWARE=\n")
        self.assertFalse(os.path.exists(self.listing))
        # Without ANTUMBRA_FIRMWARE_DIR rootfs.sh has said so already.
        self.assertEqual(self.warnings, "")

    def test_firmware_dir_without_firmware_files_is_warned_about(self):
        write(os.path.join(self.fw, "MANIFEST.sha256"), f"{'0' * 64}  ./qcom/a640_gmu.bin\n")
        os.symlink("missing.bin", os.path.join(self.fw, "a640_sqe.fw"))
        self.assertEqual(self.record(firmware_dir=True), "DEVICE_FIRMWARE=\n")
        self.assertIn(self.NO_FIRMWARE, self.warnings)

    def test_manifest_alone_is_no_firmware(self):
        # fetch-firmware.sh's MANIFEST.sha256 is not installed by hook 60.
        write(os.path.join(self.fw, "MANIFEST.sha256"), f"{'0' * 64}  ./qcom/a640_gmu.bin\n")
        self.assertEqual(self.record(), "DEVICE_FIRMWARE=\n")
        self.assertFalse(os.path.exists(self.listing))

    def test_firmware_files_are_recorded_with_their_hashes(self):
        files = {"qcom/a640_gmu.bin": b"gmu", "ath10k/WCN3990/hw1.0/board-2.bin": b"board",
                 "qcom/sm8150/oneplus/hotdog/adsp.mbn": b"adsp"}
        for name, data in files.items():
            write(os.path.join(self.fw, name), data)
        write(os.path.join(self.fw, "MANIFEST.sha256"), "not firmware\n")
        self.assertEqual(self.record(firmware_dir=True), "DEVICE_FIRMWARE=1\n")
        self.assertEqual(read(self.listing), "".join(f"{hashlib.sha256(files[n]).hexdigest()}  ./{n}\n"
                                                     for n in sorted(files)))
        self.assertEqual(self.warnings, "")

    def test_symbolic_links_alone_are_no_firmware(self):
        # Hook 60 copies them, but they hold no firmware: the decision
        # follows the list, which has regular files only.
        outside = os.path.join(self.t, "elsewhere.bin")
        write(outside, b"not in the image")
        os.makedirs(os.path.join(self.fw, "qcom"))
        os.symlink(outside, os.path.join(self.fw, "qcom", "a640_gmu.bin"))
        os.symlink("missing.bin", os.path.join(self.fw, "qcom", "a640_sqe.fw"))
        os.symlink(self.t, os.path.join(self.fw, "ath10k"))
        self.assertEqual(self.record(firmware_dir=True), "DEVICE_FIRMWARE=\n")
        self.assertFalse(os.path.exists(self.listing))
        self.assertIn(self.NO_FIRMWARE, self.warnings)

    def test_a_link_is_not_listed_its_target_is(self):
        write(os.path.join(self.fw, "qcom", "sm8150", "a640_zap.mbn"), b"zap")
        os.symlink("sm8150/a640_zap.mbn", os.path.join(self.fw, "qcom", "a640_zap.mbn"))
        self.assertEqual(self.record(), "DEVICE_FIRMWARE=1\n")
        self.assertEqual(read(self.listing), f"{hashlib.sha256(b'zap').hexdigest()}  ./qcom/sm8150/a640_zap.mbn\n")


# common.sh's helpers, with build/out in the test's directory.
COMMON_DRIVER = r"""
set -euo pipefail
source "$ROOT/build/lib/common.sh"
"$@"
"""


class StaleOutputsTest(BuildOut):
    IMAGES = ("userdata.simg", "userdata.simg.sha256", "boot.img", "boot.img.sha256",
              "vm-disk.img", "vm-disk.img.sha256")

    def common(self, *args, **env):
        return subprocess.run(["bash", "-c", COMMON_DRIVER, "driver", *args], env=self.env(**env),
                              capture_output=True, text=True, timeout=60)

    def test_remove_built_images_keeps_everything_else(self):
        kept = ("kernel/Image", "rootfs/build-flags", f"release/{NAME}/{NAME}-boot.img", "userdata.simg.zst")
        for name in self.IMAGES + kept:
            write(os.path.join(self.out, name), "x")
        r = self.common("remove_built_images")
        self.assertEqual(r.returncode, 0, r.stderr)
        for name in self.IMAGES:
            self.assertFalse(os.path.exists(os.path.join(self.out, name)), name)
        for name in kept:
            self.assertTrue(os.path.exists(os.path.join(self.out, name)), name)

    def test_rootfs_removes_what_was_built_from_the_old_tree(self):
        # rootfs.sh needs root and mmdebstrap; check that it removes the old
        # tree's stamps, squashfs and images before mmdebstrap starts.
        src = read(os.path.join(BUILD, "rootfs.sh"))
        start = src.index("\nmmdebstrap \\\n")
        for needle in ('rm -f "${ROUT}/build-flags" "${ROUT}/firmware.sha256"\n',
                       '"${ROUT}"/filesystem.squashfs{,.verity,.roothash,.sha256}', "\nremove_built_images\n"):
            self.assertNotEqual(src.find(needle), -1, needle)
            self.assertLess(src.find(needle), start, needle)
            # Before the tree: a run that stops while the tree is being
            # deleted leaves no build-flags behind.
            self.assertLess(src.find(needle), src.index('\nrm -rf "${ROOT}"\n'), needle)

    def test_rootfs_writes_build_flags_last(self):
        # Every step of rootfs.sh that can fail comes before build-flags is
        # written, so a run that fails after deleting it leaves none.
        src = read(os.path.join(BUILD, "rootfs.sh"))
        written = src.index('> "${ROUT}/build-flags"')
        self.assertEqual(src.count('"${ROUT}/build-flags"'), 2)    # deleted, then written
        for step in ("\nmmdebstrap \\\n", "\nrecord_device_firmware ", 'die "initramfs was not generated',
                     'cp "${ROOT}/boot/initrd.img-${KREL}" "${ROUT}/initrd.img"'):
            self.assertLess(src.index(step), written, step)
        self.assertNotIn("die ", src[written:])

    def squashfs(self, **env):
        # squashfs.sh insists on root; id answers 0 so it runs as anyone.
        fake = os.path.join(self.t, "bin")
        write(os.path.join(fake, "id"), "#!/bin/sh\necho 0\n")
        os.chmod(os.path.join(fake, "id"), 0o755)
        return self.run_script("squashfs.sh", PATH=fake + os.pathsep + os.environ["PATH"], **env)

    def test_squashfs_records_verity_and_removes_the_old_images(self):
        for tool in ("mksquashfs", "veritysetup"):
            if not shutil.which(tool):
                self.skipTest(f"{tool} missing")
        write(os.path.join(self.t, "work", "rootfs", "usr", "lib", "os-release"), "ID=antumbra\n")
        self.flags["ANTUMBRA_VERITY"] = "0"  # from an earlier run: replaced, not added to
        self.write_flags()
        sq = os.path.join(self.out, "rootfs", "filesystem.squashfs")
        for name in self.IMAGES:
            write(os.path.join(self.out, name), "old")
        write(sq + ".sha256", "old")

        r = self.squashfs()
        self.assertEqual(r.returncode, 0, r.stderr)
        flags = read(os.path.join(self.out, "rootfs", "build-flags"))
        self.assertEqual(re.findall(r"^ANTUMBRA_VERITY=.*$", flags, re.M), ["ANTUMBRA_VERITY=1"])
        self.assertRegex(read(sq + ".roothash").strip(), r"^[0-9a-f]{64}$")
        self.assertTrue(os.path.exists(sq + ".verity"))
        with open(sq, "rb") as f:
            self.assertEqual(read(sq + ".sha256").split()[0], hashlib.sha256(f.read()).hexdigest())
        for name in self.IMAGES:
            self.assertFalse(os.path.exists(os.path.join(self.out, name)), f"{name} outlived its squashfs")

        r = self.squashfs(ANTUMBRA_VERITY="0")
        self.assertEqual(r.returncode, 0, r.stderr)
        flags = read(os.path.join(self.out, "rootfs", "build-flags"))
        self.assertEqual(re.findall(r"^ANTUMBRA_VERITY=.*$", flags, re.M), ["ANTUMBRA_VERITY=0"])
        self.assertFalse(os.path.exists(sq + ".roothash"))


class VerityAsBuiltTest(BuildOut):
    """bootimg.sh, vm.sh and vm-bundle.sh refuse to build a kernel command
    line for another dm-verity setting than squashfs.sh's."""

    def check(self, recorded, wanted):
        self.flags["ANTUMBRA_VERITY"] = recorded
        self.write_flags()
        env = {} if wanted is None else {"ANTUMBRA_VERITY": wanted}
        return subprocess.run(["bash", "-c", COMMON_DRIVER, "driver", "require_verity_as_built"],
                              env=self.env(**env), capture_output=True, text=True, timeout=60)

    def test_require_verity_as_built(self):
        cases = [  # recorded (None: squashfs.sh has not completed), ANTUMBRA_VERITY (None: unset), accepted
            ("1", None, True), ("1", "", True), ("1", "1", True), ("1", "0", False),
            ("0", "0", True), ("0", None, False), ("0", "", False),
            (None, None, True), (None, "0", True),
        ]
        for recorded, wanted, accepted in cases:
            with self.subTest(recorded=recorded, wanted=wanted):
                r = self.check(recorded, wanted)
                if accepted:
                    self.assertEqual(r.returncode, 0, r.stderr)
                else:
                    self.assertNotEqual(r.returncode, 0)
                    self.assertIn(f"squashfs.sh built the root filesystem with ANTUMBRA_VERITY={recorded}", r.stderr)

    def test_vm_sh_checks_before_its_command_line(self):
        # vm.sh needs QEMU before it gets that far; check the order instead.
        src = read(os.path.join(BUILD, "vm.sh"))
        self.assertNotEqual(src.find("\nrequire_verity_as_built\n"), -1)
        self.assertLess(src.find("\nrequire_verity_as_built\n"), src.find("dm-verity-root-hash="))

    def bootimg_inputs(self):
        k = os.path.join(self.out, "kernel")
        image = bytearray(4096)
        image[56:60] = b"ARM\x64"
        write(os.path.join(k, "Image"), bytes(image))
        write(os.path.join(k, "sm8150-oneplus-hotdog.dtb"), b"dtb")
        write(os.path.join(k, "kernel.release"), KREL + "\n")
        write(os.path.join(k, "profile"), f"ANTUMBRA_DEVICE=oneplus-hotdog\nKERNEL_RELEASE={KREL}\n")
        write(os.path.join(self.out, "rootfs", "initrd.img"), b"initrd")
        write(os.path.join(self.out, "rootfs", "filesystem.squashfs.roothash"), ROOTHASH + "\n")
        tools = os.path.join(self.t, "cache", "tools")
        # A stand-in mkbootimg that records its arguments and stops the build.
        write(os.path.join(tools, "mkbootimg.py"),
              "import os, sys\n"
              "with open(os.path.join(os.environ['T'], 'mkbootimg.args'), 'w') as f:\n"
              "    f.write('\\n'.join(sys.argv[1:]))\n"
              "sys.exit(3)\n")
        write(os.path.join(tools, "avbtool.py"), "")
        write(os.path.join(tools, "unpack_bootimg.py"), "")
        self.args = os.path.join(self.t, "mkbootimg.args")

    def test_bootimg_refuses_another_verity_setting(self):
        if not shutil.which("python3"):
            self.skipTest("python3 missing")
        self.bootimg_inputs()
        self.write_flags()
        r = self.run_script("bootimg.sh", ANTUMBRA_VERITY="0")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("squashfs.sh built the root filesystem with ANTUMBRA_VERITY=1, not 0", r.stderr)
        self.assertFalse(os.path.exists(self.args), "mkbootimg ran")
        r = self.run_script("bootimg.sh")
        self.assertIn(f"dm-verity-root-hash=filesystem.squashfs:{ROOTHASH} ", read(self.args))

    def test_bootimg_leaves_no_old_or_unchecked_image(self):
        if not shutil.which("python3"):
            self.skipTest("python3 missing")
        self.bootimg_inputs()
        self.write_flags()
        img = os.path.join(self.out, "boot.img")
        write(img, b"built from an earlier tree")
        write(img + ".sha256", "0  boot.img\n")
        r = self.run_script("bootimg.sh")
        self.assertNotEqual(r.returncode, 0)  # the stand-in mkbootimg stops the build
        self.assertTrue(os.path.exists(self.args), "mkbootimg did not run")
        self.assertFalse(os.path.exists(img))
        self.assertFalse(os.path.exists(img + ".sha256"))
        src = read(os.path.join(BUILD, "bootimg.sh"))
        # Footer and checks on the copy in the work directory; build/out gets it last.
        self.assertLess(src.find('add_hash_footer --image "${NEWIMG}"'), src.find('mv "${NEWIMG}" "${OUTIMG}"'))
        self.assertLess(src.find('info_image --image "${NEWIMG}"'), src.find('mv "${NEWIMG}" "${OUTIMG}"'))
        self.assertEqual(src.count('"${OUTIMG}"'), 3)  # rm, mv, sha256sum

    def vm_bundle(self, **env):
        out = os.path.join(self.out, "qemu-virt")
        self.flags["ANTUMBRA_DEVICE"] = "qemu-virt"
        self.write_flags(out)
        write(os.path.join(out, "kernel", "Image"), b"kernel")
        write(os.path.join(out, "kernel", "kernel.release"), "6.17.0-antumbra-virt\n")
        write(os.path.join(out, "rootfs", "initrd.img"), b"initrd")
        write(os.path.join(out, "vm-disk.img"), os.urandom(4096))
        r = self.run_script("vm-bundle.sh", **env)
        cmdline = os.path.join(self.t, "work", "qemu-virt", "bundle", f"antumbra-{VERSION}-qemu-virt", "cmdline.txt")
        return r, (read(cmdline) if r.returncode == 0 else None)

    def test_vm_bundle_names_the_built_commit_and_gives_android_its_memory(self):
        for tool in ("zstd", "tar"):
            if not shutil.which(tool):
                self.skipTest(f"{tool} missing")
        write(os.path.join(self.out, "qemu-virt", "rootfs", "filesystem.squashfs.roothash"), ROOTHASH + "\n")
        bundle = os.path.join(self.t, "work", "qemu-virt", "bundle", f"antumbra-{VERSION}-qemu-virt")
        for android, source, mem in (("1", "0123abc", "6144"), ("", None, "4096")):
            with self.subTest(android=android):
                self.flags["ANTUMBRA_ANDROID"] = android
                self.flags["ANTUMBRA_SOURCE"] = source
                r, _ = self.vm_bundle()
                self.assertEqual(r.returncode, 0, r.stderr)
                readme, run = read(os.path.join(bundle, "README.md")), read(os.path.join(bundle, "run.sh"))
                # The commit the root filesystem was built from, not the checkout's HEAD now.
                self.assertIn(f"built from commit\n{source}." if source else "built from commit\nunknown (built before build-flags recorded it).", readme)
                self.assertIn(f'-m "${{MEM:-{mem}}}"', run)
                self.assertNotIn("@MEM@", run)
                self.assertEqual("Android apps are off until" in readme, bool(android))
        src = read(os.path.join(BUILD, "rootfs.sh"))
        self.assertIn("ANTUMBRA_SOURCE=%s", src)
        self.assertLess(src.find("SOURCE_COMMIT=\"$(git"), src.find('\nstage_overlay "${CONFIG_DIR}/rootfs"'))

    def test_vm_bundle_follows_the_recorded_setting(self):
        for tool in ("zstd", "tar"):
            if not shutil.which(tool):
                self.skipTest(f"{tool} missing")
        self.flags["ANTUMBRA_VERITY"] = "0"
        r, _ = self.vm_bundle()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("squashfs.sh built the root filesystem with ANTUMBRA_VERITY=0, not 1", r.stderr)
        r, cmdline = self.vm_bundle(ANTUMBRA_VERITY="0")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("dm-verity", cmdline)

        self.flags["ANTUMBRA_VERITY"] = "1"
        r, _ = self.vm_bundle()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no root hash", r.stderr)
        write(os.path.join(self.out, "qemu-virt", "rootfs", "filesystem.squashfs.roothash"), ROOTHASH + "\n")
        r, cmdline = self.vm_bundle()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"dm-verity-root-hash=filesystem.squashfs:{ROOTHASH} ", cmdline)


if __name__ == "__main__":
    unittest.main()
