#!/system/bin/sh
# shellcheck source-path=SCRIPTDIR
# shellcheck disable=SC2016 # awk programs, in single quotes on purpose
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra: PH3's cellular measuring kit (MOD10). Run as root on the phone,
# with the module installed, it prints one report on standard output, safe
# to share as it is: the firewall's counters, NFLOG's refusals by uid and
# interface (when PH3's opt-in loaded them and --listen asks), every
# rmnet interface with the kind of its addresses and its netd network, the
# networks with IMS or EIMS, the IMS registration, the protocol each data
# connection (APN) asked for and was given, the apps with carrier
# privileges (the module's live list for Welcome) counted by kind, and
# Qualcomm netmgrd's nm_mdmprxy rules with the order of the jumps.
#
#   adb push antumbra/android/module/tests/ph3-snapshot.sh /data/local/tmp/
#   adb shell "su -c 'sh /data/local/tmp/ph3-snapshot.sh [--listen SECONDS] [--during-call]'" >ph3-report.txt
#   ph3-snapshot.sh --redact <FILE     (the redaction pass alone, no root)
#
# Options:
#   --listen SECONDS  listen to the firewall's NFLOG group for SECONDS (1 to
#                     600; default 0, not at all), during a registration, a
#                     call or a text. Only when the rules have a group (PH3's
#                     opt-in, /data/adb/antumbra-nflog, at the next start)
#                     and Android's default IPv4 kernel logger is already
#                     nfnetlink_log (listening would set it: see "NFLOG").
#   --during-call     read the phone process's dump (the IMS registration,
#                     the carrier-privilege rules) during a call too: only
#                     for PH3's ordinary call, NEVER during an emergency call.
#   --private-names   add a last section with the package names of the apps
#                     with carrier privileges. That report is NOT for
#                     sharing: a carrier's own app names the carrier, and so
#                     the country. Off by default.
#   --moddir DIR      the installed module (default /data/adb/modules/antumbra)
#   --sys DIR         Android's tools (default /system/bin); the unit tests'
#                     stand-ins
#   --root DIR        read /proc, /sys and /data under DIR (the unit tests)
#   --owner UID       with --root only (the unit tests, run as any user):
#                     the root-only files under DIR (the Phone-mode gate,
#                     the NFLOG opt-in) must belong to UID instead of root;
#                     their mode is checked as on the phone
#
# Read only: it changes nothing on the phone. No iptables change (never -Z:
# the counters stay), no setting, no property, no 'cmd phone', nothing sent
# to Welcome, no radio, APN or IMS change, nothing dialled or texted, no
# file written; nothing that reads the IMEI is asked. It reads iptables -S
# and -L, /sys/class/net, ip -o addr, 'antumbra-fw status', the dumps of
# connectivity, netd, the telephony registry and the phone process, and
# packages.list, the package and role lists ('cmd package list packages',
# 'cmd role get-role-holders'), and picks known fields out of them.
#
# Calls first: the phone process's dump is heavy, so it is read only when
# the telephony registry shows no call and no emergency callback mode
# (each section then says "skipped" and why): never while the call state
# cannot be read or callback mode is on, and during a call only with
# --during-call, which is for PH3's ordinary call alone. Never run the kit
# during an emergency call or in the minutes after one: it cannot tell an
# emergency call from an ordinary one.
#
# Safe to share: every line goes through one redaction pass (ph3_redact, an
# awk program) before it is printed, and without awk there is no report.
# The pass replaces every IPv4 and IPv6 address by its kind and prefix
# length ("[IPv6 global /64]", "[IPv4 private 10/8 /24]"), MAC addresses,
# tel: and sip: URIs, quoted strings (Wi-Fi names), runs of 7 digits or
# more and numbers written in groups ("+1 555-123-4567", "(555) 123-4567",
# "35-209900-176148-1": IMEI, IMSI, ICCID, phone numbers; the report itself
# prints no number that long), the values of identifier, cell and location
# keys (with a suffix too: mMccStr, mOperatorAlphaLongRaw; and an
# identifier or cell key's value after a space: "cid 0x1a2b3c"), MCC and
# MNC labels (ims.mnc260.mcc310...), and decimals with 4 fractional digits
# or more (coordinates). Package names are never printed (they can name the
# carrier), only counted by kind, unless --private-names asks.

PH3_FORMAT=1
PH3_SYS=/system/bin
PH3_ROOT=
PH3_LISTEN=0
PH3_DURING_CALL=0
PH3_NAMES=0
PH3_HOLD=
PH3_OWNER=
PH3_MODDIR=/data/adb/modules/antumbra
PH3_AWK=

