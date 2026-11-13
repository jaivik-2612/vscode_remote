#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Print the partitions of a qemu-virt disk image, read-only: the outer GPT
(4096- or 512-byte sectors) and the nested GPT inside its 'userdata'
partition (ANTUMBRA_LIVE, ANTUMBRA_DATA), as (name, byte offset, byte size).

usage: gpt.py build/out/qemu-virt/vm-disk.img
"""
import struct, sys
def parts(f, base, ss):
    f.seek(base + ss)
    h = f.read(92)
    assert h[:8] == b'EFI PART', (base, ss, h[:8])
    lba_ent, n, esz = struct.unpack_from('<QII', h, 72)
    f.seek(base + lba_ent*ss)
    out = []
    for i in range(n):
        e = f.read(esz)
        if e[:16] == b'\0'*16: continue
        first, last = struct.unpack_from('<QQ', e, 32)
        name = e[56:128].decode('utf-16le').rstrip('\0')
        out.append((name, base + first*ss, (last-first+1)*ss))
    return out
p = sys.argv[1]
with open(p, 'rb') as f:
    for ss in (4096, 512):
        try:
            outer = parts(f, 0, ss); break
        except AssertionError: pass
    print('outer ss', ss, outer)
    for name, off, size in outer:
        if name == 'userdata':
            inner = parts(f, off, 4096)
            print('inner', inner)
