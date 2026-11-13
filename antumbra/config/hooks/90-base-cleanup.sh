#!/bin/sh
set -eu
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/log/apt /var/log/dpkg.log /var/log/alternatives.log
rm -rf /tmp/* /var/tmp/* /root/.cache /root/.bash_history
find /var/log -type f -delete 2>/dev/null || true
# the greeter's settings directories are created at boot by tmpfiles
rm -rf /var/lib/antumbra/settings/transient /var/lib/antumbra/settings/applied