# --- The redaction pass -----------------------------------------------------------
#
# Each line, lower-cased for matching only (the same positions), in this
# order: identifier, cell and location keys (their values); URIs; cell
# order: cell identity blocks; identifier, cell and location keys (their
# values), then an identifier or cell key's value after spaces; URIs; MCC
# and MNC labels; quoted strings; MAC addresses; IPv4 then IPv6
# addresses (an IPv4 inside an IPv6 one goes first); numbers in groups;
# long digit runs; long decimals.
# Portable awk (one-true-awk on Android, mawk, gawk, busybox): no interval
# expressions, no IGNORECASE, no bit operations.
PH3_REDACT_AWK='
function hexval(h,   i, c, v) {
	v = 0
	for (i = 1; i <= length(h); i++) {
		c = index("0123456789abcdef", substr(h, i, 1))
		if (c == 0) return -1
		v = v * 16 + c - 1
	}
	return v
}
function v4(t,   a, len, o, n, l) {
	len = ""
	if (index(t, "/")) { len = substr(t, index(t, "/") + 1); t = substr(t, 1, index(t, "/") - 1) }
	n = split(t, o, ".")
	if (n != 4 || o[1] > 255 || o[2] > 255 || o[3] > 255 || o[4] > 255) l = "other"
	else if (t == "0.0.0.0") l = (len == "0") ? "any" : "unspecified"
	else if (o[1] == 127) l = "loopback 127/8"
	else if (o[1] == 10) l = "private 10/8"
	else if (o[1] == 172 && o[2] >= 16 && o[2] <= 31) l = "private 172.16/12"
	else if (o[1] == 192 && o[2] == 168) l = "private 192.168/16"
	else if (o[1] == 169 && o[2] == 254) l = "link-local 169.254/16"
	else if (o[1] == 100 && o[2] >= 64 && o[2] <= 127) l = "shared 100.64/10"
	else if (o[1] == 192 && o[2] == 0 && o[3] == 0) l = "special 192.0.0/24"
	else if (o[1] >= 224 && o[1] <= 239) l = "multicast"
	else if (o[1] == 0 || o[1] >= 240) l = "reserved"
	else l = "global"
	return "[IPv4 " l (len != "" ? " /" len : "") "]"
}
function v6(t,   len, h, h2, l, r) {
	len = ""
	if (index(t, "/")) { len = substr(t, index(t, "/") + 1); t = substr(t, 1, index(t, "/") - 1) }
	if (index(t, "%")) t = substr(t, 1, index(t, "%") - 1)
	if (t == "::") l = (len == "0") ? "any" : "unspecified"
	else if (t == "::1") l = "loopback"
	else if (substr(t, 1, 7) == "::ffff:") l = "v4-mapped"
	else if (substr(t, 1, 1) == ":") l = "other"
	else {
		h = hexval(substr(t, 1, index(t, ":") - 1))
		r = substr(t, index(t, ":") + 1)
		h2 = (index(r, ":") ? hexval(substr(r, 1, index(r, ":") - 1)) : -1)
		if (h >= 65152 && h <= 65215) l = "link-local"
		else if (h >= 64512 && h <= 65023) l = "unique-local"
		else if (h >= 65280 && h <= 65535) l = "multicast"
		else if (h >= 8192 && h <= 16383) l = "global"
		else if (h == 100 && h2 == 65435) l = "nat64"
		else l = "other"
	}
	return "[IPv6 " l (len != "" ? " /" len : "") "]"
}
function digits(r,   n, i, c) {
	n = 0
	for (i = 1; i <= length(r); i++) { c = substr(r, i, 1); if (c >= "0" && c <= "9") n++ }
	return n
}
function fix(kind, r,   i) {
	if (kind == "key") {
		i = match(r, /[=:][ ]*/)
		return substr(r, 1, RSTART + RLENGTH - 1) "[redacted]"
	}
	if (kind == "keysp") {
		i = match(tolower(r), /[a-z][ ]+/)
		return substr(r, 1, RSTART + RLENGTH - 1) "[redacted]"
	}
	if (kind == "plmn") return substr(r, 1, 3) "[redacted]"
	if (kind == "v4") return v4(r)
	if (kind == "v6") return v6(tolower(r))
	if (kind == "grouped") return "[number]"
	return "[" kind "]"
}
function rep(s, re, kind,   out, low, rs, rl, r) {
	out = ""
	while (1) {
		low = tolower(s)
		if (!match(low, re) || RLENGTH <= 0) break
		rs = RSTART
		rl = RLENGTH
		r = substr(s, rs, rl)
		out = out substr(s, 1, rs - 1)
		# A hexadecimal literal (an iptables mark, 0x1000000) is no number to hide.
		if (kind == "number" && rs > 2 && substr(low, rs - 2, 2) == "0x") out = out r
		# Digits in groups: a number only with 7 digits or more and a dash, a
		# parenthesis or a leading plus (an iptables counter pair, "12345 1234K", is none).
		else if (kind == "grouped" && (digits(r) < 7 || !match(r, /[-+(]/))) out = out r
		else out = out fix(kind, r)
		s = substr(s, rs + rl)
	}
	return out s
}
BEGIN {
	keys = "(imei|imeisv|meid|esn|imsi|iccid|iccids|msisdn|mdn|min|eid|cardid|subscriberid|subscriber_id|subid_iccid|line1number|phonenumber|number|callincomingnumber|incomingnumber|voicemailnumber|mcc|mnc|mccmnc|operatornumeric|numeric|plmn|alphalong|alphashort|operatoralphalong|operatoralphashort|spn|gid1|gid2|ci|pci|tac|lac|cid|psc|bsic|nci|eci|cgi|gci|ecgi|ncgi|earfcn|uarfcn|arfcn|nrarfcn|bandwidth|networkid|systemid|basestationid|cellid|cellidentity|latitude|longitude|lat|lon|lng|altitude|accuracy|ssid|bssid|wifissid|macaddress|mac|hwaddr|hwaddress|extra|extrainfo)"
	# A key may carry a suffix of letters (mMccStr, mOperatorAlphaLongRaw).
	re_key = "[^a-z0-9_]m?" keys "[a-z]*[ ]*[=:][ ]*(\"[^\"]*\"|[^ ,;}>)]*)"
	# An identifier or cell key, then its value after spaces ("cid 0x1a2b3c", "imei 35-2099...").
	re_keysp = "[^a-z0-9_](imei|imeisv|meid|imsi|iccid|msisdn|eid|ci|cid|lac|tac|pci|psc|nci|eci|cgi|gci|ecgi|ncgi|cellid)[ ]+(0x[0-9a-f]+|[+]?[0-9][0-9a-f-]*)"
	# MCC and MNC labels, as in an IMS domain (ims.mnc260.mcc310.3gppnetwork.org).
	re_plmn = "(mnc|mcc)[0-9]+"
	# Digits in groups, joined by a space or a dash, maybe in parentheses.
	re_grouped = "[+]?[(]?[0-9]+([)]?[ -][(]?[0-9]+)+[)]?"
	re_uri = "(tel|sip|sips|mailto):[^ ,;>\"]+"
	re_cell = "cell(identity|info)[a-z]*:?[ ]*[{][^}]*[}]"
	re_quote = "\"[^\"]*\""
	re_mac = "[0-9a-f][0-9a-f][:-][0-9a-f][0-9a-f][:-][0-9a-f][0-9a-f][:-][0-9a-f][0-9a-f][:-][0-9a-f][0-9a-f][:-][0-9a-f][0-9a-f]"
	# A MAC address in dotted groups of four (aabb.ccdd.eeff).
	re_mac4 = "[0-9a-f][0-9a-f][0-9a-f][0-9a-f][.][0-9a-f][0-9a-f][0-9a-f][0-9a-f][.][0-9a-f][0-9a-f][0-9a-f][0-9a-f]"
	re_v4 = "[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+(/[0-9]+)?"
	# An IPv6 address begins with a hexadecimal group and a colon, or "::";
	# a port range (dpts:32768:60999) does not.
	re_v6 = "([0-9a-f]+:[0-9a-f]*:|::)[0-9a-f:]*(%[a-z0-9_.-]+)?(/[0-9]+)?"
	re_num = "[+]?[0-9][0-9][0-9][0-9][0-9][0-9][0-9]+"
	re_dec = "[0-9]+[.][0-9][0-9][0-9][0-9]+"
}
{
	s = " " $0
	s = rep(s, re_cell, "cell")
	s = rep(s, re_key, "key")
	s = rep(s, re_keysp, "keysp")
	s = rep(s, re_uri, "uri")
	s = rep(s, re_plmn, "plmn")
	s = rep(s, re_quote, "quoted")
	s = rep(s, re_mac, "mac")
	s = rep(s, re_mac4, "mac")
	s = rep(s, re_v4, "v4")
	s = rep(s, re_v6, "v6")
	s = rep(s, re_grouped, "grouped")
	s = rep(s, re_num, "number")
	s = rep(s, re_dec, "decimal")
	print substr(s, 2)
}
'

# ph3_redact: the pass, standard input to standard output.
ph3_redact() { "$PH3_AWK" "$PH3_REDACT_AWK"; }

# --- NFLOG: a capture's summary -----------------------------------------------------
#
# tcpdump's pcap of an "nflog:GROUP" capture (DLT_NFLOG, 239) as 'od -An -v
# -tx1' prints it, read as a stream, one record at a time. Each record is
# libpcap's netlink payload: struct nfgenmsg (family, version, group), then
# the attributes, their length and type in the host's byte order (the
# pcap's), their values in network order: NFULA_PREFIX (10), NFULA_UID
# (11), NFULA_IFINDEX_INDEV (4) and _OUTDEV (5), NFULA_PAYLOAD (9, the IP
# packet). Prints one line per kind: count, the rule's prefix, the uid, the
# interfaces in and out, the protocol and port, and the kind of the peer
# (the destination going out, the source coming in); never an address.
# -v ifmap="INDEX=NAME ..." names the interfaces.
PH3_NFLOG_AWK='
function hexval(h,   i, c, v) {
	v = 0
	for (i = 1; i <= length(h); i++) {
		c = index("0123456789abcdef", substr(h, i, 1))
		if (c == 0) return -1
		v = v * 16 + c - 1
	}
	return v
}
function u16(o) { return le ? b[o] + 256 * b[o + 1] : 256 * b[o] + b[o + 1] }
function u32(o) { return le ? b[o] + 256 * (b[o + 1] + 256 * (b[o + 2] + 256 * b[o + 3])) : ((b[o] * 256 + b[o + 1]) * 256 + b[o + 2]) * 256 + b[o + 3] }
function be16(o) { return 256 * b[o] + b[o + 1] }
function be32(o) { return ((b[o] * 256 + b[o + 1]) * 256 + b[o + 2]) * 256 + b[o + 3] }
function scope4(o,   a, c) {
	a = b[o]; c = b[o + 1]
	if (a == 127) return "loopback"
	if (a == 10) return "private 10/8"
	if (a == 172 && c >= 16 && c <= 31) return "private 172.16/12"
	if (a == 192 && c == 168) return "private 192.168/16"
	if (a == 169 && c == 254) return "link-local"
	if (a == 100 && c >= 64 && c <= 127) return "shared 100.64/10"
	if (a == 192 && c == 0 && b[o + 2] == 0) return "special 192.0.0/24"
	if (a >= 224 && a <= 239) return "multicast"
	if (a == 255 && c == 255) return "broadcast"
	if (a == 0 || a >= 240) return "reserved"
	return "global"
}
function scope6(o,   h, k, z) {
	h = be16(o)
	if (h >= 65152 && h <= 65215) return "link-local"
	if (h >= 64512 && h <= 65023) return "unique-local"
	if (h >= 65280) return "multicast"
	if (h >= 8192 && h <= 16383) return "global"
	if (h == 100 && be16(o + 2) == 65435) return "nat64"
	z = 1
	for (k = 0; k < 15; k++) if (b[o + k] != 0) z = 0
	if (z) return b[o + 15] == 1 ? "loopback" : (b[o + 15] == 0 ? "unspecified" : "other")
	return "other"
}
function ifname(i) { return (i in ifn) ? ifn[i] : "if" i }
function uidtext(u) { return u >= 100000 ? "user " int(u / 100000) " app " (u % 100000) : u "" }
function pname(p) {
	if (p == 6) return "tcp"
	if (p == 17) return "udp"
	if (p == 132) return "sctp"
	if (p == 1) return "icmp"
	if (p == 58) return "icmpv6"
	if (p == 50) return "esp"
	return "proto " p
}
function record(len,   fam, t, l, ty, k, c, prefix, uid, indev, outdev, pay, pl, proto, port, peer, hl, key) {
	fam = b[0]; t = 4; prefix = "?"; uid = "-"; indev = "-"; outdev = "-"; pay = -1; pl = 0
	while (t + 4 <= len) {
		l = u16(t); ty = u16(t + 2) % 16384
		if (l < 4 || t + l > len) break
		if (ty == 10) {
			prefix = ""
			for (k = t + 4; k < t + l && b[k] != 0; k++) {
				c = b[k]
				if (c < 45 || c > 122) { prefix = "?"; break }
				prefix = prefix sprintf("%c", c)
			}
		} else if (ty == 11 && l >= 8) uid = uidtext(be32(t + 4))
		else if (ty == 4 && l >= 8) indev = ifname(be32(t + 4))
		else if (ty == 5 && l >= 8) outdev = ifname(be32(t + 4))
		else if (ty == 9) { pay = t + 4; pl = l - 4 }
		t += l + (4 - l % 4) % 4
	}
	proto = "?"; port = ""; peer = "?"; hl = -1
	if (pay >= 0 && fam == 2 && pl >= 20) {
		hl = (b[pay] % 16) * 4; proto = b[pay + 9]
		peer = "IPv4 " scope4(outdev != "-" ? pay + 16 : pay + 12)
	} else if (pay >= 0 && fam == 10 && pl >= 40) {
		hl = 40; proto = b[pay + 6]
		peer = "IPv6 " scope6(outdev != "-" ? pay + 24 : pay + 8)
	}
	if (hl >= 0 && (proto == 6 || proto == 17 || proto == 132) && pl >= hl + 4) port = "/" be16(pay + hl + 2)
	else if (hl >= 0 && (proto == 1 || proto == 58) && pl > hl) port = " type " b[pay + hl]
	key = prefix " uid " uid " in " indev " out " outdev " " (proto == "?" ? "?" : pname(proto)) port " peer " peer
	cnt[key]++
	recs++
}
function feed(x) {
	b[m++] = x
	if (state == 0 && m == 24) {
		if (b[0] == 212 && b[1] == 195 && b[2] == 178 && b[3] == 161) le = 1
		else if (b[0] == 77 && b[1] == 60 && b[2] == 178 && b[3] == 161) le = 1
		else if (b[0] == 161 && b[1] == 178 && (b[2] == 195 || b[2] == 60)) le = 0
		else { why = "not a capture"; done = 1; return }
		if (u32(20) != 239) { why = "not an NFLOG capture"; done = 1; return }
		state = 1; m = 0
	} else if (state == 1 && m == 16) {
		need = u32(8); m = 0
		if (need > 262144) { why = "a record too long"; done = 1; return }
		state = (need > 0) ? 2 : 1
	} else if (state == 2 && m == need) {
		record(need); state = 1; m = 0
	}
}
BEGIN {
	n = split(ifmap, pairs, " ")
	for (k = 1; k <= n; k++) if (index(pairs[k], "=")) ifn[substr(pairs[k], 1, index(pairs[k], "=") - 1) + 0] = substr(pairs[k], index(pairs[k], "=") + 1)
}
done { next }
{
	for (i = 1; i <= NF; i++) {
		x = hexval(tolower($i))
		if (x < 0 || x > 255) { why = "not hexadecimal bytes"; done = 1; next }
		feed(x)
		if (done) next
	}
}
END {
	if (why != "") { print "  nothing read: " why; exit }
	if (state == 0) { print "  nothing captured"; exit }
	if (recs == 0) { print "  no packet in the capture"; exit }
	for (k in cnt) printf "  %6d  %s\n", cnt[k], k
}
'

# ph3_nflog_parse IFMAP: PH3_NFLOG_AWK on standard input, the busiest first.
ph3_nflog_parse() { "$PH3_AWK" -v ifmap="$1" "$PH3_NFLOG_AWK" | sort -k1,1nr -k2; }

# --- Reading ------------------------------------------------------------------------

ph3_prop() { "$PH3_SYS/getprop" "$1" 2>/dev/null; }
ph3_read() { read_value "$PH3_ROOT$1"; }
# ph3_dump ARGS...: dumpsys, bounded (10 s for the service, 12 in all).
ph3_dump() { $TB timeout 12 "$PH3_SYS/dumpsys" -t 10 "$@" 2>/dev/null; }
# ph3_phone_dump: the phone process's dump, unless PH3_HOLD says why not
# (ph3_hold: a call, callback mode or a call state that cannot be read).
ph3_phone_dump() {
	[ -z "$PH3_HOLD" ] || return 1
	ph3_dump activity service com.android.phone/com.android.phone.TelephonyDebugService
}

# ph3_hold: set PH3_HOLD to why the phone process may not be dumped now, or
# to nothing. The registry's call states and callback mode (registry_state,
# MOD11's reading): unreadable or callback mode on, never; a call, only
# with --during-call (PH3's ordinary call; never an emergency call).
ph3_hold() {
	PH3_HOLD=
	_ph_r=$(ph3_dump telephony.registry | registry_state) || _ph_r=
	set -f
	# shellcheck disable=SC2086 # three words on purpose
	set -- $_ph_r
	set +f
	if [ $# -ne 3 ]; then
		PH3_HOLD='the call state could not be read'
	elif [ "$2" = 1 ]; then
		PH3_HOLD='emergency callback mode is on'
	elif [ "$1" = 1 ] && [ "$PH3_DURING_CALL" != 1 ]; then
		PH3_HOLD="a call is on; --during-call reads it during PH3's ordinary call, never an emergency call"
	fi
}

# ph3_pm ARGS...: 'cmd package list packages ARGS', the names on one line,
# each followed by a space (nothing when it cannot be read).
ph3_pm() {
	$TB timeout 10 "$PH3_SYS/cmd" package list packages "$@" 2>/dev/null | sed -n 's/^package:\([A-Za-z0-9_.]*\)$/\1/p' | tr '\n' ' '
}

# ph3_role ROLE: the role's holders in user 0, each followed by a space.
ph3_role() {
	$TB timeout 10 "$PH3_SYS/cmd" role get-role-holders --user 0 "$1" 2>/dev/null | tr ';\n' '  ' | tr -s ' '
}

# ph3_kind_lists: the lists ph3_kinds' awk reads (PH3_K_*), once.
ph3_kind_lists() {
	PH3_K_SYS=$(ph3_pm -s)
	PH3_K_THIRD=$(ph3_pm -3 -u)
	PH3_K_SHOWN=$(ph3_pm -3)
	PH3_K_KEEP="$WELCOME_PKG $(ph3_role android.app.role.DIALER) $(ph3_role android.app.role.SMS)"
}

# PH3_KIND_AWK: awk functions that count package names by kind, never
# printing one: kept (Welcome, the default phone or SMS app: WEL9 leaves
# them alone), system (left alone too), installed and hidden (refused, as
# WEL9 refuses), installed and not hidden, unknown (in no list).
PH3_KIND_AWK='
function klist(v, a,   n, x, k) { n = split(v, x, " "); for (k = 1; k <= n; k++) a[x[k]] = 1 }
function kinit() { if (!kdone) { klist(ksys, KS); klist(kthird, KT); klist(kshown, KV); klist(kkeep, KK); kdone = 1 } }
function kind(p) {
	kinit()
	if (p in KK) return "kept"
	if (p in KS) return "system"
	if (p in KV) return "installed, not hidden"
	if (p in KT) return "installed and hidden"
	return "unknown"
}
function kinds(list,   n, x, k, c, o) {
	n = split(list, x, ",")
	c["kept"] = c["system"] = c["installed and hidden"] = c["installed, not hidden"] = c["unknown"] = 0
	for (k = 1; k <= n; k++) c[kind(x[k])]++
	o = n (n == 1 ? " package" : " packages")
	if (n) o = o sprintf(" (system %d; Welcome or the default phone or SMS app %d; installed by the person and hidden %d; installed, not hidden %d; unknown %d)", c["system"], c["kept"], c["installed and hidden"], c["installed, not hidden"], c["unknown"])
	return o
}
'

# ph3_kawk PROGRAM [-v VAR=VALUE...]: awk on standard input with
# PH3_KIND_AWK and its lists.
ph3_kawk() {
	_pk_p=$1
	shift
	"$PH3_AWK" -v ksys="$PH3_K_SYS" -v kthird="$PH3_K_THIRD" -v kshown="$PH3_K_SHOWN" -v kkeep="$PH3_K_KEEP" \
		"$@" "$PH3_KIND_AWK$_pk_p"
}

# ph3_ipt 4|6 ARGS...: iptables or ip6tables, waiting for the lock, bounded.
ph3_ipt() {
	_pi=$PH3_SYS/iptables
	[ "$1" = 4 ] || _pi=$PH3_SYS/ip6tables
	shift
	$TB timeout 15 "$_pi" -w "$@" 2>/dev/null
}
# ph3_fw_status: 'antumbra-fw status' as the module runs it (its root-only
# directory), and nothing else of the firewall.
ph3_fw_status() { ANTUMBRA_DIR=$FWDIR "$BIN/antumbra-fw" status 2>/dev/null; }

# ph3_readonly: the library's functions that change something, made to do
# nothing, so that no call in this kit can (the kit calls none of them).
ph3_readonly() {
	log() { :; }
	write_value() { return 1; }
	prop_set() { return 1; }
	prop_clear() { return 1; }
	settings_put() { return 1; }
	settings_apply() { return 1; }
	mobile_data_off() { return 1; }
	mobile_data_on() { return 1; }
	wifi_off() { return 1; }
	bluetooth_off() { return 1; }
	radios_off_now() { return 1; }
	airplane_set() { return 1; }
	cell_narrow() { return 1; }
	cell_off() { return 1; }
	cell_power() { return 1; }
	cell_reset() { return 1; }
	cell_keys() { return 1; }
	ims_off() { return 1; }
	ims_off_restore() { return 1; }
	ipv6_sweep() { return 1; }
	word_send() { return 1; }
	cell_send() { return 1; }
	priv_send() { return 1; }
	fw() { return 1; }
	fw_publish() { return 1; }
	fw_unpublish() { return 1; }
	start_tor() { return 1; }
	start_dnsfilter() { return 1; }
	runtime_setup() { return 1; }
	make_dir() { return 1; }
	status_write() { return 1; }
}

# ph3_owner_seam: --owner's check, for the unit tests alone (with --root):
# the library's cell_gate_owner_ok with PH3_OWNER for root, the same mode
# check (neither the group nor others may write). On the phone, without
# --owner, the library's own check holds: root's files only.
ph3_owner_seam() {
	cell_gate_owner_ok() {
		_go=$($TB stat -c '%u %a' "$1" 2>/dev/null) || return 1
		case $_go in "$PH3_OWNER "*) ;; *) return 1 ;; esac
		_go=${_go#"$PH3_OWNER "}
		case $_go in '' | *[!0-7]*) return 1 ;; esac
		case $_go in *[2367][0-7] | *[2367]) return 1 ;; esac
		return 0
	}
}

