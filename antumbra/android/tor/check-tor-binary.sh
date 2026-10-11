#!/usr/bin/env bash
# Antumbra: check that a tor binary from build-tor.sh has the expected form.
#
# Usage: check-tor-binary.sh --abi ABI [--api N] [--expect-version V]
#                            [--forbid-string S]... BINARY
#
# Uses readelf from binutils (set READELF to use another one). Checks:
#   - 64-bit little-endian ELF for the ABI's machine, of type DYN (a PIE);
#   - interpreter /system/bin/linker64, so it is an NDK executable;
#   - it needs only bionic's libc.so, libm.so and libdl.so (OpenSSL,
#     libevent and zlib are linked in), with no RPATH or RUNPATH;
#   - no text relocations; BIND_NOW, FLAGS_1 NOW and PIE, and a GNU_RELRO
#     segment (full RELRO);
#   - a non-executable stack and no segment both writable and executable;
#   - the API level in the Android note is at most N (default 34), so the
#     binary loads on that Android version and later;
#   - the tor version string is present, and none of the forbidden strings
#     (for example the build directory) is.
# LOAD segments aligned to less than 16 KiB give a warning only: the phone
# uses 4 KiB pages, but some newer devices and emulator images use 16 KiB.
#
# Prints one line per check and exits 1 if any check fails.
set -Eeuo pipefail
export LC_ALL=C

ABI='' API=34 VERSION='' BIN=''
FORBID=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --abi)            ABI=${2:?}; shift 2 ;;
    --api)            API=${2:?}; shift 2 ;;
    --expect-version) VERSION=${2:?}; shift 2 ;;
    --forbid-string)  FORBID+=("${2:?}"); shift 2 ;;
    -*)               echo "check-tor-binary.sh: unknown option $1" >&2; exit 2 ;;
    *)                BIN=$1; shift ;;
  esac
done
[[ -n $BIN && -f $BIN ]] || { echo "check-tor-binary.sh: no binary given" >&2; exit 2; }
case $ABI in
  arm64-v8a) MACHINE='AArch64' ;;
  x86_64)    MACHINE='X86-64' ;;
  *) echo "check-tor-binary.sh: --abi must be arm64-v8a or x86_64" >&2; exit 2 ;;
esac
READELF=${READELF:-readelf}
command -v "$READELF" >/dev/null 2>&1 || { echo "check-tor-binary.sh: $READELF not found" >&2; exit 2; }

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
warn() { printf '  WARN  %s\n' "$*"; }
check() { # check DESCRIPTION COMMAND...
  local d=$1
  shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}

header=$("$READELF" -hW "$BIN")
segments=$("$READELF" -lW "$BIN")
dynamic=$("$READELF" -dW "$BIN")
notes=$("$READELF" -nW "$BIN")

printf 'check-tor-binary: %s (%s)\n' "$BIN" "$ABI"
if command -v file >/dev/null 2>&1; then
  printf '  file: %s\n' "$(file -b "$BIN")"
fi

check "64-bit little-endian ELF" \
  grep -qE 'Class:[[:space:]]+ELF64' <<<"$header"
grep -qE 'Data:.*little endian' <<<"$header" || fail "little-endian data"
check "machine is $MACHINE" grep -qE "Machine:.*$MACHINE" <<<"$header"
check "type DYN (position-independent executable)" grep -qE 'Type:[[:space:]]+DYN' <<<"$header"
check "interpreter /system/bin/linker64" \
  grep -qF '[Requesting program interpreter: /system/bin/linker64]' <<<"$segments"

needed=$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dynamic" | sort | tr '\n' ' ')
other=$(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dynamic" | grep -vxE 'lib(c|m|dl)\.so' || true)
if [[ -z $other ]]; then
  pass "needs only bionic libraries: $needed"
else
  fail "needs libraries other than libc.so, libm.so and libdl.so: $(tr '\n' ' ' <<<"$other")"
fi
if grep -qE '\((RPATH|RUNPATH)\)' <<<"$dynamic"; then fail "no RPATH or RUNPATH"; else pass "no RPATH or RUNPATH"; fi
if grep -qE '\(TEXTREL\)|TEXTREL' <<<"$dynamic"; then fail "no text relocations"; else pass "no text relocations"; fi
check "BIND_NOW" grep -qE '\(FLAGS\)[[:space:]]+.*BIND_NOW' <<<"$dynamic"
check "FLAGS_1 has NOW and PIE" \
  grep -qE '\(FLAGS_1\)[[:space:]]+Flags:.*NOW.*PIE|\(FLAGS_1\)[[:space:]]+Flags:.*PIE.*NOW' <<<"$dynamic"
check "GNU_RELRO segment (with BIND_NOW: full RELRO)" grep -qE '^[[:space:]]*GNU_RELRO' <<<"$segments"

stack=$(grep -E '^[[:space:]]*GNU_STACK' <<<"$segments" || true)
if [[ -z $stack ]]; then
  fail "GNU_STACK segment present"
elif grep -qE 'RWE|[[:space:]]E[[:space:]]' <<<"$stack"; then
  fail "non-executable stack"
else
  pass "non-executable stack"
fi
if grep -E '^[[:space:]]*LOAD' <<<"$segments" | grep -qE 'RWE'; then
  fail "no LOAD segment is both writable and executable"
else
  pass "no LOAD segment is both writable and executable"
fi
min_align=0
while read -r a; do
  [[ $a =~ ^0x[0-9a-fA-F]+$ ]] || continue
  if ((min_align == 0 || a < min_align)); then min_align=$((a)); fi
done < <(awk '$1 == "LOAD" { print $NF }' <<<"$segments")
if ((min_align >= 16384)); then
  pass "LOAD segments aligned to $min_align bytes (16 KiB page kernels too)"
else
  warn "LOAD segments aligned to $min_align bytes: fine with 4 KiB pages, not with 16 KiB pages"
fi

# The Android note's description starts with the API level, little-endian.
note_api=''
read -r -a note_bytes < <(grep -E 'Android.*NT_VERSION' <<<"$notes" | sed -n 's/.*data:[[:space:]]*//p') || true
if [[ ${#note_bytes[@]} -ge 4 && ${note_bytes[0]} =~ ^[0-9a-f]{2}$ && ${note_bytes[1]} =~ ^[0-9a-f]{2}$ ]]; then
  note_api=$((16#${note_bytes[1]}${note_bytes[0]}))
fi
if [[ -z $note_api ]]; then
  fail "Android note (.note.android.ident) present"
elif ((note_api <= API)); then
  pass "built for API level $note_api (runs on API $API and later)"
else
  fail "built for API level $note_api, newer than the requested $API"
fi

if [[ -n $VERSION ]]; then
  check "contains the tor version string $VERSION" grep -aqF -- "$VERSION" "$BIN"
fi
for s in "${FORBID[@]}"; do
  if grep -aqF -- "$s" "$BIN"; then fail "does not contain '$s'"; else pass "does not contain '$s'"; fi
done

if ((failures > 0)); then
  printf 'check-tor-binary: %d check(s) failed\n' "$failures"
  exit 1
fi
printf 'check-tor-binary: all checks passed\n'
