#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Static validation of everything in the repository that can be checked on
# the build host without the phone.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
fail=0
step() { printf '\n== %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 2; }; }
need shellcheck; need python3; need nft; need tor

step "shell scripts (shellcheck)"
mapfile -t SHELLS < <(grep -rlE '^#!/(usr/)?bin/(ba)?sh' build config/hooks config/rootfs config/rootfs-android tests --exclude-dir=cache --exclude-dir=out --exclude-dir=work --exclude-dir=__pycache__ 2>/dev/null | sort)
# SC3037/SC3043/SC2094: vendored Tails scripts use echo -n and local (fine under dash)
shellcheck -x -e SC1091,SC3037,SC3043,SC2094 "${SHELLS[@]}" || fail=1
echo "${#SHELLS[@]} scripts checked"

step "python (byte-compile)"
mapfile -t PYS < <(grep -rlE '^#!/usr/bin/python3' config/rootfs config/rootfs-android tests 2>/dev/null; find config/rootfs config/rootfs-android tests -name '*.py' 2>/dev/null)
python3 -m py_compile "${PYS[@]}" || fail=1
find config tests -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
echo "${#PYS[@]} python files compiled"

step "pop-up motor sleep flags (userspace model)"
python3 tests/kernel/popup_gate_model.py || fail=1

step "nftables ruleset (nft -c)"
# The ruleset names system users that only exist in the image; map them to
# numeric ids for the host-side syntax check. nft -c still builds its cache
# over netlink, which needs CAP_NET_ADMIN: as root directly, otherwise
# through passwordless sudo (CI runners) or in a user and network namespace
# of its own.
TMPNFT="$(mktemp)"
sed -e 's/"debian-tor"/9001/g; s/"htp"/1101/g; s/"clearnet"/1102/g; s/"_apt"/9002/g; s/"proxy"/13/g; s/"nobody"/65534/g; s/"root"/0/g' \
    config/rootfs/etc/nftables.conf > "${TMPNFT}"
if [ "$(id -u)" -eq 0 ]; then NFT=(nft)
elif sudo -n true 2>/dev/null; then NFT=(sudo -n nft)
elif unshare -rn true 2>/dev/null; then NFT=(unshare -rn nft)
else NFT=(); fi
if [ "${#NFT[@]}" -eq 0 ]; then
    echo "nft -c needs CAP_NET_ADMIN: run as root, with passwordless sudo, or where unprivileged user namespaces work"; fail=1
elif "${NFT[@]}" -c -f "${TMPNFT}"; then echo "nftables.conf: syntax OK"; else fail=1; fi
rm -f "${TMPNFT}"

step "Android's network (namespace lab: the firewall, the start-host hook, the VM's probes)"
python3 tests/android-net-lab.py || fail=1

step "tor configuration (tor --verify-config)"
TMPTOR="$(mktemp -d)"
# User only as root: tor switches to it even for --verify-config, and an
# ordinary user cannot (setgroups fails: "Problem with User value").
# tor logs to stdout, so both streams go to the error file.
{ printf 'DataDirectory %s\n' "${TMPTOR}"; [ "$(id -u)" -ne 0 ] || printf 'User %s\n' "$(id -un)"
  grep -v '^User ' config/rootfs/etc/tor/torrc; } > "${TMPTOR}/torrc"
if tor --verify-config -f "${TMPTOR}/torrc" --hush >"${TMPTOR}/err" 2>&1; then echo "torrc: valid"; else cat "${TMPTOR}/err"; fail=1; fi
# Images with Android apps: the same plus the listeners hook 56 appends.
cat config/rootfs-android/usr/share/antumbra/android/torrc >> "${TMPTOR}/torrc"
if tor --verify-config -f "${TMPTOR}/torrc" --hush >"${TMPTOR}/err" 2>&1; then echo "torrc with Android: valid"; else cat "${TMPTOR}/err"; fail=1; fi
rm -rf "${TMPTOR}"

step "systemd units (systemd-analyze verify)"
if command -v systemd-analyze >/dev/null 2>&1; then
    # Units reference binaries that only exist in the image; only hard
    # syntax errors are fatal here.
    out="$(systemd-analyze verify --root=config/rootfs config/rootfs/usr/lib/systemd/system/*.service config/rootfs/usr/lib/systemd/system/*.timer config/rootfs/usr/lib/systemd/system/*.path config/rootfs/usr/lib/systemd/system/*.mount 2>&1 || true)"
    # Android apps: system units, and the user units in the user scope.
    XDGTMP="$(mktemp -d)"
    out="${out}
$(systemd-analyze verify --root=config/rootfs-android config/rootfs-android/usr/lib/systemd/system/*.service 2>&1 || true)
$(XDG_RUNTIME_DIR="${XDGTMP}" systemd-analyze --user verify config/rootfs-android/usr/lib/systemd/user/*.service \
        config/rootfs-android/usr/lib/systemd/user/*.path 2>&1 || true)"
    rm -rf "${XDGTMP}"
    echo "${out}" | grep -v -E 'not found|not executable|Failed to create|Failed to prepare|Cannot find unit|Unit .* has no' | grep -E 'Unknown|Failed to parse|Invalid|syntax' && fail=1 || echo "units: no syntax errors"
fi

step "kernel fragment and lock file sanity"
grep -qE '^CONFIG_NFT_REDIR=m' device/oneplus-hotdog/kernel/antumbra.config || { echo "fragment lost NFT_REDIR"; fail=1; }
grep -qE '^KERNEL_GIT_COMMIT=[0-9a-f]{40}$' device/oneplus-hotdog/sources.lock || { echo "bad KERNEL_GIT_COMMIT"; fail=1; }
[ "$(wc -l < device/oneplus-hotdog/kernel/patches.list)" -eq 27 ] || { echo "patch list changed size"; fail=1; }
CMDLEN="$(tr -d '\n' < device/oneplus-hotdog/cmdline.txt | wc -c)"
[ "${CMDLEN}" -le 380 ] || { echo "base cmdline ${CMDLEN} bytes leaves no room for the verity hash"; fail=1; }
echo "cmdline base length: ${CMDLEN}"

step "YAML (yamllint)"
if command -v yamllint >/dev/null 2>&1; then
    yamllint -d '{extends: default, rules: {line-length: {max: 160}, truthy: disable, document-start: disable}}' \
        ../.github/workflows/antumbra.yml ../.github/workflows/antumbra-release.yml || fail=1
else
    echo "yamllint not installed; skipped"
fi

step "compositor configuration"
# phoc aborts at startup on a malformed mode (the refresh rate needs "Hz").
[ -f config/rootfs/etc/antumbra/phoc.ini ] || { echo "config/rootfs/etc/antumbra/phoc.ini is missing"; fail=1; }
bad_modes="$(grep -nE '^[[:space:]]*mode[[:space:]]*=' config/rootfs/etc/antumbra/phoc.ini \
    | grep -vE '=[[:space:]]*[0-9]+x[0-9]+(@[0-9]+(\.[0-9]+)?Hz)?[[:space:]]*$' || true)"
if [ -n "${bad_modes}" ]; then echo "phoc.ini: malformed mode line(s): ${bad_modes}"; fail=1; else echo "phoc.ini: mode lines valid"; fi

step "camera"
# Antumbra never ships the OnePlus (OxygenOS) camera app or Qualcomm's camera
# HAL blobs (docs/camera.md); the VM checks scan the image the same way.
if python3 tests/no-oneplus-camera.py --skip build/cache --skip build/out --skip build/work .; then
    echo "no OnePlus/OxygenOS camera software in the tree"
else
    fail=1
fi
# The optional patched libcamera (build/libcamera.sh): every input pinned.
grep -qE '^LIBCAMERA_DSC_SHA256=[0-9a-f]{64}$' device/oneplus-hotdog/sources.lock || { echo "bad LIBCAMERA_DSC_SHA256"; fail=1; }
while read -r name; do
    [ -n "${name}" ] || continue
    grep -qE "^[0-9a-f]{64}  ${name}$" device/oneplus-hotdog/libcamera/patches.sha256 || { echo "libcamera patch ${name} has no hash"; fail=1; }
done < device/oneplus-hotdog/libcamera/patches.list
echo "libcamera inputs pinned: $(wc -l < device/oneplus-hotdog/libcamera/patches.sha256) files"

step "device profiles"
for d in device/*/; do
    [ -f "${d}device.conf" ] || { echo "${d} has no device.conf"; fail=1; }
done
a="$(sed -n 's/^USERDATA_PARTITION_SIZE=//p' device/oneplus-hotdog/device.conf)"
b="$(sed -n 's/^USERDATA_PARTITION_SIZE=//p' device/oneplus-hotdog/bootimg.conf)"
[ "${a}" = "${b}" ] || { echo "USERDATA_PARTITION_SIZE differs between device.conf (${a}) and bootimg.conf (${b})"; fail=1; }
echo "profiles: $(printf '%s ' device/*/)"

step "file modes"
# git records only 0644 and 0755, so the checkout's modes say nothing about
# the image's: rootfs.sh installs the overlays from copies that stage_overlay
# (build/lib/common.sh) makes. Stage them the same way and check the copies.
grep -nE 'sync-in[^"]*\$\{CONFIG_DIR\}' build/rootfs.sh && { echo "rootfs.sh syncs an overlay in without stage_overlay"; fail=1; }
STAGE="$(mktemp -d)"
if ( source build/lib/common.sh && stage_overlay config/rootfs "${STAGE}/rootfs" \
        && stage_overlay config/rootfs-android "${STAGE}/rootfs-android" ); then
    for f in "${STAGE}"/rootfs/etc/sudoers.d/*; do
        [ "$(stat -c %a "$f")" = "440" ] || { echo "${f#"${STAGE}"/rootfs/} is not staged 0440"; fail=1; }
    done
    for f in etc/usbguard/rules.conf etc/skel/.tor/control_auth_cookie; do
        [ "$(stat -c %a "${STAGE}/rootfs/$f")" = "600" ] || { echo "$f is not staged 0600"; fail=1; }
    done
    writable="$(find "${STAGE}" -mindepth 1 ! -type l -perm /022)"
    [ -z "${writable}" ] || { echo "group- or world-writable when staged: ${writable}"; fail=1; }
    echo "overlays staged as rootfs.sh installs them: $(find "${STAGE}" ! -type d | wc -l) files checked"
else
    echo "stage_overlay failed"; fail=1
fi
rm -rf "${STAGE}"
for f in config/hooks/*.sh build/*.sh config/rootfs-android/usr/local/lib/*; do [ -x "$f" ] || { echo "$f not executable"; fail=1; }; done

if [ "${fail}" -ne 0 ]; then echo; echo "LINT FAILED"; exit 1; fi
echo; echo "lint passed"
