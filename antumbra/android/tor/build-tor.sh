#!/usr/bin/env bash
# Antumbra: cross-compile tor for Android as a standalone PIE executable.
#
# Builds tor with OpenSSL, libevent and zlib for the Android ABIs arm64-v8a
# and x86_64 with the Android NDK. OpenSSL, libevent and zlib are linked in
# statically; the executable links dynamically only against the system's
# bionic C library (libc, libm, libdl) through /system/bin/linker64, like
# any NDK program. There is no JNI and no Java: the module starts the
# binary directly.
#
# Why not a fully static binary: bionic's libc.a does not support static
# PIE (such a binary crashes at start), and a static non-PIE executable
# would load tor's code at a fixed address, without ASLR.
#
# Every source tarball is pinned by SHA-256 in sources.lock and checked
# before it is unpacked. When gpg is installed, the publisher's OpenPGP
# signature is checked too, against the key fingerprints in sources.lock.
#
# Outputs, for each ABI built:
#   OUT/<abi>/tor            the stripped executable
#   OUT/<abi>/tor.buildinfo  versions, toolchain, flags and SHA-256
#   OUT/SHA256SUMS           checksums of every file above
#
# The build is meant to be reproducible: the same sources.lock, NDK
# revision, API level and this script give byte-identical binaries,
# whatever the work directory. Nothing in the output depends on the time,
# the host name or the build path.
set -Eeuo pipefail
umask 022
export LC_ALL=C LANG=C TZ=UTC

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCK=$HERE/sources.lock
# The prefix compiled into tor and OpenSSL (the module directory on the
# phone). Nothing is installed there by this script. tor is configured with
# --disable-system-torrc, so it reads only the torrc given with -f.
PREFIX=/data/adb/modules/antumbra

usage() {
  cat <<'EOF'
Usage: build-tor.sh --out DIR [options]

  --out DIR           where to put <abi>/tor, <abi>/tor.buildinfo and SHA256SUMS
  --abi ABI           arm64-v8a, x86_64 or all (default: all)
  --api N             Android API level to build for (default: from sources.lock)
  --jobs N            parallel make jobs (default: 2)
  --work DIR          scratch directory (default: a new one under $TMPDIR or /tmp)
  --downloads DIR     keep verified tarballs here between runs (default: WORK/downloads)
  --ndk DIR           Android NDK to use (default: the pinned revision under
                      $ANDROID_HOME/ndk or /opt/android-sdk/ndk, then $ANDROID_NDK_ROOT)
  --signatures MODE   auto: check OpenPGP signatures if gpg is installed (default)
                      require: fail if gpg is missing; skip: SHA-256 pins only
  --host-check MODE   auto (default), yes or no. For x86_64 on an x86_64 Linux
                      host, also link a static copy of tor inside the work
                      directory and run hostcheck-tor.sh on it. The static
                      copy is never put in --out.
  --allow-other-ndk   build with an NDK other than the pinned revision
  --keep-work         do not delete the unpacked sources and objects
  --fetch-only        download and verify the sources, then stop
  --print-cache-key   print the CI cache key for these options, then stop
EOF
}

say() { printf '[build-tor] %s\n' "$*" >&2; }
die() { printf '[build-tor] error: %s\n' "$*" >&2; exit 1; }

