# SPDX-License-Identifier: GPL-3.0-or-later
"""The phone's own firmware (antumbra-phone-firmware; runs on the build host):
Android's logical-partition metadata as liblp writes it, the device-mapper
table for vendor, ath10k's board-2.bin and firmware-5.bin, the link farm in
the names the kernel asks for, the boot order of the services, and the
module and kernel settings they rely on. The real partitions are proprietary,
so these use synthetic ones; docs/vm-testing.md describes the run against an
OxygenOS image in the VM."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
import re
import struct
import tempfile
import unittest
from unittest import mock

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
SCRIPT = os.path.join(ROOT, "config", "rootfs", "usr", "local", "lib", "antumbra-phone-firmware")


def load():
    loader = importlib.machinery.SourceFileLoader("antumbra_phone_firmware", SCRIPT)
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


pf = load()


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


# --- a liblp writer, from AOSP fs_mgr/liblp/include/liblp/metadata_format.h --------

def lp_geometry(max_size, slots, block=4096):
    body = struct.pack("<II", 0x616C4467, 52) + bytes(32) + struct.pack("<III", max_size, slots, block)
    digest = hashlib.sha256(body).digest()
    return (body[:8] + digest + body[40:]).ljust(4096, b"\0")


def lp_metadata(partitions, extents, minor=0, devices=("super",)):
    """partitions: [(name, attributes, first_extent, count)];
    extents: [(sectors, type, target, source)]."""
    p = b"".join(name.encode().ljust(36, b"\0") + struct.pack("<IIII", attr, first, count, 0)
                 for name, attr, first, count in partitions)
    e = b"".join(struct.pack("<QIQI", *x) for x in extents)
    g = b"default".ljust(36, b"\0") + struct.pack("<IQ", 0, 0)
    d = b"".join(struct.pack("<QIIQ", 2048, 4096, 0, 1 << 30) + n.encode().ljust(36, b"\0") + struct.pack("<I", 0)
                 for n in devices)
    tables = p + e + g + d
    hsize = 256 if minor >= 2 else 128
    desc = struct.pack("<IIIIIIIIIIII",
                       0, len(partitions), 52,
                       len(p), len(extents), 24,
                       len(p) + len(e), 1, 48,
                       len(p) + len(e) + len(g), len(devices), 64)
    head = struct.pack("<IHHI", 0x414C5030, 10, minor, hsize) + bytes(32) + struct.pack("<I", len(tables)) \
        + hashlib.sha256(tables).digest() + desc
    head = head.ljust(hsize, b"\0")
    head = head[:12] + hashlib.sha256(head).digest() + head[44:]
    return head + tables


def lp_super(slot_metadata, max_size=65536, slots=2):
    """A super image: reserved block, two geometries, primary then backup
    metadata for each slot."""
    img = bytearray(4096) + lp_geometry(max_size, slots) * 2
    for copy in range(2):
        for i in range(slots):
            img += slot_metadata[i].ljust(max_size, b"\0")
    return bytes(img)


def reader(blob):
    return lambda offset, length: blob[offset:offset + length]


class LogicalPartitions(unittest.TestCase):
    PARTS = [("vendor_a", 0, 0, 1), ("system_a", 0, 1, 1), ("vendor_b", 0, 2, 2)]
    EXTENTS = [(2048, 0, 4096, 0), (4096, 0, 8192, 0), (1024, 0, 20480, 0), (1024, 0, 30720, 0)]

    def test_both_slots_parse(self):
        meta = lp_metadata(self.PARTS, self.EXTENTS)
        blob = lp_super([meta, meta])
        for slot in (0, 1):
            parts, devices = pf.lp_partitions(reader(blob), slot)
            self.assertEqual(devices, ["super"])
            self.assertEqual(parts["vendor_b"], [(1024, 0, 20480, 0), (1024, 0, 30720, 0)])
            self.assertEqual(parts["vendor_a"], [(2048, 0, 4096, 0)])

    def test_expanded_header_version_1_2(self):
        blob = lp_super([lp_metadata(self.PARTS, self.EXTENTS, minor=2)] * 2)
        self.assertIn("vendor_b", pf.lp_partitions(reader(blob), 1)[0])

    def test_corrupt_primary_falls_back_to_backup(self):
        good = lp_metadata(self.PARTS, self.EXTENTS)
        blob = bytearray(lp_super([good, good]))
        primary_b = 4096 + 8192 + 65536
        blob[primary_b + 300] ^= 0xFF  # inside the tables: checksum mismatch
        parts, _ = pf.lp_partitions(reader(bytes(blob)), 1)
        self.assertEqual(len(parts["vendor_b"]), 2)

    def test_corrupt_primary_geometry_falls_back(self):
        meta = lp_metadata(self.PARTS, self.EXTENTS)
        blob = bytearray(lp_super([meta, meta]))
        blob[4096 + 44] ^= 1  # metadata_slot_count of the primary geometry
        self.assertIn("vendor_b", pf.lp_partitions(reader(bytes(blob)), 1)[0])

    def test_garbage_is_refused(self):
        with self.assertRaises(pf.LpError):
            pf.lp_partitions(reader(bytes(300000)), 0)
        meta = bytearray(lp_metadata(self.PARTS, self.EXTENTS))
        meta[12] ^= 1  # header checksum
        with self.assertRaises(pf.LpError):
            pf.lp_partitions(reader(lp_super([bytes(meta)] * 2)), 0)

    def test_extents_out_of_bounds_are_refused(self):
        meta = lp_metadata([("vendor_b", 0, 3, 5)], self.EXTENTS)
        with self.assertRaises(pf.LpError):
            pf.lp_partitions(reader(lp_super([meta, meta])), 1)

    def test_disabled_partitions_are_ignored(self):
        meta = lp_metadata([("vendor_b", 1 << 3, 0, 1)], self.EXTENTS)
        self.assertNotIn("vendor_b", pf.lp_partitions(reader(lp_super([meta, meta])), 1)[0])

    def test_device_mapper_table(self):
        table = pf.dm_linear_table([(1024, 0, 20480, 0), (1024, 0, 30720, 0)], "/dev/sdf12", 1 << 22)
        self.assertEqual(table, "0 1024 linear /dev/sdf12 20480\n1024 1024 linear /dev/sdf12 30720")

    def test_device_mapper_table_refuses_what_it_cannot_map(self):
        self.assertIsNone(pf.dm_linear_table([], "/dev/x", 1 << 22))
        self.assertIsNone(pf.dm_linear_table([(8, 1, 0, 0)], "/dev/x", 1 << 22))      # ZERO target
        self.assertIsNone(pf.dm_linear_table([(8, 0, 0, 1)], "/dev/x", 1 << 22))      # second block device
        self.assertIsNone(pf.dm_linear_table([(16, 0, 1 << 22, 0)], "/dev/x", 1 << 22))  # past the end


def ath10k_ies(blob, start):
    """Parse IEs the way ath10k's core.c does (le32 id, le32 len, 4-byte aligned)."""
    out, off = [], start
    while off + 8 <= len(blob):
        ident, length = struct.unpack_from("<II", blob, off)
        out.append((ident, blob[off + 8:off + 8 + length]))
        off += 8 + length + (-length % 4)
    return out, off


