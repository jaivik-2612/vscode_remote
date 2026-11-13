#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# A virtual camera for the QEMU profile, so the camera path (libcamera,
# PipeWire, the camera portal, Snapshot) can be tested without the phone
# (docs/vm-testing.md, tests/vm-smoke.sh --camera). Installed only in debug
# builds of the qemu-virt profile, like the debug console (hook 70) and the
# test tools of config/packages/vm-debug.list; phone builds never contain
# it, and the phone's kernel does not even build the driver
# (device/qemu-virt/kernel/virt.config adds it). vimc is the kernel's
# virtual media-controller camera, which libcamera drives with its vimc
# pipeline handler and IPA module.
set -eu
if [ -z "${ANTUMBRA_DEBUG:-}" ] || [ "${ANTUMBRA_DEVICE:-}" != "qemu-virt" ]; then
    echo "no virtual camera (not a qemu-virt debug build)"
    exit 0
fi
if [ -n "${ANTUMBRA_MINIMAL:-}" ]; then
    echo "minimal build: no virtual camera"
    exit 0
fi
mkdir -p /etc/modules-load.d /etc/wireplumber/wireplumber.conf.d
cat > /etc/modules-load.d/antumbra-vm-camera.conf <<'CONF'
# Antumbra qemu-virt debug build: the virtual camera (config/hooks/72-vm-camera.sh)
vimc
CONF
# The VM's stand-in for 90-antumbra-camera.conf: vimc's raw V4L2 nodes are
# hidden from WirePlumber by their card name ("vimc"), through the same
# udev-provided key (device.product.name, from ID_V4L_PRODUCT) the phone's
# rule relies on for CAMSS, so the VM checks show whether that key is
# present when WirePlumber applies the rules.
cat > /etc/wireplumber/wireplumber.conf.d/91-antumbra-camera-vm.conf <<'CONF'
# Antumbra qemu-virt debug build only (config/hooks/72-vm-camera.sh): hide
# vimc's raw V4L2 nodes, as 90-antumbra-camera.conf hides CAMSS's on the
# phone. Applications get the vimc camera through libcamera.
monitor.v4l2.rules = [
  {
    matches = [
      {
        device.product.name = "vimc"
      }
    ]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
CONF
echo "virtual camera: vimc loaded at boot, its V4L2 nodes hidden from WirePlumber"