OUT='' ABI_ARG=all API='' JOBS=2 WORK='' DOWNLOADS='' NDK=''
SIGS=auto HOST_CHECK=auto ALLOW_OTHER_NDK=0 KEEP_WORK=0 FETCH_ONLY=0 PRINT_KEY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --out)             OUT=${2:?--out needs a value}; shift 2 ;;
    --abi)             ABI_ARG=${2:?--abi needs a value}; shift 2 ;;
    --api)             API=${2:?--api needs a value}; shift 2 ;;
    --jobs)            JOBS=${2:?--jobs needs a value}; shift 2 ;;
    --work)            WORK=${2:?--work needs a value}; shift 2 ;;
    --downloads)       DOWNLOADS=${2:?--downloads needs a value}; shift 2 ;;
    --ndk)             NDK=${2:?--ndk needs a value}; shift 2 ;;
    --signatures)      SIGS=${2:?--signatures needs a value}; shift 2 ;;
    --host-check)      HOST_CHECK=${2:?--host-check needs a value}; shift 2 ;;
    --allow-other-ndk) ALLOW_OTHER_NDK=1; shift ;;
    --keep-work)       KEEP_WORK=1; shift ;;
    --fetch-only)      FETCH_ONLY=1; shift ;;
    --print-cache-key) PRINT_KEY=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 usage >&2; die "unknown argument: $1" ;;
  esac
done

case $ABI_ARG in
  all)                ABIS=(arm64-v8a x86_64) ;;
  arm64-v8a|x86_64)   ABIS=("$ABI_ARG") ;;
  *)                  die "--abi must be arm64-v8a, x86_64 or all" ;;
esac
case $SIGS in auto|require|skip) ;; *) die "--signatures must be auto, require or skip" ;; esac
case $HOST_CHECK in auto|yes|no) ;; *) die "--host-check must be auto, yes or no" ;; esac
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive number"

# --- sources.lock ---------------------------------------------------------

