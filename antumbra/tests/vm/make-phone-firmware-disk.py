#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Build the disk for the VM's phone-firmware test (antumbra_vm.py
--phone-firmware DISK): a GPT disk with 4096-byte sectors, like the phone's
UFS, holding the firmware partitions of a real OxygenOS build where the
phone has them:

  antumbra-test  ext4: expected.json, the in-guest check (phone_firmware_check.py)
                 and, for images that predate them, the loader and erofs.ko
  modem_a        an empty FAT (a slot without firmware: must be passed over)
  modem_b        the OxygenOS modem image (FAT)
  bluetooth_b    the OxygenOS bluetooth image (FAT)
  super          Android logical-partition metadata (liblp format, both
                 metadata slots, primary and backup) with vendor_b, the
                 OxygenOS vendor image (EROFS), in two extents stored out of
                 order, and vendor_a, a decoy that is no file system

The OxygenOS images are proprietary and never committed: extract them from
OnePlus's full OTA for the HD1913 (F.22, the build the port validated) with
any payload extractor. The expected files are the community mirror's hashes
(device/oneplus-hotdog/firmware/firmware-files.sha256), which F.22's
partitions reproduce, except the zap shader, whose hash is vendor's own
firmware/a640_zap.elf (pass it with --zap-sha256).

usage: make-phone-firmware-disk.py --modem modem.img --bluetooth bluetooth.img
           --vendor vendor.img --zap-sha256 HEX [--kernel-build DIR] OUT