class Ath10kFiles(unittest.TestCase):
    def test_firmware5(self):
        blob = pf.firmware5()
        self.assertEqual(len(blob), 60)
        self.assertTrue(blob.startswith(b"QCA-ATH10K\0"))
        ies, end = ath10k_ies(blob, 12)
        self.assertEqual(end, 60)
        ies = dict(ies)
        self.assertEqual(sorted(ies), [1, 2, 5, 6])
        features = int.from_bytes(ies[2], "little")
        self.assertEqual({b for b in range(24) if features >> b & 1}, {6, 18, 19, 20})
        self.assertEqual(struct.unpack("<I", ies[5])[0], 4)  # WMI op version: TLV
        self.assertEqual(struct.unpack("<I", ies[6])[0], 3)  # HTT op version: TLV

    def test_board2(self):
        files = {"bdwlan.b04": b"\x01" * 26328, "bdwlan.bin": b"\x02" * 26328, "bdwlan.102": b"\x03" * 26328,
                 "bdwlan.txt": b"not a board"}
        blob = pf.board2(files)
        magic = b"QCA-ATH10K-BOARD\0"
        self.assertTrue(blob.startswith(magic))
        boards, end = ath10k_ies(blob, 20)
        self.assertEqual(end, len(blob))
        got = []
        for ident, body in boards:
            self.assertEqual(ident, 0)
            sub = dict(ath10k_ies(body, 0)[0])
            got.append((sub[0].decode(), sub[1]))
        self.assertEqual(got, [("bus=snoc,qmi-board-id=102", b"\x03" * 26328),
                               ("bus=snoc,qmi-board-id=4", b"\x01" * 26328),
                               ("bus=snoc,qmi-board-id=ff", b"\x02" * 26328)])
        self.assertIsNone(pf.board2({"readme": b""}))