# lock_fields KIND [NAME]: print the values of every matching record, one
# record per line, without KIND (and without NAME when NAME is given).
lock_fields() {
  awk -v k="$1" -v n="${2-}" '
    /^[ \t]*(#|$)/ { next }
    $1 != k        { next }
    n == ""        { $1 = ""; sub(/^ +/, ""); print; next }
    $2 == n        { $1 = ""; $2 = ""; sub(/^ +/, ""); print }' "$LOCK"
}
# lock_one KIND [NAME]: the first value of the only matching record.
lock_one() {
  local v
  v=$(lock_fields "$@" | awk 'NR == 1 { print $1 } END { if (NR != 1) exit 1 }') ||
    die "sources.lock: expected exactly one '$*' record"
  printf '%s\n' "$v"
}
# src_field NAME N: field N of the source record (1 version, 2 SHA-256, 3 file).
src_field() {
  local v
  v=$(lock_fields source "$1" | awk -v i="$2" 'NR == 1 { print $i }')
  [[ -n $v ]] || die "sources.lock: no source record for $1"
  printf '%s\n' "$v"
}

[[ -r $LOCK ]] || die "cannot read $LOCK"
API=${API:-$(lock_one api)}
[[ $API =~ ^[0-9]+$ && $API -ge 21 ]] || die "--api must be a number of at least 21"
NDK_WANT=$(lock_one ndk)
EPOCH=$(lock_one epoch)
[[ $EPOCH =~ ^[0-9]+$ ]] || die "sources.lock: epoch must be a number"
export SOURCE_DATE_EPOCH=$EPOCH

# The cache key covers every input listed in cache-key.txt plus the options
# that change the output.
cache_key() {
  local files=() f
  while read -r f; do files+=("$HERE/$f"); done < <(awk '$1 == "file" { print $2 }' "$HERE/cache-key.txt")
  [[ ${#files[@]} -gt 0 ]] || die "cache-key.txt lists no files"
  {
    printf 'abis=%s api=%s ndk=%s host=%s-%s\n' "${ABIS[*]}" "$API" "$NDK_WANT" "$(uname -s)" "$(uname -m)"
    (cd "$HERE" && sha256sum "${files[@]#"$HERE/"}")
  } | sha256sum | cut -c1-32
}
if ((PRINT_KEY)); then
  printf 'antumbra-tor-%s-%s-%s\n' "$(src_field tor 1)" "${ABI_ARG}" "$(cache_key)"
  exit 0
fi

[[ -n $OUT ]] || { usage >&2; die "--out is required"; }

# --- work directories ------------------------------------------------------

if [[ -z $WORK ]]; then
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/antumbra-tor.XXXXXX")
fi
mkdir -p "$WORK" "$OUT"
WORK=$(cd "$WORK" && pwd -P)
OUT=$(cd "$OUT" && pwd -P)
DOWNLOADS=${DOWNLOADS:-$WORK/downloads}
mkdir -p "$DOWNLOADS" "$WORK/logs"
DOWNLOADS=$(cd "$DOWNLOADS" && pwd -P)
case $OUT/ in "$WORK"/*) die "--out must not be inside the work directory" ;; esac
say "work directory: $WORK"

# --- toolchain -------------------------------------------------------------

find_ndk() {
  local c
  if [[ -z $NDK ]]; then
    for c in "${ANDROID_HOME:+$ANDROID_HOME/ndk/$NDK_WANT}" \
             "${ANDROID_SDK_ROOT:+$ANDROID_SDK_ROOT/ndk/$NDK_WANT}" \
             "/opt/android-sdk/ndk/$NDK_WANT" \
             "${ANDROID_NDK_ROOT-}" "${ANDROID_NDK_HOME-}"; do
      if [[ -n $c && -f $c/source.properties ]]; then NDK=$c; break; fi
    done
  fi
  [[ -n $NDK && -f $NDK/source.properties ]] ||
    die "no Android NDK found; install 'ndk;$NDK_WANT' with sdkmanager or pass --ndk"
  NDK=$(cd "$NDK" && pwd -P)
  NDK_REV=$(sed -n 's/^Pkg\.Revision *= *//p' "$NDK/source.properties" | tr -d '\r')
  if [[ $NDK_REV != "$NDK_WANT" ]]; then
    ((ALLOW_OTHER_NDK)) ||
      die "the NDK at $NDK is $NDK_REV; sources.lock pins $NDK_WANT (--allow-other-ndk to build anyway)"
    say "warning: NDK $NDK_REV instead of the pinned $NDK_WANT; the output will differ from a pinned build"
  fi
  [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] ||
    die "the NDK toolchain used here needs a Linux x86_64 build host"
  TCBIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
  [[ -x $TCBIN/clang ]] || die "no clang in $TCBIN"
}

# --- downloads and verification ---------------------------------------------

CURL=(curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https'
      --tlsv1.2 --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 900)

# fetch DEST URL...: download the first URL that works to DEST.
fetch() {
  local dest=$1 u
  shift
  for u in "$@"; do
    say "  fetching $u"
    if "${CURL[@]}" -o "$dest.part" "$u"; then
      mv -f "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"
  done
  return 1
}
sha256_of() { sha256sum "$1" | awk '{ print $1 }'; }

GNUPG_DIR=''
gpgq() { gpg --homedir "$GNUPG_DIR" --batch --no-tty --no-autostart "$@"; }

# check_signature NAME TARBALL SHA256: check the publisher's signature.
check_signature() {
  local name=$1 tarball=$2 sha=$3 type signed sig status n=0 u kf ok=0 primary f s
  local -a urls signers
  if [[ $SIGS == skip ]]; then
    say "$name: signature check skipped (--signatures skip); relying on the pinned SHA-256"
    return 0
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    [[ $SIGS == require ]] && die "gpg is not installed and --signatures require was given"
    say "$name: gpg is not installed; relying on the pinned SHA-256 only"
    return 0
  fi
  if [[ -z $GNUPG_DIR ]]; then
    GNUPG_DIR=$WORK/gnupg
    rm -rf "$GNUPG_DIR"
    mkdir -m 700 "$GNUPG_DIR"
  fi
  mkdir -p "$DOWNLOADS/keys"
  # Keys are fetched again on every run so that renewals and revocations
  # are seen; a cached copy is used only if the fetch fails.
  while read -r u; do
    n=$((n + 1))
    kf=$DOWNLOADS/keys/$name-$n.key
    if ! fetch "$kf.new" "$u"; then
      [[ -s $kf ]] || die "$name: could not download a signing key from $u"
      say "$name: using the cached copy of $u"
    else
      mv -f "$kf.new" "$kf"
    fi
    # gpg exits non-zero when it cannot reach a gpg-agent, which public-key
    # import and verification do not need. Ignore the status: a key that
    # was not imported cannot produce the VALIDSIG checked below.
    gpgq --quiet --import "$kf" >/dev/null 2>&1 || true
  done < <(lock_fields keyurl "$name")
  ((n > 0)) || die "sources.lock: no keyurl for $name"

  type=$(lock_one sigtype "$name")
  case $type in
    detached)
      signed=$tarball ;;
    sha256sum)
      signed=$tarball.sha256sum
      mapfile -t urls < <(lock_fields sumurl "$name")
      fetch "$signed" "${urls[@]}" || die "$name: could not download the checksum file"
      # The signed checksum file must name this tarball with the pinned hash.
      read -r s f < "$signed" || true
      f=${f#\*}
      [[ $s == "$sha" && $f == "$(basename "$tarball")" ]] ||
        die "$name: the signed checksum file does not match sources.lock"
      ;;
    *) die "sources.lock: unknown sigtype '$type' for $name" ;;
  esac
  sig=$signed.asc
  mapfile -t urls < <(lock_fields sigurl "$name")
  fetch "$sig" "${urls[@]}" || die "$name: could not download the signature"

  status=$(gpgq --status-fd 1 --verify "$sig" "$signed" 2>/dev/null || true)
  if grep -qE '^\[GNUPG:\] (BADSIG|REVKEYSIG)' <<<"$status"; then
    die "$name: bad signature, or signed by a revoked key"
  fi
  mapfile -t signers < <(lock_fields signer "$name" | awk '{ print $1 }')
  while read -r primary; do
    for f in "${signers[@]}"; do
      [[ $primary == "$f" ]] && ok=$((ok + 1))
    done
  done < <(awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $NF }' <<<"$status")
  ((ok > 0)) || die "$name: no valid signature by a key listed in sources.lock"
  say "$name: OpenPGP signature verified; $ok valid signature(s) by keys in sources.lock"
  awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print "[build-tor]   signing key " $3 ", primary key " $NF }' <<<"$status" >&2
  if grep -q '^\[GNUPG:\] EXPKEYSIG' <<<"$status"; then
    say "$name: note: at least one signing key has expired since (the signature itself is valid)"
  fi
}