"""
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MIB = 1 << 20
SECTOR = 512
F22_MODEM = "a0bd9de273fc8145ee51b1f23a2bc39f547dfc8d148072263400f444439aa3ae"


def lp_geometry(max_size, slots, block=4096):
    body = struct.pack("<II", 0x616C4467, 52) + bytes(32) + struct.pack("<III", max_size, slots, block)
    return (body[:8] + hashlib.sha256(body).digest() + body[40:]).ljust(4096, b"\0")


def lp_metadata(partitions, extents, super_bytes):
    """liblp 10.2 metadata: partitions [(name, first extent, count)],
    extents [(sectors, target sector)], all linear on block device 0."""
    p = b"".join(n.encode().ljust(36, b"\0") + struct.pack("<IIII", 0, f, c, 1) for n, f, c in partitions)
    e = b"".join(struct.pack("<QIQI", s, 0, t, 0) for s, t in extents)
    g = b"default".ljust(36, b"\0") + struct.pack("<IQ", 0, 0) + \
        b"qti_dynamic_partitions_b".ljust(36, b"\0") + struct.pack("<IQ", 0, super_bytes // 2)
    d = struct.pack("<QIIQ", MIB // SECTOR, 4096, 0, super_bytes) + b"super".ljust(36, b"\0") + struct.pack("<I", 0)
    tables = p + e + g + d
    desc = struct.pack("<12I", 0, len(partitions), 52, len(p), len(extents), 24,
                       len(p) + len(e), 2, 48, len(p) + len(e) + len(g), 1, 64)
    head = (struct.pack("<IHHI", 0x414C5030, 10, 2, 256) + bytes(32) + struct.pack("<I", len(tables))
            + hashlib.sha256(tables).digest() + desc + struct.pack("<I", 1)).ljust(256, b"\0")
    return head[:12] + hashlib.sha256(head).digest() + head[44:] + tables


def write_gpt(path, layout, sector=4096):
    """A GPT with 4096-byte sectors (sfdisk before util-linux 2.40 cannot
    write one into a file): partitions [(name, MiB)] from 1 MiB on, in
    order. Returns {name: (byte offset, byte size)}."""
    linux = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
    total = os.path.getsize(path) // sector
    entries, offsets, lba = b"", {}, MIB // sector
    for name, mib in layout:
        count = mib * MIB // sector
        part = uuid.uuid5(uuid.NAMESPACE_URL, "antumbra-phone-firmware-test/" + name)
        entries += linux.bytes_le + part.bytes_le + struct.pack("<QQQ", lba, lba + count - 1, 0) \
            + name.encode("utf-16-le").ljust(72, b"\0")
        offsets[name] = (lba * sector, count * sector)
        lba += count
    entries = entries.ljust(128 * 128, b"\0")
    entry_lbas = len(entries) // sector
    last = total - 1
    disk = uuid.uuid5(uuid.NAMESPACE_URL, "antumbra-phone-firmware-test")

    def header(current, backup, entries_lba):
        h = struct.pack("<8sIIIIQQQQ16sQIII", b"EFI PART", 0x10000, 92, 0, 0, current, backup,
                        2 + entry_lbas, last - 1 - entry_lbas, disk.bytes_le, entries_lba, 128, 128,
                        zlib.crc32(entries))
        return (h[:16] + struct.pack("<I", zlib.crc32(h)) + h[20:]).ljust(sector, b"\0")
    mbr = bytearray(sector)
    mbr[446:462] = struct.pack("<BBBBBBBBII", 0, 0, 2, 0, 0xEE, 0xFF, 0xFF, 0xFF, 1, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    with open(path, "r+b") as f:
        f.write(mbr)
        f.write(header(1, last, 2))
        f.write(entries)
        f.seek((last - entry_lbas) * sector)
        f.write(entries)
        f.write(header(last, 1, last - entry_lbas))
    return offsets


def sha256_file(path, size=None):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        left = size if size is not None else 1 << 62
        while left > 0:
            block = f.read(min(left, 8 * MIB))
            if not block:
                break
            h.update(block)
            left -= len(block)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--modem", required=True)
    ap.add_argument("--bluetooth", required=True)
    ap.add_argument("--vendor", required=True)
    ap.add_argument("--zap-sha256", required=True)
    ap.add_argument("--kernel-build", help="kernel build directory holding fs/erofs/erofs.ko (for images without it)")
    ap.add_argument("--allow-other-build", action="store_true", help="modem image is not F.22 (expected hashes will not match)")
    ap.add_argument("out")
    a = ap.parse_args()
    if sha256_file(a.modem) != F22_MODEM and not a.allow_other_build:
        sys.exit("modem image is not OxygenOS F.22's (sha256 a0bd9de2...); the expected hashes are F.22's")
    vendor_size = os.path.getsize(a.vendor)
    if vendor_size % (8 * SECTOR):
        sys.exit("vendor image size is not a multiple of 4096")

    # Partition sizes (MiB) and the super layout.
    half = vendor_size // SECTOR // 8 // 2 * 8          # first extent, in sectors
    rest = vendor_size // SECTOR - half
    second_at = MIB // SECTOR                            # the vendor's second half, stored first
    first_at = second_at + (rest * SECTOR + 4 * MIB) // SECTOR // 8 * 8
    decoy_at = first_at + (half * SECTOR + 4 * MIB) // SECTOR // 8 * 8
    super_mib = (decoy_at * SECTOR + 8 * MIB) // MIB + 1
    layout = [("antumbra-test", 32), ("modem_a", 8), ("modem_b", 256), ("bluetooth_b", 64), ("super", super_mib)]

    work = tempfile.mkdtemp(prefix="phone-fw-disk-")
    try:
        total_mib = sum(s for _, s in layout) + 2
        with open(a.out, "wb") as f:
            f.truncate(total_mib * MIB)
        offset = write_gpt(a.out, layout)

        def put(name, src_path=None, data=None, at=0):
            start, size = offset[name]
            with open(a.out, "r+b") as out:
                out.seek(start + at)
                if data is not None:
                    assert at + len(data) <= size
                    out.write(data)
                    return
                with open(src_path, "rb") as src:
                    n = 0
                    while True:
                        block = src.read(8 * MIB)
                        if not block:
                            break
                        n += len(block)
                        assert at + n <= size, name
                        out.write(block)

        put("modem_b", a.modem)
        put("bluetooth_b", a.bluetooth)
        empty = os.path.join(work, "empty-fat.img")
        with open(empty, "wb") as f:
            f.truncate(8 * MIB)
        subprocess.run(["mkfs.vfat", "-S", "4096", "-n", "MODEM", empty], check=True, capture_output=True)
        put("modem_a", empty)

        # super: metadata at the start, vendor_b's second half first, then its first half.
        super_bytes = offset["super"][1]
        meta = lp_metadata([("vendor_a", 0, 1), ("vendor_b", 1, 2)],
                           [(8 * 256, decoy_at), (half, first_at), (rest, second_at)], super_bytes)
        blob = bytearray(4096) + lp_geometry(65536, 2) * 2 + meta.ljust(65536, b"\0") * 4
        put("super", data=bytes(blob))
        with open(a.vendor, "rb") as v:
            first = v.read(half * SECTOR)
            second = v.read()
        put("super", data=first, at=first_at * SECTOR)
        put("super", data=second, at=second_at * SECTOR)
        put("super", data=b"not a file system".ljust(4096, b"\0"), at=decoy_at * SECTOR)

        # What the guest must find.
        mirror = {}
        with open(os.path.join(ROOT, "device", "oneplus-hotdog", "firmware", "firmware-files.sha256")) as f:
            for line in f:
                h, n = line.split()
                mirror[n] = h
        expected = {
            "files": {
                "qcom/sm8150/oneplus/hotdog/adsp.mbn": ["squash", mirror["adsp.mbn"]],
                "qcom/sm8150/oneplus/hotdog/modem.mbn": ["squash", mirror["modem.mbn"]],
                "qcom/sm8150/oneplus/hotdog/wlanmdsp.mbn": ["file", mirror["wlanmdsp.mbn"]],
                "qcom/sm8150/oneplus/hotdog/a640_zap.mbn": ["squash", a.zap_sha256],
                "qcom/a640_gmu.bin": ["file", mirror["a640_gmu.bin"]],
                "qcom/a630_sqe.fw": ["file", mirror["a630_sqe.fw"]],
                "ath10k/WCN3990/hw1.0/board-2.bin": ["file", mirror["board-2.bin"]],
                "ath10k/WCN3990/hw1.0/firmware-5.bin": ["file", mirror["firmware-5.bin"]],
                "qca/crbtfw21.tlv": ["file", mirror["crbtfw21.tlv"]],
                "qca/crnv21.bin": ["file", mirror["crnv21.bin"]],
            },
            "partitions": dict.fromkeys(("modem_b", "bluetooth_b", "super")),
            "slots": {"modem": "b", "bluetooth": "b", "vendor": "b"},
        }
        for n in expected["partitions"]:
            start, size = offset[n]
            h = hashlib.sha256()
            with open(a.out, "rb") as f:
                f.seek(start)
                left = size
                while left:
                    block = f.read(min(left, 8 * MIB))
                    h.update(block)
                    left -= len(block)
            expected["partitions"][n] = h.hexdigest()

        tools = os.path.join(work, "tools")
        os.makedirs(tools)
        with open(os.path.join(tools, "expected.json"), "w") as f:
            json.dump(expected, f, indent=1, sort_keys=True)
        shutil.copy(os.path.join(ROOT, "tests", "vm", "phone_firmware_check.py"), tools)
        shutil.copy(os.path.join(ROOT, "config", "rootfs", "usr", "local", "lib", "antumbra-phone-firmware"), tools)
        if a.kernel_build:
            shutil.copy(os.path.join(a.kernel_build, "fs", "erofs", "erofs.ko"), tools)
        ext4 = os.path.join(work, "tools.img")
        with open(ext4, "wb") as f:
            f.truncate(offset["antumbra-test"][1])
        subprocess.run(["mkfs.ext4", "-q", "-b", "4096", "-L", "antumbra-test", "-d", tools, ext4], check=True)
        put("antumbra-test", ext4)
        print(f"{a.out}: {total_mib} MiB; vendor_b at sectors {first_at}+{half} and {second_at}+{rest}")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main()
