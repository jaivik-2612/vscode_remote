#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Antumbra Live: the screen and the link. The virtual phone's window is drawn
# on a virtual X display (Xvfb); x11vnc shows that display on 127.0.0.1
# only; websockify, on 127.0.0.1 only, serves the landing page
# (live/index.html), the phone's page (live/phone.html) and noVNC's core,
# and passes a WebSocket to x11vnc only when it carries the session's token
# (TokenFile plugin, token file written by live.py token); a Cloudflare
# quick tunnel (cloudflared, no account) reaches websockify from the
# Internet. Nothing listens on any other address. noVNC's own pages
# (vnc.html and the like) are not served: they take the server's address
# from the link, so a crafted link could send the token elsewhere.
#
#   live-stream.sh start           Xvfb, x11vnc, websockify, the End listener
#                                  and the window fitter
#   live-stream.sh tunnel          cloudflared; then 'link' with its address
#   live-stream.sh link HOST URL [IP]
#                                  the token file for HOST (the password from
#                                  ANTUMBRA_LIVE_PASSWORD), the check through
#                                  URL (at IP, when given) that a wrong or
#                                  missing password gets nothing, the
#                                  session's times and the job summary
#   live-stream.sh close           the link and the screen's servers stopped
#                                  (Xvfb stays: the phone's window is on it)
#   live-stream.sh stop            close, and Xvfb
#   live-stream.sh fit             (in the background, started by 'start')
#                                  moves the phone's window to the top left
#                                  corner and shows only it and its toolbar,
#                                  without the toolbar's x and - (see
#                                  TOOLBAR_TOP), and keeps the emulator's
#                                  Extended Controls hidden
#
# Environment:
#   ANTUMBRA_LIVE_DIR      private directory: logs, pids, the token file
#                          (never uploaded, never printed)
#   ANTUMBRA_LIVE_WEB      the web root the tunnel serves (public)
#   ANTUMBRA_LIVE_MINUTES  the session's length (link; default 60)
#   ANTUMBRA_LIVE_SETUP    minutes allowed for the phone to start (default 20)
#   ANTUMBRA_LIVE_DISPLAY  default :99; ANTUMBRA_LIVE_SCREEN default 1440x1440x24
#   ANTUMBRA_LIVE_PORT     websockify's port (default 6080)
#   ANTUMBRA_LIVE_WINDOW   the phone's window name, an extended regular
#                          expression (default '^Android Emulator')
#   ANTUMBRA_LIVE_NOVNC    noVNC's files (default /usr/share/novnc)
#   ANTUMBRA_LIVE_BUILD    one line about the build, for the summary
#   CLOUDFLARED            the cloudflared binary (tunnel)
#   GITHUB_STEP_SUMMARY, GITHUB_ENV, GITHUB_ACTIONS  on the runner
set -uo pipefail

CI_DIR=$(cd "$(dirname "$0")" && pwd)
LIVE=${ANTUMBRA_LIVE_DIR:?set ANTUMBRA_LIVE_DIR}
WEB=${ANTUMBRA_LIVE_WEB:?set ANTUMBRA_LIVE_WEB}
DISP=${ANTUMBRA_LIVE_DISPLAY:-:99}
SCREEN=${ANTUMBRA_LIVE_SCREEN:-1440x1440x24}
PORT=${ANTUMBRA_LIVE_PORT:-6080}
VNC_PORT=5900
END_PORT=5998
METRICS=127.0.0.1:20241
WINDOW=${ANTUMBRA_LIVE_WINDOW:-^Android Emulator}
NOVNC=${ANTUMBRA_LIVE_NOVNC:-/usr/share/novnc}
LIVEPY=(python3 -B -I "$CI_DIR/live.py")
PIDS=$LIVE/pids

say() { printf '[live %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() {
	say "$*"
	exit 1
}

# summary LINE...: the job summary on the runner, else standard output.
summary() {
	if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
		printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
	else
		printf '%s\n' "$@"
	fi
}

# start_bg NAME LOG COMMAND...: in a session of its own (it outlives the
# step), its output in LOG, its pid in $PIDS/NAME, and never with the
# password in its environment.
start_bg() {
	local name=$1 log=$2
	shift 2
	setsid env -u ANTUMBRA_LIVE_PASSWORD "$@" </dev/null >>"$log" 2>&1 &
	echo $! >"$PIDS/$name"
}