# get_source NAME: make sure DOWNLOADS holds the pinned, verified tarball.
get_source() {
  local name=$1 ver sha file dest got
  local -a urls
  ver=$(src_field "$name" 1)
  sha=$(src_field "$name" 2)
  file=$(src_field "$name" 3)
  [[ $sha =~ ^[0-9a-f]{64}$ ]] || die "sources.lock: bad SHA-256 for $name"
  [[ $file =~ ^[A-Za-z0-9._-]+$ ]] || die "sources.lock: bad file name for $name"
  dest=$DOWNLOADS/$file
  if [[ -f $dest && $(sha256_of "$dest") == "$sha" ]]; then
    say "$name $ver: cached tarball matches the pinned SHA-256"
  else
    rm -f "$dest"
    mapfile -t urls < <(lock_fields url "$name")
    fetch "$dest" "${urls[@]}" || die "could not download $file"
    got=$(sha256_of "$dest")
    if [[ $got != "$sha" ]]; then
      rm -f "$dest"
      die "$file: SHA-256 is $got but sources.lock pins $sha"
    fi
    say "$name $ver: SHA-256 matches sources.lock"
  fi
  check_signature "$name" "$dest" "$sha"
}

# --- build steps -----------------------------------------------------------

# run LOG CMD...: run a build step with its output in LOG; show the end of
# the log if it fails. 'set -e' does not apply inside the step (it runs as
# an 'if' condition), so every step chains its commands with '&&'.
run() {
  local log=$1
  shift
  if ! "$@" >"$log" 2>&1; then
    say "step failed; last lines of $log:"
    tail -n 40 "$log" >&2
    exit 1
  fi
}

