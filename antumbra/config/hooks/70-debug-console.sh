#!/bin/sh
# Debug console for the QEMU profile: a root shell on the virtio console
# hvc0, and the journal forwarded to the serial console so the test harness
# can read it. Installed only when the build is a debug build of the
# qemu-virt profile, and the unit additionally requires antumbra.debug=1 on
# the kernel command line. Release builds (release.sh refuses debug builds)
# and phone builds never contain it.
set -eu
if [ -z "${ANTUMBRA_DEBUG:-}" ] || [ "${ANTUMBRA_DEVICE:-}" != "qemu-virt" ]; then
    echo "no debug console (not a qemu-virt debug build)"
    exit 0
fi
mkdir -p /etc/systemd/system/serial-getty@hvc0.service.d
cat > /etc/systemd/system/serial-getty@hvc0.service.d/antumbra-debug.conf <<'UNIT'
# Antumbra qemu-virt debug build: root shell on the virtio console.
[Unit]
ConditionKernelCommandLine=antumbra.debug=1
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud 115200,57600,38400,9600 %I $TERM
UNIT
systemctl enable serial-getty@hvc0.service
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/zz-antumbra-debug.conf <<'CONF'
# Antumbra qemu-virt debug build: let the harness read the journal on ttyAMA0.
[Journal]
ForwardToConsole=yes
MaxLevelConsole=info
CONF
echo "debug console enabled on hvc0 (active only with antumbra.debug=1)"
