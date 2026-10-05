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
mapfile -t SHELLS < <(grep -rlE '^#!/(usr/)?bin/(ba)?sh' build config/hooks config/rootfs tests --exclude-dir=cache --exclude-dir=out --exclude-dir=work 2>/dev/null | sort)
# SC3037/SC3043/SC2094: vendored Tails scripts use echo -n and local (fine under dash)
shellcheck -x -e SC1091,SC3037,SC3043,SC2094 "${SHELLS[@]}" || fail=1
echo "${#SHELLS[@]} scripts checked"

step "python (byte-compile)"
mapfile -t PYS < <(grep -rlE '^#!/usr/bin/python3' config/rootfs tests 2>/dev/null; find config/rootfs tests -name '*.py' 2>/dev/null)
python3 -m py_compile "${PYS[@]}" || fail=1
find config tests -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
echo "${#PYS[@]} python files compiled"

step "nftables ruleset (nft -c)"
# The ruleset names system users that only exist in the image; map them to
# numeric ids for the host-side syntax check.
TMPNFT="$(mktemp)"
sed -e 's/"debian-tor"/9001/g; s/"htp"/1101/g; s/"clearnet"/1102/g; s/"_apt"/9002/g; s/"proxy"/13/g; s/"nobody"/65534/g; s/"root"/0/g' \
    config/rootfs/etc/nftables.conf > "${TMPNFT}"
nft -c -f "${TMPNFT}" && echo "nftables.conf: syntax OK" || fail=1
rm -f "${TMPNFT}"

step "tor configuration (tor --verify-config)"
TMPTOR="$(mktemp -d)"
{ printf 'DataDirectory %s\nUser %s\n' "${TMPTOR}" "$(id -un)"; grep -v '^User ' config/rootfs/etc/tor/torrc; } > "${TMPTOR}/torrc"
if tor --verify-config -f "${TMPTOR}/torrc" --hush >/dev/null 2>"${TMPTOR}/err"; then echo "torrc: valid"; else cat "${TMPTOR}/err"; fail=1; fi
rm -rf "${TMPTOR}"

step "systemd units (systemd-analyze verify)"
if command -v systemd-analyze >/dev/null 2>&1; then
    # Units reference binaries that only exist in the image; only hard
    # syntax errors are fatal here.
    out="$(systemd-analyze verify --root=config/rootfs config/rootfs/usr/lib/systemd/system/*.service config/rootfs/usr/lib/systemd/system/*.timer config/rootfs/usr/lib/systemd/system/*.path config/rootfs/usr/lib/systemd/system/*.mount 2>&1 || true)"
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
    yamllint -d '{extends: default, rules: {line-length: {max: 160}, truthy: disable, document-start: disable}}' ../.github/workflows/antumbra.yml || fail=1
else
    echo "yamllint not installed; skipped"
fi

step "device profiles"
for d in device/*/; do
    [ -f "${d}device.conf" ] || { echo "${d} has no device.conf"; fail=1; }
done
a="$(sed -n 's/^USERDATA_PARTITION_SIZE=//p' device/oneplus-hotdog/device.conf)"
b="$(sed -n 's/^USERDATA_PARTITION_SIZE=//p' device/oneplus-hotdog/bootimg.conf)"
[ "${a}" = "${b}" ] || { echo "USERDATA_PARTITION_SIZE differs between device.conf (${a}) and bootimg.conf (${b})"; fail=1; }
echo "profiles: $(printf '%s ' device/*/)"

step "file modes"
for f in config/rootfs/etc/sudoers.d/*; do [ "$(stat -c %a "$f")" = "440" ] || { echo "$f must be 0440"; fail=1; }; done
[ "$(stat -c %a config/rootfs/etc/usbguard/rules.conf)" = "600" ] || { echo "usbguard rules.conf must be 0600"; fail=1; }
for f in config/hooks/*.sh build/*.sh; do [ -x "$f" ] || { echo "$f not executable"; fail=1; }; done

if [ "${fail}" -ne 0 ]; then echo; echo "LINT FAILED"; exit 1; fi
echo; echo "lint passed"