# Per-ABI settings, set by build_abi and used by the steps below.
TRIPLE='' OSSL_TARGET='' STAGE='' DEP='' TC=() CFLAGS_LIB='' TOOLPATH=''
TOR_OPTS=() OSSL_OPTS=(no-shared no-module no-dso no-engine no-comp no-quic no-apps
  no-docs no-tests no-ui-console no-autoload-config no-weak-ssl-ciphers)

step_zlib() (
  cd "$1" &&
  env "${TC[@]}" CHOST="$TRIPLE" CFLAGS="$CFLAGS_LIB" ./configure --static --prefix="$PREFIX" &&
  env "${TC[@]}" make -j"$JOBS" libz.a &&
  env "${TC[@]}" make install DESTDIR="$STAGE"
)

# OpenSSL finds the NDK's clang on PATH and then names the compiler by its
# bare target name (for example aarch64-linux-android34-clang), so no host
# path ends up in the "compiler:" string it stores in the library.
step_openssl() (
  cd "$1" &&
  env -u CC -u CXX -u AR -u RANLIB -u LD -u CFLAGS PATH="$TOOLPATH" ANDROID_NDK_ROOT="$NDK" \
    ./Configure "$OSSL_TARGET" -D__ANDROID_API__="$API" --prefix="$PREFIX" --libdir=lib \
    --openssldir="$PREFIX/etc/ssl" "${OSSL_OPTS[@]}" \
    -fstack-protector-strong -D_FORTIFY_SOURCE=2 &&
  env -u CC -u CFLAGS PATH="$TOOLPATH" make -j"$JOBS" build_libs &&
  env -u CC -u CFLAGS PATH="$TOOLPATH" make install_dev DESTDIR="$STAGE"
)

step_libevent() (
  cd "$1" &&
  env "${TC[@]}" CFLAGS="$CFLAGS_LIB" ./configure --host="$TRIPLE" --prefix="$PREFIX" \
    --disable-shared --enable-static --with-pic --disable-openssl \
    --disable-samples --disable-libevent-regress --disable-debug-mode &&
  env "${TC[@]}" make -j"$JOBS" &&
  env "${TC[@]}" make install DESTDIR="$STAGE"
)

step_tor_configure() (
  cd "$1" &&
  env "${TC[@]}" CFLAGS="$CFLAGS_LIB" ./configure "${TOR_OPTS[@]}"
)

step_tor_make() (
  env "${TC[@]}" make -C "$1" -j"$JOBS" src/app/tor
)

# Relink src/app/tor as a static, non-PIE executable from the same objects.
# bionic's libc.a needs dladdr() from libdl.a (for backtrace_symbols_fd), so
# both go in one link group at the end.
step_tor_relink_static() (
  rm -f "$1/src/app/tor" &&
  env "${TC[@]}" make -C "$1" src/app/tor LDFLAGS="-static" \
    LIBS="-Wl,--start-group -lc -ldl -Wl,--end-group"
)

