#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Fail if OnePlus/OxygenOS camera software or Qualcomm camera HAL blobs are
present under the given directories (docs/camera.md explains why Antumbra
never ships them). tests/lint.sh runs it on the source tree; the VM camera
checks run it on the image's root filesystem, Waydroid's Android images
included. Python's standard library only, plus the zstd program for zstd
data on Python versions before 3.14.

Every file is checked by name: the names below, also with a .gz, .xz, .zst
or .bz2 suffix. Every regular file is also checked by content, whatever its
name: zip files (APKs, APEXes, XAPK, APKS and APKM bundles and their split
APKs, app bundles, jars), tar and cpio (newc) archives, gzip, xz, bzip2 and
zstd data, and Android disk images (ext2/3/4, EROFS, Android sparse images
of either) are read without mounting or extracting anything, and their
members are checked the same way, recursively. An Android package counts by
its package name whatever its file name: the AndroidManifest.xml of an APK,
APEX or app bundle, or a bundle's own metadata (manifest.json, info.json,
toc.pb).

A file that starts like one of those formats but cannot be read entirely is
reported as "cannot inspect", so the check fails closed: an EROFS image with
compressed files, an Android super partition image or OTA payload, an
encrypted zip member, nesting deeper than MAX_DEPTH, a compressed member or
stream that would need more than MEM_LIMIT bytes of memory, a damaged
archive or image.

