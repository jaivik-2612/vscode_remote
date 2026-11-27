#!/bin/sh
# Tails' mmap_aslr.conf carries x86 values; derive the arm64 maxima from the
# kernel configuration recorded by build/kernel.sh.
set -eu
SRC=/run/antumbra-build/kernel/mmap-rnd-bits
if [ -s "${SRC}" ]; then
    { echo "# Generated from the kernel configuration (ARCH_MMAP_RND_BITS_MAX)."; cat "${SRC}"; } > /etc/sysctl.d/mmap_aslr.conf
else
    echo "warning: no mmap-rnd-bits from the kernel build; ASLR sysctl not written" >&2
fi