# --- The sections -------------------------------------------------------------------

ph3_phone() {
	echo '## The phone'
	_pp_emu=no
	CELL_EMULATOR=0
	if [ "$(ph3_prop ro.boot.qemu)" = 1 ] || [ "$(ph3_prop ro.kernel.qemu)" = 1 ] ||
		[ "$(ph3_prop ro.hardware)" = ranchu ]; then
		_pp_emu=yes
		CELL_EMULATOR=1
	fi
	echo "android $(ph3_prop ro.build.version.release) (sdk $(ph3_prop ro.build.version.sdk)), build type $(ph3_prop ro.build.type), debuggable $(ph3_prop ro.debuggable), emulator $_pp_emu"
	_pp_v=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)
	echo "module ${_pp_v:-not found}, firewall $(ph3_fw_status | sed -n 's/^state=//p' | head -n 1)"
	_pp_s=$PH3_ROOT$PRIV/session
	echo "Phone-mode gate now: $(cell_gate); the session: $(if [ -f "$_pp_s" ]; then
		grep -E '^(tor_mode|cell|gate)=' "$_pp_s" | tr '\n' ' '
	else echo 'not started'; fi)"
	_pp_g=$(nflog_group)
	echo "PH3's NFLOG opt-in ($PH3_NFLOG_NAME): ${_pp_g:+group }${_pp_g:-none}"
	_pp_u=$(read_value "$PH3_ROOT/proc/uptime")
	_pp_u=${_pp_u%%[. ]*}
	case $_pp_u in '' | *[!0-9]*) _pp_u=0 ;; esac
	echo "up $((_pp_u / 86400)) d $((_pp_u % 86400 / 3600)) h $((_pp_u % 3600 / 60)) min"
	echo "airplane mode: $("$PH3_SYS/settings" get global airplane_mode_on 2>/dev/null)"
	echo "SIM state: $(ph3_prop gsm.sim.state)"
	_pp_r=$(ph3_dump telephony.registry | registry_state) || _pp_r=
	if [ -n "$_pp_r" ]; then
		set -f
		# shellcheck disable=SC2086 # three words on purpose
		set -- $_pp_r
		set +f
		echo "telephony registry: radio $3, a call $([ "$1" = 1 ] && echo now || echo none), callback mode $([ "$2" = 1 ] && echo on || echo off)"
	else
		echo "telephony registry: unreadable"
	fi
	if [ -n "$PH3_HOLD" ]; then
		echo "the phone process's dump: skipped ($PH3_HOLD)"
	else
		echo "the phone process's dump: read"
	fi
}