usage: no-oneplus-camera.py [--xdev] [--skip DIR]... ROOT...
ROOT is a directory or a file. Prints each offending path (a member of an
archive or image as OUTER!/MEMBER); exit status 1 if there is any.
"""
import bisect
import bz2
import fnmatch
import gzip
import io
import lzma
import os
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import threading
import zipfile
import zlib

# File names, matched case-insensitively. The OnePlus Camera app and service
# and the native libraries bundled with it; Qualcomm's CamX/CHI camera HAL
# and its firmware and tuning blobs (LineageOS sm8150-common
# proprietary-files.txt names them).
NAMES = [
    "oneplus*camera*", "opcamera*.apk", "*oxygen*.apk", "*oneplus*.apk",
    "libopcamera*", "libopbaselib*", "liboppictureprocess*", "libopx.so",
    "libarcsoft*", "libmpbase.so", "libvdblurless*", "libsnpe*.so",
    "camera.qcom.so", "com.qti.chi.*", "com.qti.camx.*", "com.qti.sensormodule.*",
    "com.qti.tuned.*", "com.qti.sensor.*", "camera_icp*", "libcamx*",
    "libchromatix*", "libmmcamera*",
]
COMPRESSED_SUFFIXES = (".gz", ".xz", ".zst", ".bz2")
# Package names in an Android manifest (binary XML stores UTF-16 strings,
# app bundles protobuf; compared with the zero bytes removed) or in a
# bundle's metadata.
MANIFEST_MARKERS = [b"com.oneplus.", b"net.oneplus.", b"oxygenos"]
# A bundle's own metadata, at the top of the zip: XAPK, APKM, APKS.
BUNDLE_METADATA = ("manifest.json", "info.json", "toc.pb")
HEAD = 4352            # enough for every signature below (Android super: 4096 + 8)
MAX_DEPTH = 8          # containers inside containers
MEM_LIMIT = 256 << 20  # the most data unpacked into memory for one member or stream
META_LIMIT = 16 << 20  # the largest manifest or bundle metadata read
HEX = b"0123456789abcdefABCDEF"


class CannotInspect(Exception):
    pass


def name_matches(name):
    low = name.lower()
    names = [low] + [low[:-len(s)] for s in COMPRESSED_SUFFIXES if low.endswith(s)]
    return any(fnmatch.fnmatchcase(n, p) for n in names for p in NAMES)


def has_marker(data):
    flat = data.replace(b"\x00", b"").lower()
    return any(m in flat for m in MANIFEST_MARKERS)


def read_at(f, offset, n):
    f.seek(offset)
    return f.read(n)


def read_exact(f, offset, n):
    if n > MEM_LIMIT:
        raise CannotInspect(f"implausible size: {n} bytes at {offset}")
    data = read_at(f, offset, n)
    if len(data) != n:
        raise CannotInspect(f"truncated: {n} bytes at {offset} not readable")
    return data


# --- Formats ------------------------------------------------------------------
def ext_superblock_sane(sb):
    """Whether SB (the 1024 bytes at offset 1024) is an ext2/3/4 superblock."""
    (inodes, blocks_lo, _, _, _, first_data, log_bs, _, per_group, _,
     inodes_per_group) = struct.unpack_from("<11I", sb, 0)
    rev, = struct.unpack_from("<I", sb, 0x4C)
    isize, = struct.unpack_from("<H", sb, 0x58)
    incompat, = struct.unpack_from("<I", sb, 0x60)
    blocks = blocks_lo | (struct.unpack_from("<I", sb, 0x150)[0] << 32 if incompat & 0x80 else 0)
    if log_bs > 6 or not per_group or not inodes_per_group or rev > 1 or blocks <= first_data:
        return False
    if rev == 1 and not (128 <= isize <= 1024 << log_bs and isize & (isize - 1) == 0):
        return False
    if first_data not in (0, 1) or (first_data == 1 and log_bs != 0):
        return False
    return inodes == -(-(blocks - first_data) // per_group) * inodes_per_group


def sniff(head):
    """The container format whose signature HEAD (a file's first HEAD bytes)
    starts with, or None."""
    if head[:4] in (b"PK\x03\x04", b"PK\x05\x06"):
        return "zip"
    if head[:3] == b"\x1f\x8b\x08":
        return "gzip"
    if head[:6] == b"\xfd7zXZ\x00":
        return "xz"
    if (head[:3] == b"BZh" and len(head) >= 10 and 0x31 <= head[3] <= 0x39
            and head[4:10] in (b"\x31\x41\x59\x26\x53\x59", b"\x17\x72\x45\x38\x50\x90")):
        return "bzip2"
    if head[:4] == b"\x28\xb5\x2f\xfd":
        return "zstd"
    if head[:6] in (b"070701", b"070702") and len(head) >= 110 and all(c in HEX for c in head[6:110]):
        return "cpio"
    if head[:6] == b"\x3a\xff\x26\xed\x01\x00":
        return "sparse"
    if head[:4] == b"CrAU" and head[4:12] in (struct.pack(">Q", 1), struct.pack(">Q", 2)):
        return "payload"
    if head[257:263] in (b"ustar\x00", b"ustar "):
        return "tar"
    if head[1024:1028] == b"\xe2\xe1\xf5\xe0":
        return "erofs"
    if head[1080:1082] == b"\x53\xef" and len(head) >= 2048 and ext_superblock_sane(head[1024:2048]):
        return "ext"
    if head[4096:4100] == b"gDla" and head[4100:4104] == struct.pack("<I", 52):
        return "super"
    return None


# --- Read-only views of byte ranges -------------------------------------------
class Region(io.RawIOBase):
    """A seekable read-only file of SIZE bytes whose content pread() gives."""

    def __init__(self, size):
        super().__init__()
        self.size, self.pos = size, 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        pos = (0, self.pos, self.size)[whence] + offset
        if pos < 0:
            raise OSError("negative seek position")
        self.pos = pos
        return pos

    def readinto(self, b):
        n = max(0, min(len(b), self.size - self.pos))
        data = self.pread(self.pos, n) if n else b""
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)


def buffered(region):
    return io.BufferedReader(region, 1 << 16)


class Window(Region):
    """SIZE bytes at START of the file F."""

    def __init__(self, f, start, size):
        super().__init__(size)
        self.f, self.start = f, start

    def pread(self, offset, n):
        return read_exact(self.f, self.start + offset, n)


class Fill:
    """A 4-byte value repeated (an Android sparse image's fill chunk)."""

    def __init__(self, value):
        self.value = value


class Mapped(Region):
    """A file of SIZE bytes made of RUNS, (offset, length, source): source is
    an offset in F, None for zeros, bytes, or a Fill. Gaps read as zeros."""

    def __init__(self, f, size, runs):
        super().__init__(size)
        self.f = f
        self.runs = sorted((r for r in runs if r[1] > 0), key=lambda r: r[0])
        self.starts = [r[0] for r in self.runs]

    def pread(self, offset, n):
        if n > MEM_LIMIT:
            raise CannotInspect(f"implausible size: {n} bytes")
        out = []
        end = offset + n
        while offset < end:
            i = bisect.bisect_right(self.starts, offset) - 1
            if i >= 0 and offset < self.runs[i][0] + self.runs[i][1]:
                start, length, src = self.runs[i]
                take = min(end, start + length) - offset
                k = offset - start
                if src is None:
                    out.append(bytes(take))
                elif isinstance(src, Fill):
                    out.append((src.value * ((k % 4 + take) // 4 + 1))[k % 4:k % 4 + take])
                elif isinstance(src, bytes):
                    piece = src[k:k + take]
                    if len(piece) != take:
                        raise CannotInspect("inline data shorter than the file")
                    out.append(piece)
                else:
                    out.append(read_exact(self.f, src + k, take))
            else:   # a hole, up to the next run
                nxt = self.starts[i + 1] if i + 1 < len(self.starts) else end
                take = min(end, nxt) - offset
                out.append(bytes(take))
            offset += take
        return b"".join(out)


# --- Android sparse images -------------------------------------------------------
def sparse_image(f):
    """The image an Android sparse image (libsparse) describes."""
    _magic, _major, _minor, fhdr, chdr, blk, total_blks, chunks, _crc = struct.unpack("<IHHHHIIII", read_exact(f, 0, 28))
    if fhdr < 28 or chdr < 12 or blk == 0 or blk % 4:
        raise CannotInspect("unsupported Android sparse image header")
    runs, off, out_blk = [], fhdr, 0
    for _ in range(chunks):
        ctype, _r, nblk, total = struct.unpack("<HHII", read_exact(f, off, 12))
        data, size = off + chdr, nblk * blk
        if total < chdr:
            raise CannotInspect("bad chunk in an Android sparse image")
        if ctype == 0xCAC1:      # raw
            if total != chdr + size:
                raise CannotInspect("bad raw chunk in an Android sparse image")
            runs.append((out_blk * blk, size, data))
        elif ctype == 0xCAC2:    # fill
            value = read_exact(f, data, 4)
            runs.append((out_blk * blk, size, None if value == bytes(4) else Fill(value)))
        elif ctype == 0xCAC3:    # don't care: zeros
            pass
        elif ctype == 0xCAC4:    # CRC32 of the data so far, no blocks
            nblk = 0
        else:
            raise CannotInspect(f"unknown chunk type 0x{ctype:x} in an Android sparse image")
        out_blk += nblk
        off += total
    if out_blk > total_blks:
        raise CannotInspect("Android sparse image chunks larger than the image")
    return Mapped(f, total_blks * blk, runs)


# --- File system images -----------------------------------------------------------
class Node:
    def __init__(self, key, mode, size):
        self.key, self.mode, self.size = key, mode, size

    def is_dir(self):
        return stat.S_ISDIR(self.mode)

    def is_reg(self):
        return stat.S_ISREG(self.mode)


class Ext:
    """ext2/3/4 (fs/ext4/ext4.h), read only. Not supported, so reported:
    meta_bg, journal devices, encrypted files."""
    # FILETYPE RECOVER EXTENTS 64BIT MMP FLEX_BG EA_INODE CSUM_SEED LARGEDIR
    # INLINE_DATA ENCRYPT (only per file, refused there) CASEFOLD
    INCOMPAT_OK = 0x2 | 0x4 | 0x40 | 0x80 | 0x100 | 0x200 | 0x400 | 0x2000 | 0x4000 | 0x8000 | 0x10000 | 0x20000

    def __init__(self, f):
        self.f = f
        sb = read_exact(f, 1024, 1024)
        if not ext_superblock_sane(sb):
            raise CannotInspect("bad ext4 superblock")
        self.first_data_block, log_bs = struct.unpack_from("<II", sb, 0x14)
        self.bs = 1024 << log_bs
        self.per_group, = struct.unpack_from("<I", sb, 0x20)
        self.inodes_per_group, = struct.unpack_from("<I", sb, 0x28)
        rev, = struct.unpack_from("<I", sb, 0x4C)
        self.isize = struct.unpack_from("<H", sb, 0x58)[0] if rev else 128
        incompat, = struct.unpack_from("<I", sb, 0x60)
        if incompat & ~self.INCOMPAT_OK:
            raise CannotInspect(f"ext4 incompatible features 0x{incompat & ~self.INCOMPAT_OK:x} not supported")
        blocks = struct.unpack_from("<I", sb, 0x4)[0] | (struct.unpack_from("<I", sb, 0x150)[0] << 32 if incompat & 0x80 else 0)
        self.desc = struct.unpack_from("<H", sb, 0xFE)[0] if incompat & 0x80 else 32
        if self.desc < 32 or self.desc & (self.desc - 1):
            raise CannotInspect("bad ext4 group descriptor size")
        self.groups = -(-(blocks - self.first_data_block) // self.per_group)
        self.gdt = read_exact(f, (self.first_data_block + 1) * self.bs, self.groups * self.desc)

    def block(self, n):
        return read_exact(self.f, n * self.bs, self.bs)

    def inode(self, ino):
        g, i = divmod(ino - 1, self.inodes_per_group)
        if not 0 <= g < self.groups:
            raise CannotInspect(f"ext4 inode {ino} out of range")
        d = g * self.desc
        table, = struct.unpack_from("<I", self.gdt, d + 8)
        if self.desc >= 64:
            table |= struct.unpack_from("<I", self.gdt, d + 0x28)[0] << 32
        raw = read_exact(self.f, table * self.bs + i * self.isize, self.isize)
        mode, = struct.unpack_from("<H", raw, 0)
        size = struct.unpack_from("<I", raw, 4)[0] | (struct.unpack_from("<I", raw, 0x6C)[0] << 32)
        node = Node(ino, mode, size)
        node.raw = raw
        node.flags, = struct.unpack_from("<I", raw, 0x20)
        return node

    def inline_data(self, node):
        """i_block, and the system.data extended attribute in the inode."""
        raw, extra = node.raw[0x28:0x64], b""
        if self.isize > 128:
            start = 128 + struct.unpack_from("<H", node.raw, 0x80)[0]
            if node.raw[start:start + 4] == b"\x00\x00\x02\xea":
                base = off = start + 4
                while off + 16 <= len(node.raw) and node.raw[off:off + 4] != bytes(4):
                    nlen, nidx, voff, _vino, vsize = struct.unpack_from("<BBHII", node.raw, off)
                    if nidx == 7 and node.raw[off + 16:off + 16 + nlen] == b"data":
                        extra = node.raw[base + voff:base + voff + vsize]
                    off += (16 + nlen + 3) & ~3
        return raw, extra

    def runs(self, node):
        if node.flags & 0x800:
            raise CannotInspect("encrypted ext4 file")
        if node.flags & 0x10000000:
            raw, extra = self.inline_data(node)
            return [(0, node.size, (raw + extra)[:node.size])]
        nblocks = -(-node.size // self.bs)
        blocks = []   # (logical block, count, physical block or None for zeros)
        if node.flags & 0x80000:
            self.extents(node.raw[0x28:0x64], blocks, 0)
        else:
            self.block_map(struct.unpack_from("<15I", node.raw, 0x28), blocks, nblocks)
        runs = []
        for lblk, count, pblk in sorted(blocks, key=lambda b: b[0]):
            count = min(count, nblocks - lblk)
            if count <= 0:
                continue
            off, length, src = lblk * self.bs, count * self.bs, None if pblk is None else pblk * self.bs
            last = runs[-1] if runs else None
            if last and src is not None and last[2] is not None and last[0] + last[1] == off and last[2] + last[1] == src:
                runs[-1] = (last[0], last[1] + length, last[2])
            else:
                runs.append((off, length, src))
        return runs

    def extents(self, node, out, level):
        magic, entries, _max, depth = struct.unpack_from("<HHHH", node, 0)
        if magic != 0xF30A or level > 8 or 12 + 12 * entries > len(node):
            raise CannotInspect("bad ext4 extent tree")
        for k in range(entries):
            if depth == 0:
                lblk, length, hi, lo = struct.unpack_from("<IHHI", node, 12 + 12 * k)
                unwritten = length > 32768
                out.append((lblk, length - 32768 if unwritten else length, None if unwritten else hi << 32 | lo))
            else:
                _lblk, lo, hi = struct.unpack_from("<IIH", node, 12 + 12 * k)
                self.extents(self.block(hi << 32 | lo), out, level + 1)

    def block_map(self, ptrs, out, nblocks):
        per = self.bs // 4

        def walk(p, level, lblk):
            if lblk >= nblocks:
                return lblk
            if level == 0:
                if p:
                    out.append((lblk, 1, p))
                return lblk + 1
            if not p:
                return lblk + per ** level
            for q in struct.unpack(f"<{per}I", self.block(p)):
                lblk = walk(q, level - 1, lblk)
            return lblk

        lblk = 0
        for i, p in enumerate(ptrs):     # 12 direct, then single, double, triple indirect
            lblk = walk(p, max(0, i - 11), lblk)

    def open(self, node):
        return Mapped(self.f, node.size, self.runs(node))

    def root(self):
        return self.inode(2)

    def listdir(self, node):
        if node.flags & 0x800:
            raise CannotInspect("encrypted ext4 directory")
        if node.flags & 0x10000000:
            raw, extra = self.inline_data(node)
            bufs = [raw[4:], extra]    # i_block starts with the parent's inode number
        else:
            data = self.open(node).pread(0, node.size)
            bufs = [data[i:i + self.bs] for i in range(0, len(data), self.bs)]
        for buf in bufs:     # linear: hash tree blocks read as empty entries
            off = 0
            while off + 8 <= len(buf):
                ino, rec_len, name_len = struct.unpack_from("<IHB", buf, off)
                if rec_len in (0, 65535) and self.bs == 65536:
                    rec_len = 65536
                else:
                    rec_len = (rec_len & 65532) | ((rec_len & 3) << 16)
                if rec_len < 8 or off + rec_len > len(buf) or 8 + name_len > rec_len:
                    if not any(buf[off:]):   # the unused end of an inline directory
                        break
                    raise CannotInspect("bad ext4 directory entry")
                name = buf[off + 8:off + 8 + name_len]
                if ino and name not in (b".", b".."):
                    yield name, self.inode(ino)
                off += rec_len


class Erofs:
    """EROFS (fs/erofs/erofs_fs.h), read only. Compressed files, extra
    devices and the 48-bit and metabox layouts are not supported, so they
    are reported."""
    # ZERO_PADDING BIG_PCLUSTER CHUNKED_FILE DEVICE_TABLE ZTAILPACKING
    # FRAGMENTS XATTR_PREFIXES
    INCOMPAT_OK = 0x7F

    def __init__(self, f):
        self.f = f
        sb = read_exact(f, 1024, 128)
        self.bits, = struct.unpack_from("<B", sb, 12)
        self.root_nid, = struct.unpack_from("<H", sb, 14)
        meta, = struct.unpack_from("<I", sb, 40)
        incompat, = struct.unpack_from("<I", sb, 80)
        extra_devices, = struct.unpack_from("<H", sb, 86)
        dirblkbits, = struct.unpack_from("<B", sb, 90)
        if not 9 <= self.bits <= 16 or dirblkbits:
            raise CannotInspect("unsupported EROFS block size")
        if incompat & ~self.INCOMPAT_OK:
            raise CannotInspect(f"EROFS features 0x{incompat & ~self.INCOMPAT_OK:x} not supported")
        if extra_devices:
            raise CannotInspect("EROFS image with extra devices")
        self.bs = 1 << self.bits
        self.meta = meta << self.bits

    def inode(self, nid):
        loc = self.meta + nid * 32
        raw = read_at(self.f, loc, 64)
        if len(raw) < 32:
            raise CannotInspect(f"EROFS inode {nid} out of range")
        fmt, xcount, mode = struct.unpack_from("<HHH", raw, 0)
        layout = fmt >> 1 & 7
        if fmt & ~0xF or layout > 4:
            raise CannotInspect(f"unsupported EROFS inode format 0x{fmt:x}")
        if fmt & 1:     # extended, 64 bytes
            if len(raw) < 64:
                raise CannotInspect(f"EROFS inode {nid} truncated")
            isize, (size,) = 64, struct.unpack_from("<Q", raw, 8)
        else:           # compact, 32 bytes
            isize, (size,) = 32, struct.unpack_from("<I", raw, 8)
        node = Node(nid, mode, size)
        node.layout = layout
        node.iu, = struct.unpack_from("<I", raw, 16)
        node.tail = loc + isize + (12 + 4 * (xcount - 1) if xcount else 0)
        return node

    def runs(self, node):
        size, bs = node.size, self.bs
        if node.layout in (1, 3):
            raise CannotInspect("compressed EROFS file")
        if node.layout in (0, 2) and size and node.iu == 0xFFFFFFFF and (node.layout == 0 or size > bs):
            raise CannotInspect("EROFS file without a block address")
        if node.layout == 0:     # flat
            return [(0, size, node.iu << self.bits)] if size else []
        if node.layout == 2:     # flat, the last block inline after the inode
            if not size:
                return []
            last = (size - 1) // bs * bs
            return ([(0, last, node.iu << self.bits)] if last else []) + [(last, size - last, node.tail)]
        cf = node.iu & 0xFFFF    # chunk-based
        if cf & ~0x3F:
            raise CannotInspect(f"unsupported EROFS chunk format 0x{cf:x}")
        chunk = bs << (cf & 0x1F)
        unit = 8 if cf & 0x20 else 4
        table = -(-node.tail // unit) * unit
        n = -(-size // chunk)
        entries = read_exact(self.f, table, n * unit)
        runs = []
        for k in range(n):
            blk, = struct.unpack_from("<I", entries, unit * k + unit - 4)
            if blk != 0xFFFFFFFF:     # else a hole
                runs.append((k * chunk, min(chunk, size - k * chunk), blk << self.bits))
        return runs

    def open(self, node):
        return Mapped(self.f, node.size, self.runs(node))

    def root(self):
        return self.inode(self.root_nid)

    def listdir(self, node):
        data = self.open(node).pread(0, node.size)
        for start in range(0, len(data), self.bs):
            blk = data[start:start + self.bs]
            if len(blk) < 12:
                raise CannotInspect("bad EROFS directory block")
            first, = struct.unpack_from("<H", blk, 8)
            if first < 12 or first % 12 or first > len(blk):
                raise CannotInspect("bad EROFS directory block")
            count = first // 12
            for k in range(count):
                nid, nameoff = struct.unpack_from("<QH", blk, 12 * k)
                if k + 1 < count:
                    end, = struct.unpack_from("<H", blk, 12 * (k + 1) + 8)
                else:
                    end = blk.find(b"\x00", nameoff)
                    end = len(blk) if end < 0 else end
                if not first <= nameoff < end <= len(blk):
                    raise CannotInspect("bad EROFS directory entry")
                name = blk[nameoff:end]
                if name not in (b".", b".."):
                    yield name, self.inode(nid)


def scan_fs(fs, label, depth, out):
    """Every file of the file system image FS: names, then contents."""
    unreadable = {}
    stack, seen = [("", fs.root())], set()
    while stack:
        path, d = stack.pop()
        if d.key in seen:
            continue
        seen.add(d.key)
        for raw_name, child in fs.listdir(d):
            name = raw_name.decode("utf-8", "replace")
            sub = f"{label}!{path}/{name}"
            if child.is_dir():
                stack.append((f"{path}/{name}", child))
            elif name_matches(name):
                out.append(sub)
            elif child.is_reg() and child.size >= 4:
                try:
                    region = fs.open(child)
                    kind = sniff(region.pread(0, min(HEAD, child.size)))
                except CannotInspect as e:
                    unreadable.setdefault(str(e), []).append(sub)
                    continue
                if kind is not None:
                    inspect_as(buffered(region), sub, depth + 1, out, kind)
    for reason, paths in sorted(unreadable.items()):
        out.append(f"{label}: cannot inspect {len(paths)} file(s) ({reason}), e.g. {paths[0]}")


# --- Archives and compressed data -------------------------------------------------
def zip_data_offset(f, zi):
    h = read_exact(f, zi.header_offset, 30)
    if h[:4] != b"PK\x03\x04":
        raise CannotInspect(f"bad local header for {zi.filename}")
    n, e = struct.unpack_from("<HH", h, 26)
    return zi.header_offset + 30 + n + e


def scan_zip(f, label, depth, out):
    with zipfile.ZipFile(f) as z:
        for zi in z.infolist():
            if zi.is_dir():
                continue
            sub = f"{label}!/{zi.filename}"
            base = zi.filename.rsplit("/", 1)[-1]
            if name_matches(base):
                out.append(sub)
                continue
            if zi.flag_bits & 1:
                out.append(f"{sub}: cannot inspect (encrypted zip member)")
                continue
            # The package's own name: an APK's, APEX's or app bundle's
            # manifest, an XAPK/APKM/APKS bundle's metadata.
            if ((base == "AndroidManifest.xml" or zi.filename in BUNDLE_METADATA)
                    and zi.file_size <= META_LIMIT and has_marker(z.read(zi))):
                out.append(label)
            if zi.file_size < 4:
                continue
            try:
                with z.open(zi) as m:
                    head = m.read(HEAD)
            except ERRORS as e:
                out.append(f"{sub}: cannot inspect ({type(e).__name__}: {e})")
                continue
            kind = sniff(head)
            if kind is None:
                continue
            if zi.compress_type == zipfile.ZIP_STORED:
                member = buffered(Window(f, zip_data_offset(f, zi), zi.file_size))
            elif zi.file_size <= MEM_LIMIT:
                member = io.BytesIO(z.read(zi))
            else:
                out.append(f"{sub}: cannot inspect (compressed member larger than {MEM_LIMIT >> 20} MiB)")
                continue
            inspect_as(member, sub, depth + 1, out, kind)


def scan_tar(f, label, depth, out, stream=False):
    with tarfile.open(fileobj=f, mode="r|" if stream else "r:") as t:
        for m in t:
            sub = f"{label}!/{m.name}"
            if m.isdir():
                continue
            if name_matches(m.name.rsplit("/", 1)[-1]):
                out.append(sub)
                continue
            if not m.isfile() or m.size < 4:
                continue
            ef = t.extractfile(m)
            head = ef.read(HEAD)
            kind = sniff(head)
            if kind is None:
                continue
            if not stream and not m.issparse():
                member = buffered(Window(f, m.offset_data, m.size))
            elif m.size <= MEM_LIMIT:
                member = io.BytesIO(head + ef.read())
            else:
                out.append(f"{sub}: cannot inspect (member larger than {MEM_LIMIT >> 20} MiB in a compressed tar)")
                continue
            inspect_as(member, sub, depth + 1, out, kind)


def scan_cpio(f, label, depth, out, stream=False):
    """A newc cpio archive (an initramfs), then what follows its trailer: an
    initramfs can be an uncompressed archive followed by a compressed one."""
    pos = 0

    def read(n):
        nonlocal pos
        data = f.read(n) if stream else read_at(f, pos, n)
        if len(data) != n:
            raise CannotInspect("truncated cpio archive")
        pos += n
        return data

    def skip(n):
        nonlocal pos
        while stream and n > 0:
            n -= len(read(min(n, 1 << 20)))
        pos += max(n, 0)

    while True:
        hdr = read(110)
        if hdr[:6] not in (b"070701", b"070702"):
            raise CannotInspect("bad cpio header")
        fields = [int(hdr[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
        mode, size, namesize = fields[1], fields[6], fields[11]
        name = read(namesize).rstrip(b"\x00").decode("utf-8", "replace")
        skip(-(110 + namesize) % 4)
        if name == "TRAILER!!!":
            break
        sub, start = f"{label}!/{name}", pos
        if name_matches(name.rsplit("/", 1)[-1]):
            out.append(sub)
        elif stat.S_ISREG(mode) and size >= 4:
            head = read(min(HEAD, size))
            kind = sniff(head)
            if kind is None:
                pass
            elif not stream:
                inspect_as(buffered(Window(f, start, size)), sub, depth + 1, out, kind)
            elif size <= MEM_LIMIT:
                inspect_as(io.BytesIO(head + read(size - len(head))), sub, depth + 1, out, kind)
            else:
                out.append(f"{sub}: cannot inspect (member larger than {MEM_LIMIT >> 20} MiB in a compressed cpio archive)")
        skip(start + size - pos)
        skip(-size % 4)
    if stream:
        rest = f.read(MEM_LIMIT + 1).lstrip(b"\x00")
        if len(rest) > MEM_LIMIT:
            raise CannotInspect(f"more than {MEM_LIMIT >> 20} MiB after a compressed cpio archive")
        kind = sniff(rest[:HEAD])
        if kind is not None:
            inspect_as(io.BytesIO(rest), label, depth + 1, out, kind)
        return
    end = f.seek(0, 2)
    while pos < end:
        chunk = read_at(f, pos, 1 << 16)
        stripped = chunk.lstrip(b"\x00")
        pos += len(chunk) - len(stripped)
        if stripped:
            rest = buffered(Window(f, pos, end - pos))
            kind = sniff(read_at(rest, 0, HEAD))
            if kind is not None:
                inspect_as(rest, label, depth + 1, out, kind)
            return


class ZstdPipe(io.RawIOBase):
    """zstd -d, fed from F by a thread (Python before 3.14 has no zstd)."""

    def __init__(self, f):
        super().__init__()
        exe = shutil.which("zstd")
        if not exe:
            raise CannotInspect("zstd data, and no zstd program to read it")
        self.p = subprocess.Popen([exe, "-dcq"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL)
        self.err, self.done = None, False
        self.t = threading.Thread(target=self.feed, args=(f,), daemon=True)
        self.t.start()

    def feed(self, f):
        try:
            while True:
                b = f.read(1 << 16)
                if not b:
                    break
                self.p.stdin.write(b)
        except (BrokenPipeError, ValueError):
            pass
        except Exception as e:  # noqa: BLE001 - reported by readinto
            self.err = e
        finally:
            try:
                self.p.stdin.close()
            except OSError:
                pass

    def readable(self):
        return True

    def readinto(self, b):
        n = self.p.stdout.readinto(b)
        if not n and not self.done:
            self.done = True
            self.t.join()
            if self.err is not None or self.p.wait() != 0:
                raise CannotInspect(f"zstd could not decompress it ({self.err or 'exit status %d' % self.p.returncode})")
        return n

    def close(self):
        if not self.closed:
            if self.p.poll() is None:
                self.p.kill()
            self.p.stdout.close()
            self.t.join()
            self.p.wait()
        super().close()


def decompressed(kind, f):
    f.seek(0)
    if kind == "gzip":
        return gzip.GzipFile(fileobj=f, mode="rb")
    if kind == "xz":
        return lzma.LZMAFile(f)
    if kind == "bzip2":
        return bz2.BZ2File(f)
    try:
        from compression import zstd  # Python 3.14
        return zstd.ZstdFile(f)
    except ImportError:
        return io.BufferedReader(ZstdPipe(f))


def scan_compressed(f, label, depth, out, kind):
    with decompressed(kind, f) as d:
        head = d.read(HEAD)
        inner = sniff(head)
        data = None
        if inner not in (None, "tar", "cpio"):
            data = head + d.read(MEM_LIMIT + 1 - len(head))
            if len(data) > MEM_LIMIT:
                raise CannotInspect(f"{inner} data larger than {MEM_LIMIT >> 20} MiB compressed with {kind}")
    if inner in ("tar", "cpio"):
        with decompressed(kind, f) as d:
            (scan_tar if inner == "tar" else scan_cpio)(d, label, depth + 1, out, stream=True)
    elif data is not None:
        inspect_as(io.BytesIO(data), label, depth + 1, out, inner)


def scan_image(f, label, depth, out, kind):
    if kind == "sparse":
        img = buffered(sparse_image(f))
        inner = sniff(read_at(img, 0, HEAD))
        if inner not in ("ext", "erofs", "super"):
            raise CannotInspect("Android sparse image of an unknown file system")
        inspect_as(img, label, depth + 1, out, inner)
    elif kind in ("super", "payload"):
        raise CannotInspect("Android super partition image" if kind == "super" else "Android OTA payload")
    else:
        scan_fs(Ext(f) if kind == "ext" else Erofs(f), label, depth, out)


ERRORS = (CannotInspect, OSError, EOFError, ValueError, struct.error, zipfile.BadZipFile,
          zipfile.LargeZipFile, tarfile.TarError, lzma.LZMAError, zlib.error,
          NotImplementedError, RuntimeError, KeyError, IndexError, RecursionError, MemoryError, OverflowError)


def inspect_as(f, label, depth, out, kind):
    """Check the content of F, a seekable file of format KIND."""
    if depth > MAX_DEPTH:
        out.append(f"{label}: cannot inspect ({kind} nested more than {MAX_DEPTH} levels deep)")
        return
    try:
        f.seek(0)
        if kind == "zip":
            scan_zip(f, label, depth, out)
        elif kind == "tar":
            scan_tar(f, label, depth, out)
        elif kind == "cpio":
            scan_cpio(f, label, depth, out)
        elif kind in ("gzip", "xz", "bzip2", "zstd"):
            scan_compressed(f, label, depth, out, kind)
        else:
            scan_image(f, label, depth, out, kind)
    except ERRORS as e:
        reason = str(e) if isinstance(e, CannotInspect) else f"{kind}: {type(e).__name__}: {e}"
        out.append(f"{label}: cannot inspect ({reason})")


def check_file(path, name, out):
    if name_matches(name):
        out.append(path)
        return
    try:
        st = os.lstat(path)
    except OSError:
        return
    if not stat.S_ISREG(st.st_mode) or st.st_size < 4:
        return
    try:
        with open(path, "rb") as f:
            kind = sniff(f.read(HEAD))
            if kind is not None:
                inspect_as(f, path, 0, out, kind)
    except OSError as e:
        out.append(f"{path}: cannot inspect ({e.strerror})")


def scan(root, xdev, skip):
    out = []
    if not os.path.isdir(root):
        check_file(root, os.path.basename(root), out)
        return list(dict.fromkeys(out))
    root_dev = os.lstat(root).st_dev
    for dirpath, dirnames, filenames in os.walk(root):
        keep = []
        for d in dirnames:
            p = os.path.normpath(os.path.join(dirpath, d))
            if p in skip or d == ".git":
                continue
            if xdev:
                try:
                    if os.lstat(p).st_dev != root_dev:
                        continue
                except OSError:
                    continue
            keep.append(d)
        dirnames[:] = keep
        for f in filenames:
            check_file(os.path.join(dirpath, f), f, out)
    return list(dict.fromkeys(out))


def main(argv):
    xdev, skip, roots = False, set(), []
    args = iter(argv)
    for a in args:
        if a == "--xdev":
            xdev = True
        elif a == "--skip":
            skip.add(os.path.normpath(next(args)))
        else:
            roots.append(a)
    if not roots:
        print(__doc__, file=sys.stderr)
        return 2
    hits = []
    for r in roots:
        hits += scan(os.path.normpath(r), xdev, {os.path.normpath(s) for s in skip})
    for h in hits:
        print(h)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
