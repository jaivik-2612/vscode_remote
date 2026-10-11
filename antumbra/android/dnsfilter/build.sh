#!/usr/bin/env bash
# Antumbra: build antumbra-dnsfilter for the phone and the CI emulator.
#
# Builds static Linux executables (CGO_ENABLED=0) for the module's two
# ABIs, which run on Android as they are: no bionic, no linker, no
# libraries. Also builds listc for the build host, for fetch-lists.sh.
#
# Outputs:
#   OUT/arm64-v8a/antumbra-dnsfilter            the phone (OnePlus 7T Pro)
#   OUT/x86_64/antumbra-dnsfilter               the CI emulator
#   OUT/<abi>/antumbra-dnsfilter.buildinfo      Go version, module versions, flags
#                                               (go version -m, with no build path)
#   OUT/host/listc                              list compiler (never shipped)
#   OUT/SHA256SUMS                              checksums of the executables
# The module zip carries OUT/<abi>/antumbra-dnsfilter as bin/<abi>/.
#
# The build is reproducible: the Go toolchain is pinned (the 'toolchain'
# line of go.mod, enforced through GOTOOLCHAIN), the one dependency is
# pinned by go.sum, paths and build IDs are stripped, and nothing depends
# on the time or the build directory. The same commit gives the same bytes.
set -Eeuo pipefail
umask 022
export LC_ALL=C TZ=UTC

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

usage() {
	cat <<'EOF'
Usage: build.sh --out DIR [options]

  --out DIR        where to put the executables
  --abi ABI        arm64-v8a, x86_64 or all (default: all)
  --version V      version string compiled in (default: $ANTUMBRA_VERSION or "dev")
  --test           run go vet and the unit tests first, under the race
                   detector when a C compiler is installed (it needs cgo)
  --fuzz TIME      after the tests, fuzz the query parser (FuzzHandle) and
                   the reply parser (FuzzReply) for TIME each, e.g. 60s;
                   a failing input is written to
                   internal/dnsfilter/testdata/fuzz/ (keep it as a test)
  --check          after building, check the executables: static, the right
                   machine, and the self-test where it can run (natively for
                   x86_64 on an x86_64 host; arm64 under qemu-aarch64 or
                   qemu-aarch64-static if installed)
  --require-selftest
                   with --check: fail when a self-test cannot run here,
                   instead of skipping it (CI: install qemu-user-static)
EOF
}

OUT='' ABIS=all VERSION=${ANTUMBRA_VERSION:-dev} TEST=0 CHECK=0 FUZZ='' REQUIRE_RUN=0
while [ $# -gt 0 ]; do
	case $1 in
	--out) OUT=$2; shift 2 ;;
	--abi) ABIS=$2; shift 2 ;;
	--version) VERSION=$2; shift 2 ;;
	--test) TEST=1; shift ;;
	--check) CHECK=1; shift ;;
	--fuzz) FUZZ=$2; shift 2 ;;
	--require-selftest) REQUIRE_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) echo "build.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
	esac
done
[ -n "$OUT" ] || { usage >&2; exit 2; }
case $ABIS in
all) ABIS="arm64-v8a x86_64" ;;
arm64-v8a | x86_64) ;;
*) echo "build.sh: unknown ABI $ABIS" >&2; exit 2 ;;
esac
case $VERSION in
*[!A-Za-z0-9._+-]* | '') echo "build.sh: version may use only letters, digits and ._+-" >&2; exit 2 ;;
esac
case $FUZZ in
'' | [1-9]*[smh] | [1-9]*x) ;;
*) echo "build.sh: --fuzz takes a time such as 60s (or a count such as 10000x)" >&2; exit 2 ;;
esac

command -v go >/dev/null || { echo "build.sh: go is not installed" >&2; exit 1; }
TOOLCHAIN=$(awk '$1 == "toolchain" { print $2 }' "$HERE/go.mod")
[ -n "$TOOLCHAIN" ] || { echo "build.sh: go.mod has no toolchain line" >&2; exit 1; }
# Exactly this toolchain: the go command downloads it if needed and checks
# it against the Go checksum database.
export GOTOOLCHAIN=$TOOLCHAIN
export GOFLAGS=-mod=readonly
export CGO_ENABLED=0
cd "$HERE"
echo "build.sh: $(go version)"