running() {
	local pid
	pid=$(cat "$PIDS/$1" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

stop_one() {
	local pid
	pid=$(cat "$PIDS/$1" 2>/dev/null) || return 0
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill -TERM "$pid" 2>/dev/null
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.5
		done
		kill -KILL "$pid" 2>/dev/null
		say "stopped $1"
	fi
	rm -f "$PIDS/$1"
}

# wait_port PORT SECONDS: something listens on PORT (ss: without connecting,
# so that x11vnc's log counts only real clients).
wait_port() {
	local end=$((SECONDS + $2))
	while [ $SECONDS -lt "$end" ]; do
		[ -n "$(ss -Hltn "sport = :$1" 2>/dev/null)" ] && return 0
		sleep 0.5
	done
	return 1
}

# loopback_only PORT: every socket listening on PORT is bound to 127.0.0.1.
loopback_only() {
	local socks
	socks=$(ss -Hltn "sport = :$1" 2>/dev/null | awk '{ print $4 }')
	[ -n "$socks" ] || return 1
	! printf '%s\n' "$socks" | grep -v -q -x "127.0.0.1:$1"
}

cmd_start() {
	local tool
	for tool in Xvfb x11vnc websockify xdotool xwininfo xdpyinfo; do
		command -v "$tool" >/dev/null || die "$tool is needed (apt: xvfb x11vnc websockify novnc xdotool x11-utils)"
	done
	if [ ! -f "$NOVNC/core/rfb.js" ] || [ ! -d "$NOVNC/vendor/pako" ]; then die "no noVNC at $NOVNC (apt: novnc)"; fi
	mkdir -p "$LIVE" "$PIDS" "$WEB"
	chmod 700 "$LIVE"
	# The web root: the two pages and noVNC's core (and the zlib it
	# imports), nothing else; not noVNC's vnc.html, vnc_lite.html or app/.
	rm -rf "${WEB:?}/core" "${WEB:?}/vendor"
	cp -RL "$NOVNC/core" "$NOVNC/vendor" "$WEB/"
	cp "$CI_DIR/live/index.html" "$WEB/index.html"
	cp "$CI_DIR/live/phone.html" "$WEB/phone.html"
	# No token yet: websockify refuses every WebSocket until 'link'.
	: >"$LIVE/tokens"
	chmod 600 "$LIVE/tokens"

	start_bg xvfb "$LIVE/xvfb.log" Xvfb "$DISP" -screen 0 "$SCREEN" -nolisten tcp -noreset
	for _ in $(seq 1 40); do
		xdpyinfo -display "$DISP" >/dev/null 2>&1 && break
		sleep 0.5
	done
	xdpyinfo -display "$DISP" >/dev/null 2>&1 || die "Xvfb did not start on $DISP"
	# A word on the screen until the phone's window comes.
	if command -v xmessage >/dev/null; then
		start_bg message /dev/null env DISPLAY="$DISP" xmessage -center -buttons '' \
			'The virtual phone is starting. This takes about 10 minutes.'
	fi

	start_bg x11vnc "$LIVE/x11vnc.log" x11vnc -display "$DISP" -localhost -listen 127.0.0.1 -rfbport "$VNC_PORT" \
		-noipv6 -forever -shared -nopw -xkb -noxrecord -nowf -noscr
	wait_port "$VNC_PORT" 30 || die "x11vnc did not start (its log is private)"
	loopback_only "$VNC_PORT" || die "x11vnc listens on more than 127.0.0.1:$VNC_PORT: stopped"

	start_bg end "$LIVE/end-listener.log" "${LIVEPY[@]}" end-listener --port "$END_PORT" --flag "$LIVE/end-requested"
	# websockify's log holds the WebSocket paths, tokens included: private.
	# The web root holds only public files (noVNC, the page, session.json),
	# so its directory listings show nothing private.
	start_bg websockify "$LIVE/websockify.log" websockify --web "$WEB" --heartbeat 30 \
		--token-plugin TokenFile --token-source "$LIVE/tokens" "127.0.0.1:$PORT"
	wait_port "$PORT" 30 || die "websockify did not start"
	loopback_only "$PORT" || die "websockify listens on more than 127.0.0.1:$PORT: stopped"
	wait_port "$END_PORT" 15 || die "the End listener did not start"
	loopback_only "$END_PORT" || die "the End listener listens on more than 127.0.0.1:$END_PORT: stopped"

	start_bg fit "$LIVE/fit.log" bash "$0" fit
	if [ -n "${GITHUB_ENV:-}" ]; then echo "DISPLAY=$DISP" >>"$GITHUB_ENV"; fi
	say "the screen ($DISP, $SCREEN), x11vnc on 127.0.0.1:$VNC_PORT, websockify on 127.0.0.1:$PORT"
}

# viewable_windows: the top-level windows that are on the screen, one per
# line: ID X Y WIDTH HEIGHT NAME.
viewable_windows() {
	local id
	for id in $(xwininfo -display "$DISP" -root -children 2>/dev/null | awk '$1 ~ /^0x/ { print $1 }'); do
		xwininfo -display "$DISP" -id "$id" 2>/dev/null | awk -v id="$id" '
			/^xwininfo: Window id:/ { n = $0; sub(/^[^"]*"/, "", n); sub(/"[^"]*$/, "", n); if (n == $0) n = "" }
			/Absolute upper-left X:/ { x = $NF } /Absolute upper-left Y:/ { y = $NF }
			/^ *Width:/ { w = $NF } /^ *Height:/ { h = $NF } /Map State: IsViewable/ { v = 1 }
			END { if (v && w > 8 && h > 8) print id, x, y, w, h, n }'
	done
}

# The emulator's toolbar starts with a row of two buttons, x and -: x
# switches the virtual phone off at once (no question; the session then
# ends and the phone's own recording is lost), - hides the toolbar. The
# fitter keeps that row out of what is shown: the phone's window goes to
# 0,TOOLBAR_TOP, its toolbar to the same height minus TOOLBAR_TOP, and the
# view starts at TOOLBAR_TOP. (Checked with emulator 16428233 on Xvfb: the
# row is the toolbar's top 15 pixels, its first other button starts below
# 24, and a toolbar moved by hand stays where it is put until the phone is
# rotated, when the emulator puts it back beside the phone.)
TOOLBAR_TOP=24

# name_of LINE: the NAME field of a viewable_windows line.
name_of() { printf '%s\n' "$1" | cut -d ' ' -f 6-; }

# fit_pass: one pass of the fitter. Hides the emulator's Extended Controls
# (the toolbar's More button opens them at 0,0, over the phone and the
# toolbar; with no window manager they could not be closed or moved), moves
# the phone's window and its toolbar as above, and prints WxH+0+TOP, the
# smallest rectangle that holds every window still on the screen (the phone
# and its toolbar) from TOOLBAR_TOP down. The phone's window is the one
# named like WINDOW, else the largest one (a name the emulator might
# change); the toolbar is the window named Emulator, else the one just to
# the phone's right. The starting message goes once the phone is there.
fit_pass() {
	local wins line id x y name main='' mx my mw tool='' tx ty moved=0 sw sh
	wins=$(viewable_windows)
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		name=$(name_of "$line")
		case $name in
		'Extended Controls'*)
			id=${line%% *}
			xdotool windowunmap "$id" >/dev/null 2>&1 && say "hid the emulator's Extended Controls (More)"
			moved=1
			;;
		esac
	done <<<"$wins"
	[ "$moved" = 0 ] || wins=$(viewable_windows)
	moved=0
	main=$(printf '%s\n' "$wins" | awk -v re="$WINDOW" '{ n = $0; sub(/^([^ ]+ ){5}/, "", n) } n ~ re { print $1; exit }')
	if [ -z "$main" ]; then
		main=$(printf '%s\n' "$wins" | awk 'NF >= 5 && $6 != "xmessage" && $4 * $5 > a { a = $4 * $5; m = $1 } END { print m }')
	fi
	[ -n "$main" ] || return 1
	stop_one message
	read -r _ mx my mw _ < <(printf '%s\n' "$wins" | awk -v m="$main" '$1 == m')
	if [ "$mx,$my" != "0,$TOOLBAR_TOP" ]; then
		xdotool windowmove "$main" 0 "$TOOLBAR_TOP" >/dev/null 2>&1
		xdotool windowfocus "$main" >/dev/null 2>&1
		moved=1
	fi
	[ "$moved" = 0 ] || { sleep 1; wins=$(viewable_windows); }
	read -r _ mx my mw _ < <(printf '%s\n' "$wins" | awk -v m="$main" '$1 == m')
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		read -r id x y _ <<<"$line"
		name=$(name_of "$line")
		if [ "$id" = "$main" ] || [ "$name" = xmessage ]; then continue; fi
		if [ "$name" = Emulator ] || { [ "$x" -ge $((mx + mw - 8)) ] && [ "$x" -le $((mx + mw + 8)) ]; }; then
			tool=$id tx=$x ty=$y
			break
		fi
	done <<<"$wins"
	if [ -n "$tool" ] && [ "$ty" != $((my - TOOLBAR_TOP)) ]; then
		xdotool windowmove "$tool" "$tx" $((my - TOOLBAR_TOP)) >/dev/null 2>&1
		sleep 0.5
		wins=$(viewable_windows)
	fi
	read -r sw sh < <(xdpyinfo -display "$DISP" 2>/dev/null | awk '/dimensions:/ { split($2, d, "x"); print d[1], d[2]; exit }')
	printf '%s\n' "$wins" | awk -v sw="${sw:-0}" -v sh="${sh:-0}" -v top="$TOOLBAR_TOP" '
		{ n = $0; sub(/^([^ ]+ ){5}/, "", n) }
		NF >= 5 && n != "xmessage" && n !~ /^Extended Controls/ {
			r = $2 + $4; b = $3 + $5; if (r > mx) mx = r; if (b > my) my = b
		}
		END {
			if (mx > sw) mx = sw; if (my > sh) my = sh
			if (mx < 16 || my - top < 16) exit 1
			printf "%dx%d+0+%d\n", mx, my - top, top
		}'
}

cmd_fit() {
	local last='' geo
	export DISPLAY="$DISP"
	while :; do
		if geo=$(fit_pass) && [ -n "$geo" ] && [ "$geo" != "$last" ]; then
			if x11vnc -display "$DISP" -sync -R "clip:$geo" >/dev/null 2>&1; then
				say "shown: $geo"
				last=$geo
			fi
		fi
		sleep 1
	done
}

cmd_link() {
	local host=$1 url=$2 ip=${3:-} minutes setup t0 end probe_rc
	minutes=$("${LIVEPY[@]}" minutes "${ANTUMBRA_LIVE_MINUTES:-60}")
	setup=${ANTUMBRA_LIVE_SETUP:-20}
	# The token file; on the runner the tokens are masked in every log.
	"${LIVEPY[@]}" token --host "$host" --tokens "$LIVE/tokens" ${GITHUB_ACTIONS:+--mask} ||
		die "no token file: the password secret is missing or too short"
	# Nothing after this needs the password itself.
	unset ANTUMBRA_LIVE_PASSWORD
	# Through the link: it reaches this web server; a stranger (no password,
	# a wrong one) gets nothing; the owner gets the screen.
	"${LIVEPY[@]}" probe --url "$url" --tokens "$LIVE/tokens" --web "$WEB" --vnc-log "$LIVE/x11vnc.log" \
		${ip:+--ip "$ip"} >"$LIVE/probe.txt" 2>&1
	probe_rc=$?
	sed 's/^/[live] /' "$LIVE/probe.txt" >&2
	case $probe_rc in
	0 | 1) ;;
	2)
		cmd_close
		summary "## Antumbra Live: stopped" "" \
			"A connection without the right password reached the screen in the check before the session, so the link was closed again and the session does not start." \
			"" "$(sed 's/^/- /' "$LIVE/probe.txt")"
		die "a stranger got through: the link is closed"
		;;
	*)
		cmd_close
		summary "## Antumbra Live: stopped" "" \
			"The link could not be checked from GitHub's side: it did not answer, so it could not be shown that a missing or wrong password gets nothing. The link was closed again and the session does not start. Start Antumbra Live again; Cloudflare's quick tunnels sometimes take a while." \
			"" "$(sed 's/^/- /' "$LIVE/probe.txt")"
		die "the link could not be checked: it is closed"
		;;
	esac
	t0=$(date +%s)
	end=$((t0 + (setup + minutes) * 60))
	"${LIVEPY[@]}" state --web "$WEB" --start "$t0" --end "$end" --minutes "$minutes" --set state=starting
	echo "$end" >"$LIVE/end-epoch"
	if [ -n "${GITHUB_ENV:-}" ]; then echo "ANTUMBRA_LIVE_END=$end" >>"$GITHUB_ENV"; fi
	local hm_t0 hm_end check
	hm_t0=$(date -u -d "@$t0" '+%Y-%m-%d %H:%M UTC')
	hm_end=$(date -u -d "@$end" '+%H:%M UTC')
	# Only what the check saw (the probe's lines start with "ok:" for a
	# step that held).
	check="Checked through the link just now: no password, refused; a wrong password, refused; x11vnc saw no client from either."
	if [ "$probe_rc" = 0 ]; then
		check="$check The right password got the screen."
	else
		check="$check The right password did not get the screen yet from GitHub's side ($(tail -n 1 "$LIVE/probe.txt")). If the page says the password is wrong, wait a minute and try again."
	fi
	summary "## Antumbra Live" "" \
		"**Open $url in Safari** on your iPhone or iPad, and type your password (the secret ANTUMBRA_LIVE_PASSWORD)." "" \
		"- Link up: $hm_t0. The phone is ready about 10 minutes later; the page says when." \
		"- **The session ends by itself at $hm_end** ($minutes minutes, plus $setup for the phone to start). To end it earlier: *End the session now* on the page, or cancel this run." \
		"- ${ANTUMBRA_LIVE_BUILD:-The build: the newest successful Antumbra Android run.}" \
		"- $check" "" \
		"Then: turn *Administration* on in Welcome (to install apps) and press *Start Antumbra*. F-Droid and Aptoide should be in the app drawer once Tor is connected; if one is missing, the page says why." "" \
		"This is a virtual phone on GitHub's computer. GitHub's machine and Cloudflare carry the screen: never sign in to real accounts, and never type real passwords or personal details in it. The privacy check of the session is added to this summary when it ends."
	say "the session ends at $hm_end"
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		echo "::notice title=Antumbra Live::Open $url in Safari and type your password. The session ends at $hm_end."
	fi
	# The last line of the step's log, with nothing after the link: easy to
	# find and tap in the GitHub app while the run's summary is still empty.
	printf 'the link: %s\n' "$url"
}