ph3_counters() {
	echo '## Firewall counters (the ANTUMBRA chains; packets and bytes since the rules were loaded)'
	for _pc_f in 4 6; do
		for _pc_t in raw mangle nat filter; do
			for _pc_c in $(ph3_ipt "$_pc_f" -t "$_pc_t" -S | sed -n 's/^-N \(ANTUMBRA_[A-Z0-9_]*\)$/\1/p'); do
				echo "### IPv$_pc_f $_pc_t $_pc_c"
				ph3_ipt "$_pc_f" -t "$_pc_t" -L "$_pc_c" -v -n | sed 1d
			done
		done
	done
}

ph3_nflog() {
	echo '## NFLOG: what the firewall refused, by uid and interface'
	_pn_g=$(for _pn_f in 4 6; do for _pn_t in mangle nat filter; do ph3_ipt "$_pn_f" -t "$_pn_t" -S; done; done |
		grep '^-A ANTUMBRA_' | sed -n 's/.*--nflog-group \([0-9]*\).*/\1/p' | sort -u | head -n 1)
	if [ -n "$_pn_g" ]; then
		echo "NFLOG rules loaded, group $_pn_g"
	else
		echo "no NFLOG rule loaded: the firewall copies what it refuses to NFLOG only with PH3's opt-in ($PH3_NFLOG_NAME), from the start after it is written"
	fi
	_pn_l=$(read_value "$PH3_ROOT/proc/sys/net/netfilter/nf_log/2")
	if [ "$PH3_LISTEN" = 0 ]; then
		echo "not listened (--listen SECONDS listens)"
	elif [ -z "$_pn_g" ]; then
		echo "not listened: no NFLOG rule"
	elif [ "$_pn_l" != nfnetlink_log ]; then
		echo "not listened: tcpdump would make nfnetlink_log Android's default IPv4 kernel logger (/proc/sys/net/netfilter/nf_log/2 reads ${_pn_l:-nothing}), and this kit changes nothing; to allow it until the next start, as root: echo nfnetlink_log >/proc/sys/net/netfilter/nf_log/2"
	elif [ -r "$PH3_ROOT/proc/net/netfilter/nfnetlink_log" ] &&
		"$PH3_AWK" -v g="$_pn_g" '$1 == g { f = 1 } END { exit !f }' "$PH3_ROOT/proc/net/netfilter/nfnetlink_log"; then
		echo "not listened: group $_pn_g already has a listener"
	elif [ ! -x "$PH3_SYS/tcpdump" ]; then
		echo "not listened: no tcpdump"
	else
		echo "listened for $PH3_LISTEN s (count, rule, uid, in, out, protocol and port, the peer's kind):"
		$TB timeout -s INT "$PH3_LISTEN" "$PH3_SYS/tcpdump" -i "nflog:$_pn_g" -s 256 -U -w - 2>/dev/null |
			$TB od -An -v -tx1 | ph3_nflog_parse "$(ph3_ifmap)"
	fi
}

