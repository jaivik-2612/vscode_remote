#!/bin/sh
# Install the Antumbra kernel modules and generate the initramfs (the kernel
# Image itself goes into the boot image, not the root filesystem).
set -eu
: "${KERNEL_RELEASE:?}"
SRC=/run/antumbra-build/kernel
tar -C / --zstd -xf "${SRC}/modules.tar.zst"
depmod -a "${KERNEL_RELEASE}"
install -m 0644 "${SRC}/config" "/boot/config-${KERNEL_RELEASE}"
mkdir -p /etc/antumbra
install -m 0644 "${SRC}/live-fs-uuid" /etc/antumbra/live-fs-uuid
printf '%s\n' "${KERNEL_RELEASE}" > /etc/antumbra/kernel-release
update-initramfs -c -k "${KERNEL_RELEASE}"
ls -la "/boot/initrd.img-${KERNEL_RELEASE}"
