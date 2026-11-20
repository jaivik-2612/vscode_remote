#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs inside build/libcamera.sh's throwaway trixie chroot (POSIX sh).
#
# usage: libcamera-chroot.sh prepare | build
#   prepare  unpack Debian's source package into /build/src and apply
#            Antumbra's changes: antumbra-packaging.diff, the port's patches
#            appended to debian/patches/series (dpkg-source applies them
#            before the build, with no fuzz), the tuning files added to
#            libcamera-ipa, and a changelog entry for LOCAL_VERSION
#   build    dpkg-buildpackage for arm64 (binary packages only), then a flat
#            apt repository in /build/repo
#
# Input: /build/input (staged by libcamera.sh), including build.env with
# DSC, LOCAL_VERSION, SUITE, CHANGELOG_DATE, PROFILES, ARCH_OPT, JOBS and
# SOURCE_DATE_EPOCH.
set -eu
IN=/build/input
# shellcheck source=/dev/null
. "${IN}/build.env"
export SOURCE_DATE_EPOCH

prepare() {
    cd /build
    rm -rf src
    dpkg-source -x "${IN}/${DSC}" src
    cd src
    patch -p1 -s --no-backup-if-mismatch < "${IN}/antumbra-packaging.diff"
    while read -r p; do
        [ -n "${p}" ] || continue
        cp "${IN}/patches/${p}" "debian/patches/${p}"
        printf '%s\n' "${p}" >> debian/patches/series
    done < "${IN}/patches.list"
    # The port installs its tuning files into the soft ISP's data directory;
    # libcamera picks the file named after the sensor model.
    mkdir -p debian/antumbra-tuning
    cp "${IN}"/tuning/*.yaml debian/antumbra-tuning/
    printf '%s\n' 'debian/antumbra-tuning/*.yaml usr/share/libcamera/ipa/simple' >> debian/libcamera-ipa.install
    {
        printf 'libcamera (%s) %s; urgency=medium\n\n' "${LOCAL_VERSION}" "${SUITE}"
        printf '  * Antumbra rebuild for %s (build/libcamera.sh).\n' "${SUITE}"
        printf '  * Add the hotdog-linux-bringup patches 0003-0010: sensor data for the\n'
        printf '    IMX471, IMX586, IMX481 and S5K3M5, soft ISP autofocus and 3A changes.\n'
        printf '  * Install the port'"'"'s soft ISP tuning files for those four sensors.\n'
        printf '  * Drop the tensorflow-lite build dependency; honour the nopython and\n'
        printf '    noqt build profiles.\n\n'
        printf ' -- Antumbra build <build@antumbra.invalid>  %s\n\n' "${CHANGELOG_DATE}"
        cat debian/changelog
    } > debian/changelog.antumbra
    mv debian/changelog.antumbra debian/changelog
    echo "prepared libcamera ${LOCAL_VERSION}: $(wc -l < debian/patches/series) patches in the series"
}

build() {
    cd /build/src
    export DEB_BUILD_OPTIONS="nocheck nodoc noautodbgsym parallel=${JOBS}"
    # ARCH_OPT is empty (native) or -aarm64 (cross build); word splitting wanted.
    # shellcheck disable=SC2086
    dpkg-buildpackage -B -us -uc ${ARCH_OPT} -P"${PROFILES}"
    # libcamera runs an IPA module inside the camera process only if its
    # signature verifies against the key built into libcamera0.7. Debian's
    # rules check that only in native builds, so check it here for both:
    # every packaged module against this build's key, and that key inside
    # the packaged library.
    openssl pkey -in obj-*/src/ipa-priv-key.pem -pubout -outform DER -out /build/ipa-pub.der
    for so in debian/libcamera-ipa/usr/lib/*/libcamera/ipa/ipa_*.so; do
        openssl dgst -sha256 -verify /build/ipa-pub.der -keyform DER -signature "${so}.sign" "${so}" >/dev/null \
            || { echo "IPA signature does not verify: ${so}" >&2; exit 1; }
    done
    python3 -c 'import sys; sys.exit(open(sys.argv[2], "rb").read() not in open(sys.argv[1], "rb").read())' \
        debian/libcamera0.7/usr/lib/*/libcamera.so.*.*.* /build/ipa-pub.der \
        || { echo "libcamera0.7 does not carry the key the IPA modules were signed with" >&2; exit 1; }
    echo "IPA module signatures verified"
    rm -rf /build/repo
    mkdir -p /build/repo
    cp /build/*.deb /build/repo/
    cd /build/repo
    for pkg in libcamera0.7 libcamera-ipa gstreamer1.0-libcamera libcamera-tools libcamera-v4l2; do
        [ -f "${pkg}_${LOCAL_VERSION#*:}_arm64.deb" ] || { echo "missing ${pkg} ${LOCAL_VERSION} arm64" >&2; exit 1; }
    done
    dpkg-deb -c "libcamera-ipa_${LOCAL_VERSION#*:}_arm64.deb" | grep '/usr/share/libcamera/ipa/simple/imx471.yaml$' >/dev/null \
        || { echo "libcamera-ipa lacks the IMX471 tuning file" >&2; exit 1; }
    dpkg-scanpackages --multiversion . > Packages
    gzip -9nk Packages
    # Origin and Label are what rootfs.sh pins.
    apt-ftparchive \
        -o APT::FTPArchive::Release::Origin=Antumbra \
        -o APT::FTPArchive::Release::Label=antumbra-libcamera \
        -o APT::FTPArchive::Release::Suite=antumbra-libcamera \
        -o APT::FTPArchive::Release::Codename=antumbra-libcamera \
        -o APT::FTPArchive::Release::Architectures=arm64 \
        release . > ../Release
    mv ../Release Release
    ls -l
}

case "${1:-}" in
    prepare) prepare ;;
    build) build ;;
    *) echo "usage: $0 prepare|build" >&2; exit 2 ;;
esac
