#!/bin/sh

# Import is_package_installed
. /usr/local/lib/tails-shell-library/common.sh

strip_nondeterminism_wrapper() {
    apt-get --yes install strip-nondeterminism
    strip-nondeterminism "${@}"
    apt-get --yes purge strip-nondeterminism '^libfile-stripnondeterminism-perl'
}

# Ensure that the packages whose names are passed as arguments are
# installed. If they are installed now, they will be marked as
# "automatically installed" so the next `apt-get autoremove` action
# *unless* they are later explicitly installed (or other packages
# depends on them).
ensure_hook_dependency_is_installed() {
    # Filter out already installed packages from $@.
    for p in "${@}"; do
        shift
        if ! echo "${p}" | grep -q --extended-regexp '^[a-z0-9.+-]+$'; then
            echo "ensure_hook_dependency_is_installed():" \
                "doesn't look like a package name: ${p}" >&2
            exit 1
        fi
        if is_package_installed "${p}"; then
            continue
        fi
        set -- "${@}" "${p}"
    done
    if [ -z "${*}" ]; then
        return
    fi
    apt-get install --yes "${@}"
    apt-mark auto "${@}"
}

install_fake_package() {
    local name version section provides tmp control_file
    name="${1}"
    version="${2}"
    section="${3:-misc}"
    provides="${4:-}"
    ensure_hook_dependency_is_installed equivs
    tmp="$(mktemp -d)"
    control_file="${tmp}/${name}_${version}.control"
    cat >"${control_file}" <<EOF
Section: ${section}
Priority: optional
Homepage: https://tails.net/
Standards-Version: 3.9.6

Package: ${name}
Version: ${version}
Maintainer: Tails developers <foundations@tails.net>
Architecture: all
Provides: ${provides}
Description: (Fake) ${name}
 Dummy packaged used to meet some dependency without installing the
 real ${name} package.
EOF
    (
        cd "${tmp}"
        equivs-build "${control_file}"
        dpkg -i "${tmp}/${name}_${version}_all.deb"
    )
    rm -R "${tmp}"
}

download_file() {
    local url target curl_opts
    url="${1}"
    target="${2:-}"
    if [ -n "${target}" ]; then
        curl_opts="--output ${target}"
    else
        curl_opts="--remote-name"
    fi
    (
        # Use the builder's caching APT proxy, if any
        apt_proxy="$(apt-config --format '%v' dump Acquire::http::Proxy)"
        if [ -n "${apt_proxy}" ]; then
            # Import JENKINS_URL and TAILS_PROXY_TYPE
            . /usr/share/tails/build/variables
            if [ "${TAILS_PROXY_TYPE}" = 'vmproxy' ] || [ -n "${JENKINS_URL:-}" ]; then
                # When using the vmproxy or building on Jenkins, we know
                # that apt-cacher-ng is used, so we fetch and cache over
                # https using the HTTPS/// trick
                # (https://www.unix-ag.uni-kl.de/~bloch/acng/html/howtos.html#ssluse)
                url="$(echo "${url}" | sed "s@^https://@${apt_proxy}/HTTPS///@")"
                unset HTTP_PROXY http_proxy HTTPS_PROXY https_proxy
            else
                # Otherwise it's the user's responsibility to configure their proxy
                # to support the (possibly HTTPS) URL we want to download.
                export HTTP_PROXY="${apt_proxy}"
                export http_proxy="${apt_proxy}"
                export HTTPS_PROXY="${apt_proxy}"
                export https_proxy="${apt_proxy}"
            fi
        fi
        # Bypass the /usr/local/bin/curl wrapper
        # shellcheck disable=SC2086
        /usr/bin/curl --retry 20 ${curl_opts} "${url}"
    )
}
