#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra CI: make sure the Android SDK packages a job needs are installed,
# using the runner's preinstalled copies when they are the pinned revision,
# and sdkmanager (which checks each package against Google's repository
# index over HTTPS) otherwise.
#
# Usage: sdk-install.sh PACKAGE...
#   ndk          the NDK revision pinned in antumbra/android/tor/sources.lock;
#                also writes ANDROID_NDK_ROOT to $GITHUB_ENV when it is set
#   platform     platforms;android-36
#   build-tools  build-tools;36.0.0
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
SDKMANAGER=$SDK/cmdline-tools/latest/bin/sdkmanager
NDK_REV=$(awk '$1 == "ndk" { print $2 }' "$HERE/../tor/sources.lock")
[ -n "$NDK_REV" ] || { echo "sdk-install: no 'ndk' line in tor/sources.lock" >&2; exit 1; }

pkgs=()
for want in "$@"; do
	case $want in
	ndk) [ -f "$SDK/ndk/$NDK_REV/source.properties" ] || pkgs+=("ndk;$NDK_REV") ;;
	platform) [ -f "$SDK/platforms/android-36/android.jar" ] || pkgs+=("platforms;android-36") ;;
	build-tools) [ -x "$SDK/build-tools/36.0.0/aapt2" ] || pkgs+=("build-tools;36.0.0") ;;
	*) echo "sdk-install: unknown package '$want'" >&2; exit 2 ;;
	esac
done

if [ ${#pkgs[@]} -gt 0 ]; then
	[ -x "$SDKMANAGER" ] || { echo "sdk-install: no sdkmanager at $SDKMANAGER" >&2; exit 1; }
	echo "sdk-install: installing ${pkgs[*]}"
	yes 2>/dev/null | "$SDKMANAGER" --install "${pkgs[@]}" >/dev/null
else
	echo "sdk-install: already installed: $*"
fi

for want in "$@"; do
	if [ "$want" = ndk ]; then
		grep -q "^Pkg.Revision *= *$NDK_REV\$" "$SDK/ndk/$NDK_REV/source.properties" ||
			{ echo "sdk-install: $SDK/ndk/$NDK_REV is not revision $NDK_REV" >&2; exit 1; }
		echo "sdk-install: NDK $NDK_REV at $SDK/ndk/$NDK_REV"
		if [ -n "${GITHUB_ENV:-}" ]; then
			echo "ANDROID_NDK_ROOT=$SDK/ndk/$NDK_REV" >>"$GITHUB_ENV"
		fi
	fi
done