class LinkFarm(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.lib = os.path.join(self.tmp.name, "lib")
        for d in (pf.PREFIX, "qcom"):
            os.makedirs(os.path.join(self.lib, d), exist_ok=True)

    def tree(self, name, files):
        d = os.path.join(self.tmp.name, name)
        os.makedirs(d)
        for f, data in files.items():
            p = os.path.join(d, f)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as fh:
                fh.write(data)
        return d

    def test_modem(self):
        image = self.tree("modem", {"adsp.mdt": b"A", "adsp.b00": b"0", "adsp.b13": b"13", "modem.mdt": b"M",
                                    "modem.b31": b"31", "WLANMDSP.MBN": b"W", "bdwlan.bin": b"B" * 8,
                                    "modem_pr/mcfg/x.mbn": b"x"})
        found = pf.link_modem(image, self.lib)
        self.assertEqual(found, {"adsp", "modem", "wlanmdsp", "board-2"})
        p = os.path.join(self.lib, pf.PREFIX)
        self.assertEqual(os.readlink(os.path.join(p, "adsp.mbn")), os.path.join(image, "adsp.mdt"))
        for name, data in (("adsp.b13", b"13"), ("modem.b31", b"31"), ("wlanmdsp.mbn", b"W"),
                           ("modem_pr/mcfg/x.mbn", b"x")):
            with open(os.path.join(p, name), "rb") as f:
                self.assertEqual(f.read(), data)
        a = os.path.join(self.lib, pf.ATH10K)
        self.assertEqual(sorted(os.listdir(a)), ["board-2.bin", "firmware-5.bin"])
        self.assertEqual(os.stat(os.path.join(a, "board-2.bin")).st_mode & 0o777, 0o400)

    def test_mbn_is_never_shadowed(self):
        image = self.tree("modem", {"modem.mbn": b"single", "modem.mdt": b"split"})
        pf.link_modem(image, self.lib)
        self.assertEqual(os.readlink(os.path.join(self.lib, pf.PREFIX, "modem.mbn")), os.path.join(image, "modem.mbn"))

    def test_bluetooth(self):
        image = self.tree("bt", {"crbtfw21.tlv": b"t", "crnv21.bin": b"n", "crnv21.b44": b"x", "apbtfw11.tlv": b"a"})
        self.assertEqual(pf.link_bluetooth(image, self.lib), {"crbtfw21.tlv", "crnv21.bin"})
        self.assertEqual(sorted(os.listdir(os.path.join(self.lib, "qca"))), ["crbtfw21.tlv", "crnv21.bin"])

    def test_gpu_prefers_the_squashed_zap(self):
        fw = self.tree("vendor", {"a640_zap.elf": b"ELF", "a640_zap.mdt": b"MDT", "a640_zap.b00": b"0",
                                  "a640_gmu.bin": b"G", "a630_sqe.fw": b"S"})
        self.assertEqual(pf.copy_gpu(fw, self.lib), {"a640_zap", "a640_gmu", "a630_sqe"})
        with open(os.path.join(self.lib, pf.PREFIX, "a640_zap.mbn"), "rb") as f:
            self.assertEqual(f.read(), b"ELF")
        self.assertFalse(os.path.exists(os.path.join(self.lib, pf.PREFIX, "a640_zap.b00")))
        self.assertEqual(os.stat(os.path.join(self.lib, "qcom", "a640_gmu.bin")).st_mode & 0o777, 0o400)

    def test_gpu_split_zap(self):
        fw = self.tree("vendor", {"a640_zap.mdt": b"MDT", "a640_zap.b00": b"0", "a640_zap.b02": b"2"})
        self.assertEqual(pf.copy_gpu(fw, self.lib), {"a640_zap"})
        p = os.path.join(self.lib, pf.PREFIX)
        self.assertEqual(sorted(os.listdir(p)), ["a640_zap.b00", "a640_zap.b02", "a640_zap.mbn"])


class Slots(unittest.TestCase):
    def order(self, cmdline):
        with mock.patch("builtins.open", mock.mock_open(read_data=cmdline)):
            return pf.slot_order()

    def test_slot_order(self):
        self.assertEqual(self.order("quiet androidboot.slot_suffix=_a"), ["_a", "_b"])
        self.assertEqual(self.order("androidboot.slot_suffix=_b"), ["_b", "_a"])
        self.assertEqual(self.order("androidboot.slot=a"), ["_a", "_b"])
        # Antumbra lives in slot B: the default when the bootloader says nothing.
        self.assertEqual(self.order("quiet"), ["_b", "_a"])
        self.assertEqual(self.order("androidboot.slot_suffix=_c"), ["_b", "_a"])


class Main(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = os.path.join(self.tmp.name, "run")
        self.param = os.path.join(self.tmp.name, "path")
        open(self.param, "w").close()
        patches = {"BASE": base, "LIB": os.path.join(base, "lib"), "MNT": os.path.join(base, "mnt"),
                   "STATUS": os.path.join(base, "status.json"), "INCOMPLETE": os.path.join(base, "incomplete"),
                   "FW_PATH_PARAM": self.param}
        for k, v in patches.items():
            p = mock.patch.object(pf, k, v)
            p.start()
            self.addCleanup(p.stop)

    def run_main(self, modem, bluetooth, vendor, argv=("--any-device", "--wait", "0")):
        with mock.patch.object(pf, "partitions", return_value={}), \
                mock.patch.object(pf, "collect_fat", side_effect=lambda kind, *a: modem if kind == "modem" else bluetooth), \
                mock.patch.object(pf, "collect_vendor", return_value=vendor), \
                mock.patch.object(pf, "start_offline_adsp") as kick:
            self.assertEqual(pf.main(list(argv)), 0)
        with open(pf.STATUS) as f:
            return json.load(f), kick

    def test_complete(self):
        got = {"slot": "b", "files": ["x"]}
        status, kick = self.run_main(got, got, got)
        self.assertTrue(status["complete"])
        self.assertFalse(os.path.exists(pf.INCOMPLETE))
        with open(self.param) as f:
            self.assertEqual(f.read(), pf.LIB)  # no trailing newline: tqftpserv drops one byte
        kick.assert_not_called()

    def test_incomplete_then_late(self):
        got = {"slot": "b", "files": ["x"]}
        status, _ = self.run_main(got, None, None)
        self.assertFalse(status["complete"])
        self.assertTrue(os.path.exists(pf.INCOMPLETE))
        status, kick = self.run_main(None, got, got, argv=("--late", "--any-device", "--wait", "0"))
        self.assertEqual(status["modem"], got)  # kept from the early run
        self.assertTrue(status["complete"])
        self.assertFalse(os.path.exists(pf.INCOMPLETE))
        kick.assert_called_once()

    def test_other_devices_are_left_alone(self):
        with mock.patch.object(pf, "is_hotdog", return_value=False), mock.patch.object(pf, "partitions") as parts:
            self.assertEqual(pf.main([]), 0)
        parts.assert_not_called()
        self.assertFalse(os.path.exists(pf.STATUS))


class BootIntegration(unittest.TestCase):
    def unit(self, name):
        return read("config", "rootfs", "usr", "lib", "systemd", "system", name)

    def test_early_unit_runs_before_coldplug_unsandboxed(self):
        u = self.unit("antumbra-phone-firmware.service")
        self.assertIn("DefaultDependencies=no", u)
        before = re.search(r"^Before=(.*)$", u, re.M).group(1).split()
        self.assertIn("systemd-udev-trigger.service", before)
        self.assertIn("sysinit.target", before)
        self.assertIn("WantedBy=sysinit.target", u)
        # Mounts in a private namespace would be invisible to the kernel's loader.
        for word in ("PrivateMounts", "ProtectSystem", "PrivateTmp", "ReadOnlyPaths", "TemporaryFileSystem"):
            self.assertNotIn(word + "=", u)

    def test_late_unit_only_when_incomplete_and_before_the_modem(self):
        u = self.unit("antumbra-phone-firmware-late.service")
        self.assertIn("ConditionPathExists=" + pf.INCOMPLETE, u)
        before = re.search(r"^Before=(.*)$", u, re.M).group(1).split()
        self.assertEqual(sorted(before), ["rmtfs.service", "tqftpserv.service"])
        self.assertIn("--late", u)

    def test_enabled_by_the_firmware_hook(self):
        hook = read("config", "hooks", "60-base-firmware.sh")
        self.assertRegex(hook, r"systemctl enable antumbra-phone-firmware\.service antumbra-phone-firmware-late\.service")

    def test_erofs_is_a_module_loaded_only_by_name(self):
        self.assertIn("CONFIG_EROFS_FS=m", read("device", "oneplus-hotdog", "kernel", "antumbra.config").splitlines())
        self.assertIn("blacklist erofs", read("config", "rootfs", "etc", "modprobe.d", "erofs.conf").splitlines())
        self.assertIn('run("modprobe", "erofs")', read("config", "rootfs", "usr", "local", "lib", "antumbra-phone-firmware"))

    def test_partitions_are_only_read(self):
        src = read("config", "rootfs", "usr", "local", "lib", "antumbra-phone-firmware")
        self.assertTrue(pf.FAT_OPTIONS.startswith("ro,"))
        self.assertIn('"--readonly"', src)
        self.assertIn('"ro,noload,', src)
        self.assertNotIn("persist", re.sub(r"#.*", "", src))
        self.assertTrue(os.access(SCRIPT, os.X_OK))


if __name__ == "__main__":
    unittest.main()
