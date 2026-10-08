#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""In-guest check for the VM's phone-firmware test (antumbra_vm.py
--phone-firmware; disk from make-phone-firmware-disk.py): reads what
antumbra-phone-firmware left behind the way the kernel would, and prints one
"PASS|FAIL name: detail" line per check.

usage: phone_firmware_check.py EXPECTED.json
"""
import hashlib
import json
import os
import struct
import sys

BASE = "/run/antumbra/phone-firmware"
LIB = os.path.join(BASE, "lib")
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}", flush=True)


def kernel_view(path):
    """The image as the kernel's MDT loader assembles it from the requested
    name: the file itself when it holds every segment, else each segment
    with data from <name minus its last three characters>bNN, as
    drivers/soc/qcom/mdt_loader.c does; written out like pil-squasher."""
    with open(path, "rb") as f:
        mdt = f.read()
    if mdt[:4] != b"\x7fELF":
        raise ValueError("not ELF")
    is64 = mdt[4] == 2
    if is64:
        phoff = struct.unpack_from("<Q", mdt, 32)[0]
        phentsize, phnum = struct.unpack_from("<HH", mdt, 54)
    else:
        phoff = struct.unpack_from("<I", mdt, 28)[0]
        phentsize, phnum = struct.unpack_from("<HH", mdt, 42)
    ph = []
    for i in range(phnum):
        o = phoff + i * phentsize
        if is64:
            _t, flags, off, _v, _p, filesz = struct.unpack_from("<IIQQQQ", mdt, o)
        else:
            _t, off, _v, _p, filesz, _m, flags = struct.unpack_from("<IIIIIII", mdt, o)
        ph.append((i, flags, off, filesz))
    if all(off + filesz <= len(mdt) for _i, _f, off, filesz in ph if filesz):
        return mdt
    end = max([off + filesz for _i, _f, off, filesz in ph if filesz] + [phoff + phentsize * phnum])
    buf = bytearray(end)
    buf[:phoff + phentsize * phnum] = mdt[:phoff + phentsize * phnum]
    hashoff = ph[0][3]
    for i, flags, off, filesz in ph:
        if not filesz:
            continue
        seg = None
        if (flags >> 24) & 7 == 2 and len(mdt) >= hashoff + filesz:
            seg = mdt[hashoff:hashoff + filesz]
            hashoff += filesz
        if seg is None:
            with open(path[:-3] + "b%02d" % i, "rb") as f:
                seg = f.read()
            if len(seg) != filesz:
                raise ValueError(f"segment {i}: {len(seg)} != {filesz} bytes")
        buf[off:off + filesz] = seg
    return bytes(buf)


def main(expected_path):
    with open(expected_path) as f:
        expected = json.load(f)
    try:
        with open(os.path.join(BASE, "status.json")) as f:
            status = json.load(f)
    except (OSError, ValueError) as e:
        check("status", False, str(e))
        return 1
    check("status complete", status.get("complete") is True, json.dumps(status, sort_keys=True))
    for kind, slot in expected["slots"].items():
        got = (status.get(kind) or {}).get("slot")
        check(f"{kind} from slot {slot}", got == slot, f"got {got}")
    with open("/sys/module/firmware_class/parameters/path") as f:
        param = f.read()
    check("firmware_class.path", param == LIB + "\n", repr(param))  # sysfs adds the newline
    check("firmware tree is root-only", (os.stat(LIB).st_mode & 0o777) == 0o700, oct(os.stat(LIB).st_mode & 0o777))
    check("status readable by all", (os.stat(os.path.join(BASE, "status.json")).st_mode & 0o777) == 0o644)

    for name, (how, want) in sorted(expected["files"].items()):
        path = os.path.join(LIB, name)
        try:
            data = kernel_view(path) if how == "squash" else open(path, "rb").read()
            got = hashlib.sha256(data).hexdigest()
            check(name, got == want, f"{got[:16]} (want {want[:16]})")
        except (OSError, ValueError) as e:
            check(name, False, str(e))

    with open("/proc/self/mounts") as f:
        mounts = {line.split()[1]: line.split()[3].split(",") for line in f}
    for kind in ("modem", "bluetooth"):
        opts = mounts.get(os.path.join(BASE, "mnt", kind))
        check(f"{kind} stays mounted read-only", bool(opts) and "ro" in opts, ",".join(opts or []))
    check("vendor unmounted again", os.path.join(BASE, "mnt", "vendor") not in mounts)
    check("vendor mapping removed", not os.path.exists("/dev/mapper/antumbra-phone-vendor"))

    for name, want in sorted(expected["partitions"].items()):
        dev = os.path.realpath(f"/dev/disk/by-partlabel/{name}")
        h = hashlib.sha256()
        with open(dev, "rb") as f:
            while True:
                block = f.read(8 << 20)
                if not block:
                    break
                h.update(block)
        check(f"{name} unchanged", h.hexdigest() == want, dev)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