# ph3_ifmap: "INDEX=NAME ..." for every interface now.
ph3_ifmap() {
	for _pm_d in "$PH3_ROOT"/sys/class/net/*; do
		[ -e "$_pm_d/ifindex" ] || continue
		printf '%s=%s ' "$(read_value "$_pm_d/ifindex")" "${_pm_d##*/}"
	done
}

# ph3_netd: 'dumpsys netd' on standard input; prints its networks, "NETID
# TYPE IF1,IF2" (NetworkController's "Networks:" list).
ph3_netd() {
	"$PH3_AWK" '
		/^ *Networks:$/ { on = 1; next }
		/Interface <-> last network map:/ { on = 0 }
		on && /^ *[0-9]+ [A-Z_]+( [A-Za-z0-9_.,-]+)?$/ { print $1, $2, (NF > 2 ? $3 : "-") }
	'
}

ph3_ifaces() {
	echo '## Interfaces'
	_pf_all=
	for _pf_d in "$PH3_ROOT"/sys/class/net/*; do
		[ -e "$_pf_d" ] || continue
		_pf_all="$_pf_all ${_pf_d##*/} ($(read_value "$_pf_d/operstate"))"
	done
	echo "all:${_pf_all:- none}"
	_pf_net=$(ph3_dump netd | ph3_netd)
	echo "netd's networks: $(printf '%s\n' "$_pf_net" | grep . | tr '\n' ';' | sed 's/;$//; s/;/; /g')"
	_pf_n=0
	for _pf_d in "$PH3_ROOT"/sys/class/net/*rmnet*; do
		[ -e "$_pf_d" ] || continue
		_pf_n=$((_pf_n + 1))
		_pf_i=${_pf_d##*/}
		_pf_w=$(printf '%s\n' "$_pf_net" | "$PH3_AWK" -v i="$_pf_i" '{ n = split($3, a, ","); for (k = 1; k <= n; k++) if (a[k] == i) print $1 " (" $2 ")" }' | tr '\n' ' ')
		echo "$_pf_i: $(read_value "$_pf_d/operstate"), mtu $(read_value "$_pf_d/mtu"), IPv6 disabled $(read_value "$PH3_ROOT/proc/sys/net/ipv6/conf/$_pf_i/disable_ipv6"), netd network ${_pf_w:-none}"
		"$PH3_SYS/ip" -o addr show dev "$_pf_i" 2>/dev/null | "$PH3_AWK" '{
			for (k = 1; k <= NF; k++) if ($k == "inet" || $k == "inet6") {
				s = "?"
				for (j = k + 2; j < NF; j++) if ($j == "scope") s = $(j + 1)
				print "  " $k " " $(k + 1) " scope " s
			}
		}'
	done
	[ "$_pf_n" -gt 0 ] || echo "no rmnet interface"
}