if [ "$TEST" = 1 ]; then
	go vet ./...
	# The race detector needs cgo, for the tests only: the shipped
	# executables stay CGO_ENABLED=0.
	if command -v "$(go env CC)" >/dev/null 2>&1; then
		CGO_ENABLED=1 go test -race -count=1 ./...
	else
		echo "build.sh: no C compiler ($(go env CC)); tests run without the race detector"
		go test -count=1 ./...
	fi
fi
if [ -n "$FUZZ" ]; then
	# go test -fuzz takes one target per run.
	for target in FuzzHandle FuzzReply; do
		go test -run '^$' -fuzz "^$target\$" -fuzztime "$FUZZ" ./internal/dnsfilter
	done
fi

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
LDFLAGS="-s -w -buildid= -X main.version=$VERSION"

build() { # GOOS GOARCH OUTPUT PACKAGE
	GOOS=$1 GOARCH=$2 go build -trimpath -buildvcs=false -ldflags "$LDFLAGS" -o "$3" "$4"
}

: >"$OUT/SHA256SUMS.new"
for abi in $ABIS; do
	case $abi in
	arm64-v8a) arch=arm64 ;;
	x86_64) arch=amd64 ;;
	esac
	mkdir -p "$OUT/$abi"
	bin=$OUT/$abi/antumbra-dnsfilter
	build linux "$arch" "$bin" ./cmd/antumbra-dnsfilter
	# Run from the output folder, so that the file names no build path.
	(cd "$OUT/$abi" && go version -m antumbra-dnsfilter) >"$bin.buildinfo"
	(cd "$OUT" && sha256sum "$abi/antumbra-dnsfilter") >>"$OUT/SHA256SUMS.new"
	echo "build.sh: $abi: $(stat -c %s "$bin") bytes"
done
mv "$OUT/SHA256SUMS.new" "$OUT/SHA256SUMS"

mkdir -p "$OUT/host"
build "$(go env GOHOSTOS)" "$(go env GOHOSTARCH)" "$OUT/host/listc" ./cmd/listc

if [ "$CHECK" = 1 ]; then
	fail=0 skipped=''
	for abi in $ABIS; do
		bin=$OUT/$abi/antumbra-dnsfilter
		case $abi in
		arm64-v8a) machine=AArch64 qemu=qemu-aarch64 ;;
		x86_64) machine=X86-64 qemu= ;;
		esac
		# The ELF header, read with od: a 64-bit little-endian file for the
		# right machine (e_machine 0xb7 AArch64, 0x3e x86-64).
		hdr=$(od -A n -t x1 -N 20 "$bin" | tr -d ' \n')
		case $hdr in
		7f454c460201*) ;;
		*) echo "build.sh: $abi: not a 64-bit little-endian ELF file" >&2; fail=1; continue ;;
		esac
		case $machine:${hdr:36:4} in
		AArch64:b700 | X86-64:3e00) ;;
		*) echo "build.sh: $abi: wrong machine (e_machine ${hdr:36:4})" >&2; fail=1 ;;
		esac
		# Static: no INTERP or DYNAMIC program header, so neither bionic's
		# linker nor any library is involved.
		if command -v readelf >/dev/null; then
			if readelf -lW "$bin" | grep -Eq '^ *(INTERP|DYNAMIC) '; then
				echo "build.sh: $abi: dynamically linked" >&2
				fail=1
			fi
		elif command -v file >/dev/null; then
			if ! file -b "$bin" | grep -q 'statically linked'; then
				echo "build.sh: $abi: not statically linked" >&2
				fail=1
			fi
		else
			echo "build.sh: $abi: neither readelf nor file is installed; static linking not checked"
		fi
		if [ "$abi" = x86_64 ] && [ "$(uname -m)" = x86_64 ]; then
			"$bin" -version
			"$bin" -self-test || fail=1
		elif [ -n "$qemu" ] && command -v "$qemu" >/dev/null; then
			"$qemu" "$bin" -version
			"$qemu" "$bin" -self-test || fail=1
		elif [ -n "$qemu" ] && command -v "$qemu-static" >/dev/null; then
			"$qemu-static" "$bin" -version
			"$qemu-static" "$bin" -self-test || fail=1
		else
			echo "build.sh: $abi: cannot run here; self-test skipped"
			skipped="$skipped $abi"
		fi
	done
	if [ -n "$skipped" ] && [ "$REQUIRE_RUN" = 1 ]; then
		echo "build.sh: self-test not run for$skipped (--require-selftest)" >&2
		fail=1
	fi
	[ "$fail" = 0 ] || { echo "build.sh: checks FAILED" >&2; exit 1; }
	echo "build.sh: checks passed"
fi
cat "$OUT/SHA256SUMS"
