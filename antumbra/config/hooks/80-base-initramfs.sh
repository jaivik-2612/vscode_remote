#!/bin/sh
# Generate the initramfs and prove it carries no network driver: nothing in
# the initramfs may bring up a network interface before the firewall and
# the MAC spoofer are in place (Tails patches live-boot for the same reason;
# here etc/initramfs-tools/hooks/antumbra filters the module list instead).
set -eu
KERNEL_RELEASE="$(cat /etc/antumbra/kernel-release)"
update-initramfs -c -k "${KERNEL_RELEASE}"
INITRD="/boot/initrd.img-${KERNEL_RELEASE}"
ls -la "${INITRD}"
LISTING="$(lsinitramfs "${INITRD}")"
# Every module in the initramfs must come from an allowed subtree, except
# the four initramfs-tools adds for the built-in msm DRM driver after all
# hooks ran; those must be unloadable (etc/initramfs-tools/hooks/antumbra).
EXCEPTIONS='net/qrtr/qrtr drivers/soc/qcom/pmic_glink drivers/soc/qcom/pmic_glink_altmode drivers/usb/typec/mux/gpio-sbu-mux'
bad="$(printf '%s\n' "${LISTING}" | grep -E '\.ko(\.(zst|xz|gz))?$' \
    | grep -vE '/kernel/(fs/|drivers/md/|drivers/block/|block/|lib/|crypto/|arch/)' \
    | while IFS= read -r mod; do
        rel="${mod#*/kernel/}"; rel="${rel%%.ko*}"
        case " ${EXCEPTIONS} " in *" ${rel} "*) continue ;; esac
        printf '%s\n' "${mod}"
      done)"
if [ -n "${bad}" ]; then
    echo "80-base-initramfs: unexpected modules in the initramfs:" >&2
    echo "${bad}" >&2
    exit 1
fi
tmp="$(mktemp -d)"
unmkinitramfs "${INITRD}" "${tmp}"
for exc in ${EXCEPTIONS}; do
    name="$(basename "${exc}" | tr - _)"
    grep -qx "install ${name} /bin/false" "${tmp}/etc/modprobe.d/antumbra-initramfs.conf" \
        || { echo "80-base-initramfs: ${name} is not blocked inside the initramfs" >&2; rm -rf "${tmp}"; exit 1; }
done
rm -rf "${tmp}"
for must in etc/antumbra/live-fs-uuid etc/modprobe.d/all-net-blocklist.conf \
            scripts/live-premount/05-antumbra-loop usr/sbin/losetup usr/sbin/veritysetup; do
    printf '%s\n' "${LISTING}" | grep -qx "${must}" || { echo "80-base-initramfs: ${must} missing from the initramfs" >&2; exit 1; }
done
echo "80-base-initramfs: initramfs verified (modules: $(printf '%s\n' "${LISTING}" | grep -cE '\.ko(\.(zst|xz|gz))?$'))"