ph3_networks() {
	echo '## Networks (connectivity), IMS and EIMS marked'
	ph3_dump connectivity networks | "$PH3_AWK" '
		/^ *NetworkAgentInfo[{]/ {
			id = "?"; tr = "-"; cap = "-"; ifs = ""
			if (match($0, /network[{][0-9]+[}]/)) id = substr($0, RSTART + 8, RLENGTH - 9)
			if (match($0, /Transports: [A-Z_|]+/)) tr = substr($0, RSTART + 12, RLENGTH - 12)
			if (match($0, /Capabilities: [A-Z_&]+/)) cap = substr($0, RSTART + 14, RLENGTH - 14)
			s = $0
			while (match(s, /InterfaceName: [A-Za-z0-9_.-]+/)) {
				ifs = ifs (ifs == "" ? "" : ",") substr(s, RSTART + 15, RLENGTH - 15)
				s = substr(s, RSTART + RLENGTH)
			}
			c = "&" cap "&"
			mark = ""
			if (index(c, "&IMS&")) mark = mark " IMS"
			if (index(c, "&EIMS&")) mark = mark " EIMS"
			mark = mark (index(c, "&INTERNET&") ? " with INTERNET" : " without INTERNET")
			printf "network %s:%s; transports %s; interfaces %s; capabilities %s\n", id, mark, tr, (ifs == "" ? "none" : ifs), cap
			n++
		}
		END { if (!n) print "no network (or the dump could not be read)" }
	'
}

ph3_ims() {
	echo '## IMS registration (the module'"'"'s reading, read only)'
	if [ -n "$PH3_HOLD" ]; then
		_pi_w="skipped ($PH3_HOLD)"
	else
		_pi_w=$(ph3_phone_dump | ims_state) || _pi_w=unreadable
	fi
	echo "IMS: $_pi_w (cell: over the cell network; wifi: Wi-Fi calling; registered: the bearer not known; none: not registered)"
}

ph3_apns() {
	echo '## Data connections: the protocol each APN asked for and was given'
	ph3_dump telephony.registry | "$PH3_AWK" '
		function after(e, k,   i, r) {
			i = index(e, k)
			if (!i) return "?"
			r = substr(e, i + length(k))
			if (match(r, /[,]/)) r = substr(r, 1, RSTART - 1)
			return r
		}
		/^last known state:/ { on = 1; next }
		/^local logs:/ { on = 0 }
		!on { next }
		/^ *Phone Id=/ { ph = $0; sub(/^ *Phone Id=/, "", ph); next }
		/^ *mPreciseDataConnectionStates=/ {
			m = split($0, parts, " state: ")
			for (k = 2; k <= m; k++) {
				e = parts[k]
				st = e; sub(/,.*/, "", st)
				a = index(e, "APN Setting: ")
				types = "?"; proto = "?"; rproto = "?"
				if (a) {
					r = substr(e, a)
					if (match(r, /, [a-z_]+( [|] [a-z_]+)*, (IP|IPV6|IPV4V6|PPP|NON-IP|UNSTRUCTURED|null), (IP|IPV6|IPV4V6|PPP|NON-IP|UNSTRUCTURED|null), (true|false), /)) {
						x = substr(r, RSTART + 2, RLENGTH - 4)
						n = split(x, f, ", ")
						types = f[1]; proto = f[2]; rproto = f[3]
						gsub(/ [|] /, "+", types)
					}
				}
				ifc = "none"; addrs = ""; v4 = 0; v6 = 0
				l = index(e, "link properties: {")
				if (l) {
					lp = substr(e, l)
					if (match(lp, /InterfaceName: [A-Za-z0-9_.-]+/)) ifc = substr(lp, RSTART + 15, RLENGTH - 15)
					if (match(lp, /LinkAddresses: [[][^]]*[]]/)) {
						addrs = substr(lp, RSTART + 16, RLENGTH - 17)
						gsub(/^ +| +$/, "", addrs)
						na = split(addrs, al, ",")
						for (j = 1; j <= na; j++) { if (index(al[j], ":")) v6++; else if (index(al[j], ".")) v4++ }
					}
				}
				got = (v4 && v6) ? "IPv4 and IPv6" : (v4 ? "IPv4 only" : (v6 ? "IPv6 only" : "no address"))
				printf "phone %s: %s, %s, %s, %s, netId %s: asked %s (roaming %s), given %s; interface %s; addresses %s\n", ph, types, st, after(e, "transport: "), after(e, "network type: "), after(e, "netId: "), proto, rproto, got, ifc, (addrs == "" ? "none" : addrs)
				nc++
			}
		}
		END { if (!nc) print "no data connection listed" }
	'
}

