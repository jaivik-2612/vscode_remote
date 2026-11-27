#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Run one phase of the daily VM workflow (.github/workflows/antumbra-vm.yml)
# and record its wall time for metrics.py: appends a line
# "NAME<TAB>START<TAB>END<TAB>STATUS" (seconds since the epoch, exit
# status) to ${ANTUMBRA_CI_OUT}/phases.tsv. A phase run as several commands
# gets several lines; metrics.py adds them up.
#
# usage: phase.sh NAME COMMAND [ARG...]     exits with COMMAND's status
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: phase.sh NAME COMMAND [ARG...]" >&2
    exit 2
fi
name="$1"
shift
[[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "phase.sh: phase names are lower-case words: '${name}'" >&2; exit 2; }
out="${ANTUMBRA_CI_OUT:?phase.sh: ANTUMBRA_CI_OUT is not set}"
mkdir -p "${out}"

start="$(date +%s)"
status=0
"$@" || status=$?
end="$(date +%s)"
printf '%s\t%s\t%s\t%s\n' "${name}" "${start}" "${end}" "${status}" >> "${out}/phases.tsv"
echo "[phase.sh] ${name}: $((end - start)) s, exit status ${status}" >&2
exit "${status}"
