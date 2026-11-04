#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# WEL9's probe apps for the emulator job (antumbra/android/ci/
# emulator-antumbra.sh): code-less APKs that ask for location and phone
# state and contain nothing else, built with the SDK's aapt2, zipalign and
# apksigner and signed with two keys made for this build and thrown away
# after it: key "a" for the location probes, key "b" for the two carrier
# probes, whose certificate's SHA-256 the emulator job puts in the carrier
# configuration. The welcome job runs this (it has the build tools); a
# failure here only leaves the emulator's WEL9 checks "not judged".
#
#   ci/build-probes.sh OUT_DIR
#
# Writes OUT_DIR/<package>.apk for each probe, OUT_DIR/probes.txt (one
# "package key" line each) and OUT_DIR/carrier-cert-sha256 (key b's
# certificate's SHA-256, lower-case hexadecimal, as apksigner prints it).
# Needs ANDROID_HOME (platform 36, build-tools 36.0.0) and keytool.
set -euo pipefail

out=${1:?usage: build-probes.sh OUT_DIR}
sdk=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}}
bt=$sdk/build-tools/36.0.0
jar=$sdk/platforms/android-36/android.jar
die() { echo "build-probes: $*" >&2; exit 1; }
for t in "$bt/aapt2" "$bt/zipalign" "$bt/apksigner" "$jar"; do [ -e "$t" ] || die "missing $t"; done
command -v keytool >/dev/null || die "no keytool"

# The probes: package and key. One, two and three are installed before
# Start (one chosen precise, two approximate, three not chosen); late
# during the session; carrier before the carrier configuration names key
# b, carrierlate while it does.
PROBES=(
    "org.antumbra.probe.one a"
    "org.antumbra.probe.two a"
    "org.antumbra.probe.three a"
    "org.antumbra.probe.late a"
    "org.antumbra.probe.carrier b"
    "org.antumbra.probe.carrierlate b"
)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
# The keys live in the work directory only; their password is this build's.
pass=$(od -An -N 18 -tx1 /dev/urandom | tr -d ' \n')
for k in a b; do
    keytool -genkeypair -keystore "$work/$k.p12" -storetype PKCS12 -storepass "$pass" -keypass "$pass" -alias probe \
        -keyalg RSA -keysize 2048 -validity 30 -dname "CN=Antumbra CI probe $k" -noprompt >/dev/null 2>&1 ||
        die "keytool could not make key $k"
done

: >"$out/probes.txt"
for spec in "${PROBES[@]}"; do
    read -r pkg key <<<"$spec"
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\" package=\"$pkg\"" \
        '    android:versionCode="1" android:versionName="1">' \
        '    <uses-sdk android:minSdkVersion="34" android:targetSdkVersion="36" />' \
        '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />' \
        '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />' \
        '    <uses-permission android:name="android.permission.ACCESS_BACKGROUND_LOCATION" />' \
        '    <uses-permission android:name="android.permission.READ_PHONE_STATE" />' \
        '    <uses-permission android:name="android.permission.READ_PHONE_NUMBERS" />' \
        "    <application android:hasCode=\"false\" android:label=\"Antumbra probe ${pkg##*.}\" />" \
        '</manifest>' >"$work/$pkg.xml"
    "$bt/aapt2" link -o "$work/$pkg.unaligned.apk" -I "$jar" --manifest "$work/$pkg.xml" || die "aapt2 could not link $pkg"
    "$bt/zipalign" -f -p 4 "$work/$pkg.unaligned.apk" "$work/$pkg.aligned.apk" || die "zipalign failed for $pkg"
    "$bt/apksigner" sign --ks "$work/$key.p12" --ks-pass "pass:$pass" --ks-key-alias probe \
        --out "$out/$pkg.apk" "$work/$pkg.aligned.apk" || die "apksigner could not sign $pkg"
    rm -f "$out/$pkg.apk.idsig"
    echo "$pkg $key" >>"$out/probes.txt"
done

# Key b's certificate's SHA-256, as Android hashes it (Signature.toByteArray
# is the certificate's DER encoding, which apksigner hashes too).
"$bt/apksigner" verify --print-certs "$out/org.antumbra.probe.carrier.apk" |
    sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | tr 'A-F' 'a-f' >"$out/carrier-cert-sha256"
grep -qE '^[0-9a-f]{64}$' "$out/carrier-cert-sha256" || die "no certificate hash for key b"
# Key a's must differ: only the carrier probes may match.
a=$("$bt/apksigner" verify --print-certs "$out/org.antumbra.probe.one.apk" | sed -n 's/^Signer #1 certificate SHA-256 digest: //p')
[ -n "$a" ] && [ "$a" != "$(cat "$out/carrier-cert-sha256")" ] || die "keys a and b have the same certificate"
echo "build-probes: ${#PROBES[@]} probes in $out; key b's certificate $(cut -c1-16 "$out/carrier-cert-sha256")…"