# PH3_CARRIER_AWK: the registry's mCarrierPrivilegeState and
# mCarrierServiceState for each phone. With names=0 (the shared report)
# the packages counted by kind (PH3_KIND_AWK), never named; with names=1
# (--private-names) named. Each uid as its user and app id ("user 10 app
# 10123"), so that none prints as a long number.
PH3_CARRIER_AWK='
function uid(u) { u += 0; return u >= 100000 ? "user " int(u / 100000) " app " (u % 100000) : u "" }
function uids(s,   n, a, k, o) {
	n = split(s, a, ", ")
	o = ""
	for (k = 1; k <= n; k++) o = o (k > 1 ? ", " : "") uid(a[k])
	return o
}
/^last known state:/ { on = 1; next }
/^local logs:/ { on = 0 }
!on { next }
/^ *Phone Id=/ { ph = $0; sub(/^ *Phone Id=/, "", ph); next }
/^ *mCarrierPrivilegeState=<packages=[[].*[]], uids=[[][0-9, ]*[]]>$/ {
	s = $0
	sub(/^ *mCarrierPrivilegeState=<packages=[[]/, "", s)
	u = s
	sub(/[]], uids=[[].*/, "", s)
	sub(/.*[]], uids=[[]/, "", u)
	sub(/[]]>$/, "", u)
	if (names) p = "packages [" s "]"
	else if (s ~ /^[*][*][*], size=[0-9]+$/) { sub(/.*=/, "", s); p = s " packages (names hidden by the build)" }
	else { gsub(/, /, ",", s); p = kinds(s) }
	printf "phone %s: %s, uids [%s]\n", ph, p, uids(u)
	n++
	next
}
/^ *mCarrierPrivilegeState=/ { print "phone " ph ": not in the known form"; n++ }
/^ *mCarrierServiceState=<package=.*, uid=-?[0-9]+>$/ {
	s = $0
	sub(/^ *mCarrierServiceState=<package=/, "", s)
	u = s
	sub(/, uid=.*/, "", s)
	sub(/.*, uid=/, "", u)
	sub(/>$/, "", u)
	if (!names) s = (s == "null" || s == "") ? "none" : kind(s)
	print "phone " ph ", carrier service: " s ", uid " uid(u)
}
END { if (!n) print "no mCarrierPrivilegeState in the registry\047s dump" }
'

# ph3_live_list: the module's live list for Welcome as the module reads it
# (priv_state, priv_list): the names joined by commas, or status 1.
ph3_live_list() {
	_pl_s=$(ph3_dump telephony.registry | priv_state) && printf '%s\n' "$_pl_s" | priv_list
}

ph3_carrier() {
	echo '## Apps with carrier privileges (counted by kind; no package named)'
	ph3_kind_lists
	ph3_dump telephony.registry | ph3_kawk "$PH3_CARRIER_AWK" -v names=0
	if _pc_v=$(ph3_live_list); then
		echo "the module's live list for Welcome: $(ph3_kawk 'BEGIN { print kinds(v) }' -v v="$_pc_v" </dev/null)"
	else
		echo "the module's live list for Welcome: unreadable"
	fi
	if [ -n "$PH3_HOLD" ]; then
		echo "rules by source: skipped ($PH3_HOLD)"
		return 0
	fi
	ph3_phone_dump | "$PH3_AWK" '
		function rules(s,   n) {
			if (s ~ /: null$/) return "none"
			n = 0
			while (match(s, /cert: /)) { n++; s = substr(s, RSTART + RLENGTH) }
			return n
		}
		/CarrierPrivilegesTracker - phoneId: / { ph = $NF }
		/CarrierPrivilegesTracker - SIM-loaded rules: / { sim[ph] = rules($0); seen[ph] = 1 }
		/CarrierPrivilegesTracker - Carrier config rules: / { cc[ph] = rules($0); seen[ph] = 1 }
		/CarrierPrivilegesTracker - Test-override rules: / { to[ph] = rules($0); seen[ph] = 1 }
		/mSimIsReadyButNotLoaded: / { nl[ph] = $NF }
		END {
			for (p in seen) { printf "phone %s, rules by source: the SIM (and an eSIM profile) %s, the carrier configuration %s, test overrides %s; SIM ready but not loaded: %s\n", p, sim[p], cc[p], to[p], nl[p]; k++ }
			if (!k) print "the phone process'"'"'s dump gave no CarrierPrivilegesTracker"
		}
	'
}