build_abi() {
  local abi=$1 base src v_tor v_ossl v_lev v_zlib n torsrc
  case $abi in
    arm64-v8a) TRIPLE=aarch64-linux-android OSSL_TARGET=android-arm64 ;;
    x86_64)    TRIPLE=x86_64-linux-android  OSSL_TARGET=android-x86_64 ;;
  esac
  v_tor=$(src_field tor 1)
  v_ossl=$(src_field openssl 1)
  v_lev=$(src_field libevent 1)
  v_zlib=$(src_field zlib 1)
  base=$WORK/$abi
  src=$base/src
  STAGE=$base/stage
  DEP=$STAGE$PREFIX
  TOOLPATH=$TCBIN:$PATH
  TC=(PATH="$TOOLPATH" CC="$TRIPLE$API-clang" AR=llvm-ar RANLIB=llvm-ranlib NM=llvm-nm
      STRIP=llvm-strip OBJDUMP=llvm-objdump LD=ld.lld)
  # Hardening for the libraries; tor's configure adds its own (stack
  # protector, FORTIFY, PIE, full RELRO and BIND_NOW). -ffile-prefix-map
  # keeps the work directory out of the output. OpenSSL does not get it:
  # it stores its compiler flags in the library, and it compiles with
  # relative paths anyway.
  CFLAGS_LIB="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fPIC -ffile-prefix-map=$WORK=/antumbra-build"
  # --enable-gpl turns on the onion-service proof-of-work module, which
  # needs GPL code. Tor Browser's tor has it; without it, this client would
  # get the lowest priority at onion services under attack and would stand
  # out from Tor Browser users. The binary is then covered by the GPL 3.0,
  # like the rest of Antumbra.
  TOR_OPTS=(--host="$TRIPLE" --prefix="$PREFIX" --enable-gpl
    --enable-static-openssl --with-openssl-dir="$DEP"
    --enable-static-libevent --with-libevent-dir="$DEP"
    --enable-static-zlib --with-zlib-dir="$DEP"
    --disable-module-relay --disable-module-dirauth
    --disable-system-torrc --disable-unittests
    --disable-asciidoc --disable-manpage --disable-html-manual
    --disable-lzma --disable-zstd --disable-seccomp --disable-libscrypt --disable-systemd
    --disable-tool-name-check)

  say "[$abi] unpacking sources"
  rm -rf "$base"
  mkdir -p "$src" "$STAGE"
  for n in zlib openssl libevent tor; do
    tar -xzf "$DOWNLOADS/$(src_field "$n" 3)" -C "$src" --no-same-owner
  done
  torsrc=$src/tor-$v_tor

  say "[$abi] zlib $v_zlib"
  run "$WORK/logs/$abi-zlib.log" step_zlib "$src/zlib-$v_zlib"
  say "[$abi] OpenSSL $v_ossl"
  run "$WORK/logs/$abi-openssl.log" step_openssl "$src/openssl-$v_ossl"
  say "[$abi] libevent $v_lev"
  run "$WORK/logs/$abi-libevent.log" step_libevent "$src/libevent-$v_lev"
  say "[$abi] tor $v_tor"
  run "$WORK/logs/$abi-tor-configure.log" step_tor_configure "$torsrc"
  # TransPort needs Linux netfilter support (SO_ORIGINAL_DST). Without it
  # tor would build but refuse the TransPort line.
  grep -q '^#define USE_TRANSPARENT 1' "$torsrc/orconfig.h" ||
    die "[$abi] tor was configured without transparent proxy support"
  grep -q '^#define HAVE_LINUX_NETFILTER_IPV4_H 1' "$torsrc/orconfig.h" ||
    die "[$abi] tor did not find linux/netfilter_ipv4.h"
  grep -q '^#define HAVE_MODULE_POW 1' "$torsrc/orconfig.h" ||
    die "[$abi] tor was configured without the proof-of-work module"
  if grep -q '^#define HAVE_MODULE_RELAY 1' "$torsrc/orconfig.h"; then
    die "[$abi] tor was configured with the relay module"
  fi
  run "$WORK/logs/$abi-tor-make.log" step_tor_make "$torsrc"

  say "[$abi] installing into $OUT/$abi"
  mkdir -p "$OUT/$abi"
  "$TCBIN/llvm-strip" --strip-all -o "$OUT/$abi/tor.part" "$torsrc/src/app/tor"
  chmod 0755 "$OUT/$abi/tor.part"
  mv -f "$OUT/$abi/tor.part" "$OUT/$abi/tor"
  {
    printf 'tor_version=%s\n' "$v_tor"
    printf 'openssl_version=%s\n' "$v_ossl"
    printf 'libevent_version=%s\n' "$v_lev"
    printf 'zlib_version=%s\n' "$v_zlib"
    printf 'abi=%s\n' "$abi"
    printf 'target=%s%s\n' "$TRIPLE" "$API"
    printf 'ndk_revision=%s\n' "$NDK_REV"
    printf 'source_date_epoch=%s\n' "$EPOCH"
    printf 'link=PIE; bionic libc, libm and libdl dynamic; OpenSSL, libevent and zlib static\n'
    printf 'license=GPL-3.0-only (tor --enable-gpl); OpenSSL Apache-2.0; libevent BSD-3-Clause; zlib Zlib\n'
    printf 'tor_configure=%s\n' "${TOR_OPTS[*]//$WORK/WORK}"
    printf 'openssl_configure=%s %s\n' "$OSSL_TARGET" "${OSSL_OPTS[*]}"
    printf 'build_script_sha256=%s\n' "$(sha256_of "$HERE/build-tor.sh")"
    printf 'sources_lock_sha256=%s\n' "$(sha256_of "$LOCK")"
    printf 'tor_sha256=%s\n' "$(sha256_of "$OUT/$abi/tor")"
  } >"$OUT/$abi/tor.buildinfo"

  say "[$abi] checking the binary"
  "$HERE/check-tor-binary.sh" --abi "$abi" --api "$API" --expect-version "$v_tor" \
    --forbid-string "$WORK" --forbid-string "$NDK" "$OUT/$abi/tor"

  if [[ $abi == x86_64 && $HOST_CHECK != no ]]; then
    host_check "$torsrc" "$base"
  fi

  if ((KEEP_WORK)); then
    say "[$abi] keeping $base (--keep-work)"
  else
    rm -rf "$src" "$STAGE"
  fi
}