cmd_tunnel() {
	local url="" doh=() ip=
	[ -x "${CLOUDFLARED:-}" ] || die "set CLOUDFLARED to the cloudflared binary"
	running websockify || die "websockify is not running ('start' first)"
	# cloudflared's log names the quick tunnel's address; it stays private
	# all the same.
	start_bg cloudflared "$LIVE/cloudflared.log" "$CLOUDFLARED" tunnel --no-autoupdate --metrics "$METRICS" \
		--url "http://127.0.0.1:$PORT"
	for _ in $(seq 1 90); do
		url=$(grep -o -E 'https://[a-z0-9-]+\.trycloudflare\.com' "$LIVE/cloudflared.log" 2>/dev/null |
			grep -v -x 'https://api\.trycloudflare\.com' | head -n 1)
		[ -n "$url" ] && break
		running cloudflared || break
		sleep 1
	done
	if [ -z "$url" ]; then
		summary "## Antumbra Live: no link" "" "Cloudflare's quick tunnel did not start, so there is no link to the phone. Start the run again later."
		cmd_close
		die "no quick tunnel"
	fi
	for _ in $(seq 1 60); do
		curl -fsS -o /dev/null --max-time 5 "http://$METRICS/ready" 2>/dev/null && break
		sleep 1
	done
	# The new name through Cloudflare's resolver first (1.1.1.1, over HTTPS),
	# so that the runner's own resolver does not keep an early "no such
	# name".
	curl --help all 2>/dev/null | grep -q -- '--doh-url' && doh=(--doh-url https://1.1.1.1/dns-query)
	# The address that answered goes to the check, so that it does not
	# depend on the runner's resolver either.
	for _ in $(seq 1 30); do
		ip=$(curl -fsS -o /dev/null -w '%{remote_ip}' --max-time 10 "${doh[@]}" "$url/" 2>/dev/null) && break
		ip=
		sleep 2
	done
	cmd_link "${url#https://}" "$url" "$ip"
}

cmd_close() {
	local n
	for n in cloudflared websockify x11vnc end fit message; do stop_one "$n"; done
	: >"$LIVE/tokens" 2>/dev/null
	return 0
}

cmd_stop() {
	cmd_close
	stop_one xvfb
}

case ${1:-} in
start) cmd_start ;;
tunnel) cmd_tunnel ;;
link)
	[ $# -eq 3 ] || [ $# -eq 4 ] || die "usage: live-stream.sh link HOST URL [IP]"
	cmd_link "$2" "$3" "${4:-}"
	;;
close) cmd_close ;;
stop) cmd_stop ;;
fit) cmd_fit ;;
*) die "usage: live-stream.sh start|tunnel|link HOST URL [IP]|close|stop" ;;
esac