ph3_mdm() {
	echo "## Qualcomm netmgrd's nm_mdmprxy rules, and the order of the jumps (FW7)"
	_pd_n=0
	for _pd_f in 4 6; do
		for _pd_t in raw mangle nat filter; do
			_pd_s=$(ph3_ipt "$_pd_f" -t "$_pd_t" -S)
			[ -n "$_pd_s" ] || continue
			_pd_m=$(printf '%s\n' "$_pd_s" | grep nm_mdmprxy)
			if [ -n "$_pd_m" ]; then
				_pd_n=$((_pd_n + 1))
				echo "### IPv$_pd_f $_pd_t: nm_mdmprxy"
				printf '%s\n' "$_pd_m"
				for _pd_c in $(printf '%s\n' "$_pd_m" | sed -n 's/^-N \(nm_mdmprxy[A-Za-z0-9_]*\)$/\1/p'); do
					echo "### IPv$_pd_f $_pd_t $_pd_c (counters)"
					ph3_ipt "$_pd_f" -t "$_pd_t" -L "$_pd_c" -v -n | sed 1d
				done
			fi
			for _pd_c in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
				_pd_j=$(printf '%s\n' "$_pd_s" | sed -n "s/^-A $_pd_c .*-[jg] \\([^ ]*\\).*/\\1/p" | tr '\n' ' ')
				_pd_p=$(printf '%s\n' "$_pd_s" | sed -n "s/^-P $_pd_c //p")
				[ -n "$_pd_j$_pd_p" ] || continue
				echo "IPv$_pd_f $_pd_t $_pd_c (policy ${_pd_p:-none}): ${_pd_j:-no rule}"
			done
		done
	done
	[ "$_pd_n" -gt 0 ] || echo "no nm_mdmprxy rule"
}

# ph3_names: --private-names alone: the package names, in a last section
# marked as not for sharing.
ph3_names() {
	echo '## PRIVATE: package names with carrier privileges (--private-names; NOT FOR SHARING: they can name the carrier, and so the country)'
	ph3_dump telephony.registry | ph3_kawk "$PH3_CARRIER_AWK" -v names=1
	if _pn_v=$(ph3_live_list); then
		echo "the module's live list for Welcome: ${_pn_v:-none}"
	else
		echo "the module's live list for Welcome: unreadable"
	fi
}

# --- Main ---------------------------------------------------------------------------

ph3_main() {
	_redact=0
	while [ $# -gt 0 ]; do
		case $1 in
		--listen | --moddir | --sys | --root | --owner)
			if [ $# -lt 2 ]; then
				echo "ph3-snapshot: $1 needs a value" >&2
				return 64
			fi
			case $1 in
			--listen) PH3_LISTEN=$2 ;;
			--moddir) PH3_MODDIR=$2 ;;
			--sys) PH3_SYS=$2 ;;
			--root) PH3_ROOT=$2 ;;
			--owner) PH3_OWNER=$2 ;;
			esac
			shift 2
			;;
		--redact)
			_redact=1
			shift
			;;
		--during-call)
			PH3_DURING_CALL=1
			shift
			;;
		--private-names)
			PH3_NAMES=1
			shift
			;;
		*)
			echo "ph3-snapshot: unknown option $1" >&2
			return 64
			;;
		esac
	done
	case $PH3_LISTEN in '' | *[!0-9]* | 0?*)
		echo "ph3-snapshot: --listen takes 0 to 600 seconds" >&2
		return 64
		;;
	esac
	case $PH3_OWNER in
	'') ;;
	*[!0-9]* | 0?*)
		echo "ph3-snapshot: --owner takes a uid" >&2
		return 64
		;;
	*)
		if [ -z "$PH3_ROOT" ]; then
			echo "ph3-snapshot: --owner only with --root (the tests)" >&2
			return 64
		fi
		;;
	esac
	if [ "$PH3_LISTEN" -gt 600 ]; then
		echo "ph3-snapshot: --listen takes 0 to 600 seconds" >&2
		return 64
	fi
	PH3_AWK=$PH3_SYS/awk
	[ -x "$PH3_AWK" ] || PH3_AWK=$(command -v awk 2>/dev/null)
	# No awk, no redaction: no report.
	if [ -z "$PH3_AWK" ] || [ "$(echo 'x 10.1.2.3' | ph3_redact 2>/dev/null)" != 'x [IPv4 private 10/8]' ]; then
		echo "ph3-snapshot: no working awk, so nothing could be redacted: no report" >&2
		return 1
	fi
	if [ "$_redact" = 1 ]; then
		ph3_redact
		return
	fi
	if [ -z "$PH3_ROOT" ] && [ "$(id -u 2>/dev/null)" != 0 ]; then
		echo "ph3-snapshot: run it as root (adb shell su -c ...)" >&2
		return 1
	fi
	if [ ! -r "$PH3_MODDIR/lib/antumbra.sh" ]; then
		echo "ph3-snapshot: the module is not installed in $PH3_MODDIR (--moddir)" >&2
		return 1
	fi
	# shellcheck disable=SC2034 # read by lib/antumbra.sh
	MODDIR=$PH3_MODDIR
	# shellcheck source=../lib/antumbra.sh
	. "$MODDIR/lib/antumbra.sh"
	ph3_readonly
	TB=$PH3_SYS/toybox
	[ -z "$PH3_OWNER" ] || ph3_owner_seam
	# The library's root-only files, under --root (the tests).
	CELL_GATE_FILE=$PH3_ROOT$CELL_GATE_FILE
	PH3_NFLOG_NAME=$NFLOG_FILE
	NFLOG_FILE=$PH3_ROOT$NFLOG_FILE
	PKG_LIST=$PH3_ROOT$PKG_LIST
	# Calls first: whether the phone process may be dumped (ph3_hold).
	ph3_hold 2>/dev/null
	{
		echo "# Antumbra PH3 snapshot (MOD10, report format $PH3_FORMAT)"
		if [ "$PH3_NAMES" = 1 ]; then
			echo "# NOT FOR SHARING: --private-names put package names in its last section; they can name the carrier and the country."
		else
			echo "# Every address is replaced by its kind and prefix length; no identifier of the phone, the SIM or the line is in it, and no package name."
		fi
		echo
		ph3_phone
		echo
		ph3_counters
		echo
		ph3_nflog
		echo
		ph3_ifaces
		echo
		ph3_networks
		echo
		ph3_ims
		echo
		ph3_apns
		echo
		ph3_carrier
		echo
		ph3_mdm
		echo
		if [ "$PH3_NAMES" = 1 ]; then
			ph3_names
			echo
		fi
		echo "# end of report"
	} 2>/dev/null | ph3_redact
}

[ "${PH3_LIB:-0}" = 1 ] || ph3_main "$@"