# host_check TORSRC BASE: link a static, non-PIE copy of the x86_64 tor
# from the same objects and run hostcheck-tor.sh on it. bionic's static
# executables run on an ordinary x86_64 Linux kernel; the shipped binary
# cannot run here, because it needs Android's /system/bin/linker64. The
# copy stays in the work directory and is never shipped.
host_check() {
  local torsrc=$1 base=$2
  say "[x86_64] host check: linking a static copy for this host"
  cp -p "$torsrc/src/app/tor" "$torsrc/src/app/tor.pie"
  run "$WORK/logs/x86_64-tor-hostcheck-link.log" step_tor_relink_static "$torsrc"
  mv -f "$torsrc/src/app/tor" "$base/tor-hostcheck"
  mv -f "$torsrc/src/app/tor.pie" "$torsrc/src/app/tor"
  "$HERE/hostcheck-tor.sh" --expect-version "$(src_field tor 1)" \
    --expect-library "OpenSSL $(src_field openssl 1)" \
    --expect-library "$(src_field libevent 1)" \
    --expect-library "$(src_field zlib 1)" \
    "$base/tor-hostcheck"
}

# --- main ------------------------------------------------------------------

find_ndk
say "NDK $NDK_REV at $NDK; API level $API; ABIs: ${ABIS[*]}"
for n in tor openssl libevent zlib; do get_source "$n"; done
if ((FETCH_ONLY)); then
  say "sources downloaded and verified (--fetch-only)"
  exit 0
fi
for abi in "${ABIS[@]}"; do build_abi "$abi"; done

(cd "$OUT" && find . -mindepth 2 -maxdepth 2 -type f \( -name tor -o -name tor.buildinfo \) |
   sed 's|^\./||' | sort | xargs sha256sum >SHA256SUMS)
say "done:"
sed 's/^/  /' "$OUT/SHA256SUMS" >&2
if ((KEEP_WORK == 0)); then
  rm -rf "$GNUPG_DIR"
  say "logs and downloads are kept in $WORK"
fi
