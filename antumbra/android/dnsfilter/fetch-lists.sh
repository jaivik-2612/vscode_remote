#!/usr/bin/env bash
# Antumbra: download the block-list sources and compile the lists.
#
# Runs in CI (the daily list job and release builds), never on the phone:
# the phone only receives the compiled list. Every remote source named in
# lists/sources.conf is downloaded over HTTPS, with TLS verified, from the
# URL written there; listc then merges, checks and compiles them.
#
# Outputs:
#   OUT/dnsfilter.list   the filter's block list (/data/adb/antumbra/lists/
#                        on the phone, and lists/ in the module zip)
#   OUT/doh-ipv4.txt     DoH server addresses for antumbra-fw (same place)
#   OUT/sources/NAME     each download as it was received (for the record;
#                        not shipped)
#   OUT/SHA256SUMS       checksums of all of the above
#
# The lists change several times a day, so a download cannot be pinned by
# hash in advance. Each download's SHA-256 goes into the compiled list's
# header; --expect NAME=SHA256 makes the script refuse a download that
# differs, to rebuild an earlier list from the same inputs (for example
# with --downloads pointing at an earlier OUT/sources).
set -Eeuo pipefail
umask 022
export LC_ALL=C TZ=UTC

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCES=$HERE/lists/sources.conf

usage() {
	cat <<'EOF'
Usage: fetch-lists.sh --out DIR [options]

  --out DIR          where to write the lists
  --version V        list version (default: the UTC date as YYYYMMDD, from
                     SOURCE_DATE_EPOCH if set)
  --listc PATH       listc to use (default: build it with go)
  --downloads DIR    use the files already in DIR (one per source name)
                     instead of downloading
  --expect NAME=SHA  refuse source NAME unless its SHA-256 is SHA (repeatable)
EOF
}

OUT='' VERSION='' LISTC='' DOWNLOADS='' EXPECT=()
while [ $# -gt 0 ]; do
	case $1 in
	--out) OUT=$2; shift 2 ;;
	--version) VERSION=$2; shift 2 ;;
	--listc) LISTC=$2; shift 2 ;;
	--downloads) DOWNLOADS=$2; shift 2 ;;
	--expect) EXPECT+=("$2"); shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) echo "fetch-lists.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
	esac
done
[ -n "$OUT" ] || { usage >&2; exit 2; }
if [ -z "$VERSION" ]; then
	VERSION=$(date -u -d "@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m%d)
fi
case $VERSION in
*[!A-Za-z0-9._+-]* | '') echo "fetch-lists.sh: version may use only letters, digits and ._+-" >&2; exit 2 ;;
esac

mkdir -p "$OUT/sources"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Remote sources: "NAME URL" for every block record (block NAME FORMAT MIN
# WHERE) and ipv4 record (ipv4 NAME MIN WHERE) whose WHERE is an https URL.
remote=$(awk '
	$1 == "block" && $5 ~ /^https:\/\// { print $2, $5 }
	$1 == "ipv4"  && $4 ~ /^https:\/\// { print $2, $4 }' "$SOURCES")
[ -n "$remote" ] || { echo "fetch-lists.sh: no remote sources in $SOURCES" >&2; exit 1; }

while read -r name url; do
	case $name in
	*[!a-z0-9.-]* | .* | '') echo "fetch-lists.sh: bad source name '$name'" >&2; exit 1 ;;
	esac
	dest=$OUT/sources/$name
	if [ -n "$DOWNLOADS" ]; then
		cp "$DOWNLOADS/$name" "$dest.part"
	else
		echo "fetch-lists.sh: $name <- $url"
		# HTTPS only, also after redirects; TLS 1.2 or later, verified; at
		# most 64 MiB; retried on transient errors.
		curl --proto '=https' --proto-redir '=https' --tlsv1.2 \
			--fail --silent --show-error --location --max-redirs 3 \
			--connect-timeout 20 --max-time 300 --max-filesize 67108864 \
			--retry 3 --retry-delay 10 --retry-all-errors \
			--user-agent 'antumbra-fetch-lists' \
			--output "$dest.part" "$url"
	fi
	sum=$(sha256sum "$dest.part" | cut -d' ' -f1)
	for e in "${EXPECT[@]+"${EXPECT[@]}"}"; do
		if [ "${e%%=*}" = "$name" ] && [ "${e#*=}" != "$sum" ]; then
			echo "fetch-lists.sh: $name: SHA-256 $sum, expected ${e#*=}" >&2
			exit 1
		fi
	done
	mv "$dest.part" "$dest"
	echo "fetch-lists.sh: $name: $(stat -c %s "$dest") bytes, sha256 $sum"
done <<EOF
$remote
EOF

if [ -z "$LISTC" ]; then
	command -v go >/dev/null || { echo "fetch-lists.sh: go is not installed (or give --listc)" >&2; exit 1; }
	TOOLCHAIN=$(awk '$1 == "toolchain" { print $2 }' "$HERE/go.mod")
	(cd "$HERE" && GOTOOLCHAIN=$TOOLCHAIN GOFLAGS=-mod=readonly CGO_ENABLED=0 \
		go build -trimpath -o "$WORK/listc" ./cmd/listc)
	LISTC=$WORK/listc
fi

"$LISTC" -config "$SOURCES" -downloads "$OUT/sources" -version "$VERSION" \
	-o "$OUT/dnsfilter.list" -doh-out "$OUT/doh-ipv4.txt"
"$LISTC" -check "$OUT/dnsfilter.list"
(cd "$OUT" && sha256sum dnsfilter.list doh-ipv4.txt sources/*) >"$OUT/SHA256SUMS"
echo "fetch-lists.sh: done, version $VERSION"
