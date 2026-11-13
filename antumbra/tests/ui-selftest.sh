#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build the Welcome screen's GTK4/libadwaita UI headless and let it write a
# default settings set. Needs python3-gi, gir1.2-gtk-4.0, gir1.2-adw-1,
# xvfb and openssl on the host.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
PY="${PYTHON:-python3}"
for p in /usr/bin/python3 /usr/bin/python3.13 /usr/bin/python3.12; do
    if "${p}" -c 'import gi' 2>/dev/null; then PY="${p}"; break; fi
done
"${PY}" -c 'import gi; gi.require_version("Gtk", "4.0"); gi.require_version("Adw", "1")' \
    || { echo "GTK4/libadwaita Python bindings missing; skipping UI self-test"; exit 0; }
command -v xvfb-run >/dev/null || { echo "xvfb-run missing; skipping UI self-test"; exit 0; }
PYTHONPATH=config/rootfs/usr/lib/python3/dist-packages timeout 120 \
    xvfb-run -a -s "-screen 0 480x1000x24" "${PY}" config/rootfs/usr/bin/antumbra-welcome --self-test
