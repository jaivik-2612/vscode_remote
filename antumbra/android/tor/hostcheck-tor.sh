#!/usr/bin/env bash
# Antumbra: run a static x86_64 tor on this Linux host and check that it
# accepts Antumbra's torrc and behaves the way the module expects.
#
# Usage: hostcheck-tor.sh [--expect-version V] [--expect-library S]...
#                         [--require-runtime] TOR
#
# TOR is the static, non-PIE x86_64 copy that build-tor.sh links from the
# same objects as the shipped binary (the shipped one needs Android's
# /system/bin/linker64 and cannot run here). The runtime part runs in a
# network namespace with only a loopback interface, so nothing can leave
# this host even while tor's network is enabled.
#
# Always (any user):
#   1. 'tor --version' and '--library-versions' name the expected versions.
#   2. 'tor --verify-config' accepts torrc.in rendered for /data/adb/antumbra.
# As root, when unshare, setpriv, ip, iptables and python3 are available
# (otherwise skipped, or a failure with --require-runtime), in new mount and
# network namespaces (loopback only, no route out) on a tmpfs laid out as
# the torrc header says:
#   3. tor starts as uid/gid 2950 with no capabilities and no new privileges.
#   4. The control socket is mode 0660, owned by 2950:2950; the cookie is
#      0600. Commands before AUTHENTICATE are refused, and cookie
#      authentication works. DisableNetwork is 1 and tor has no TCP or UDP
#      listener at all.
#   5. After 'SETCONF DisableNetwork=0' (as the module does after the
#      Welcome screen) the only listeners are TCP 127.0.0.1:9040 and UDP
#      127.0.0.1:9053. The DNSPort maps a .onion name into 10.192.0.0/10,
#      and a TCP connection to that address, redirected by an iptables nat
#      rule as the firewall will do, arrives at TransPort as a stream to the
#      .onion name (so SO_ORIGINAL_DST works in this build). tor's own
#      connection attempts fail at once: the namespace has no route out.
#   6. After 'SETCONF DisableNetwork=1' the listeners close again; setting
#      and clearing a bridge over the control socket works.
#   7. uid 2951 (the DNS filter) cannot connect to the control socket or
#      read the cookie, but can read run/status.json.
#   8. 'SIGNAL SHUTDOWN' stops tor with exit status 0; the log has no [err].
set -Eeuo pipefail
export LC_ALL=C

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# A v3 onion address used only as a name to map (the Tor Project's).
ONION=2gzyxa5ihm7nsggfxnu52rck2vv4rvmdlkiu3zzui5du4xyclen53wid.onion

# Control-socket client for the runtime checks, written to the test tmpfs.
CTL_PY=$(cat <<'EOF'
import os, select, socket, struct, sys, time

def say(ok, msg):
    print(('  PASS  ' if ok else '  FAIL  ') + msg, flush=True)
    return 0 if ok else 1

def connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    return s, s.makefile('rwb', buffering=0)

EVENTS = []

def read_events(f, sock, seconds, match):
    """Collect asynchronous 650 events for up to SECONDS or until MATCH is seen."""
    end = time.time() + seconds
    while time.time() < end:
        # select() first: a timeout inside readline() would break the file.
        ready, _, _ = select.select([sock], [], [], max(0.0, end - time.time()))
        if not ready:
            break
        raw = f.readline()
        if not raw:
            break
        l = raw.decode('utf-8', 'replace').rstrip('\r\n')
        if l.startswith('650'):
            EVENTS.append(l)
            if match in l:
                break

def cmd(f, line):
    f.write(line.encode() + b'\r\n')
    out = []
    while True:
        raw = f.readline()
        if not raw:
            out.append('<connection closed>')
            return out
        l = raw.decode('utf-8', 'replace').rstrip('\r\n')
        if l.startswith('650'):
            EVENTS.append(l)
            if len(l) >= 4 and l[3] == '+':
                while f.readline().decode('utf-8', 'replace').rstrip('\r\n') != '.':
                    pass
            continue
        out.append(l)
        if len(l) >= 4 and l[3] == '+':
            while True:
                d = f.readline().decode('utf-8', 'replace').rstrip('\r\n')
                if d == '.':
                    break
                out.append(d)
            continue
        if len(l) >= 4 and l[3] == ' ':
            return out

def value(lines, key):
    for l in lines:
        if l[4:].startswith(key + '='):
            return l[4 + len(key) + 1:]
    return None

def dns_query(name, port):
    q = struct.pack('>HHHHHH', 0x4242, 0x0100, 1, 0, 0, 0)
    for label in name.split('.'):
        q += bytes([len(label)]) + label.encode()
    q += b'\x00' + struct.pack('>HH', 1, 1)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.settimeout(5)
    u.sendto(q, ('127.0.0.1', port))
    r, _ = u.recvfrom(512)
    an = struct.unpack('>H', r[6:8])[0]
    if an < 1 or len(r) < len(q) + 16:
        return None
    return socket.inet_ntoa(r[-4:])

def listening():
    """TCP and UDP sockets bound in this network namespace, from /proc/net."""
    found = set()
    for proto, want in (('tcp', '0A'), ('tcp6', '0A'), ('udp', '07'), ('udp6', '07')):
        try:
            rows = open('/proc/net/' + proto).read().splitlines()[1:]
        except OSError:
            continue
        for row in rows:
            f = row.split()
            if f[3] != want:
                continue
            host, port = f[1].split(':')
            if len(host) == 8:
                ip = socket.inet_ntoa(bytes.fromhex(host)[::-1])
            else:
                ip = '[%s]' % host
            found.add('%s %s:%d' % (proto, ip, int(port, 16)))
    return found

def wait_listening(expected, seconds=10):
    end = time.time() + seconds
    while True:
        now = listening()
        if now == expected or time.time() > end:
            return now
        time.sleep(0.2)

def session(sock, cookie_path, version, onion):
    bad = 0
    # Commands other than PROTOCOLINFO and AUTHENTICATE need authentication.
    s, f = connect(sock)
    info = cmd(f, 'PROTOCOLINFO 1')
    methods = ' '.join(info)
    bad += say('METHODS=COOKIE,SAFECOOKIE' in methods and 'NULL' not in methods
               and 'HASHEDPASSWORD' not in methods,
               'control socket offers cookie authentication only: '
               + next((l for l in info if 'METHODS=' in l), '?')[4:])
    r = cmd(f, 'GETINFO version')
    bad += say(r[0].startswith('514'), 'commands before AUTHENTICATE are refused: ' + r[0])
    s.close()

    s, f = connect(sock)
    cookie = open(cookie_path, 'rb').read()
    r = cmd(f, 'AUTHENTICATE ' + cookie.hex())
    bad += say(r == ['250 OK'], 'cookie authentication: ' + ' '.join(r))
    v = value(cmd(f, 'GETINFO version'), 'version') or ''
    bad += say(v.startswith(version), 'GETINFO version: ' + v)
    r = cmd(f, 'GETCONF DisableNetwork')
    bad += say(r == ['250 DisableNetwork=1'], 'network disabled at start: ' + ' '.join(r))
    now = wait_listening(set(), 2)
    bad += say(now == set(), 'with DisableNetwork 1 tor has no TCP or UDP listener at all: %s'
               % (sorted(now) or 'none'))

    # Turn the network on, as the module does after the Welcome screen. This
    # namespace has only loopback and no route out, so tor's own connection
    # attempts fail at once and nothing leaves the host.
    r = cmd(f, 'SETCONF DisableNetwork=0')
    bad += say(r == ['250 OK'], 'SETCONF DisableNetwork=0: ' + ' '.join(r))
    want = {'tcp 127.0.0.1:9040', 'udp 127.0.0.1:9053'}
    now = wait_listening(want)
    bad += say(now == want, 'with the network on, the only listeners are %s' % sorted(now))
    lst = {}
    for kind in ('socks', 'trans', 'dns', 'control', 'natd', 'httptunnel', 'extor', 'or', 'dir'):
        lst[kind] = value(cmd(f, 'GETINFO net/listeners/' + kind), 'net/listeners/' + kind)
    bad += say(lst['trans'] == '"127.0.0.1:9040"', 'TransPort listener: %s' % lst['trans'])
    bad += say(lst['dns'] == '"127.0.0.1:9053"', 'DNSPort listener: %s' % lst['dns'])
    bad += say((lst['control'] or '').startswith('"unix:') and lst['control'].endswith('/run/tor-control.sock"'),
               'control listener is the Unix socket only: %s' % lst['control'])
    others = {k: v for k, v in lst.items() if k not in ('trans', 'dns', 'control') and v}
    bad += say(not others, 'no SOCKS, NATD, HTTP tunnel, ExtOR, OR or Dir listener'
               + ('' if not others else ': %r' % others))

    # DNSPort automapping, and TransPort behind a netfilter redirect.
    try:
        addr = dns_query(onion, 9053)
    except Exception as e:
        addr = None
        print('        DNS query failed: %r' % (e,))
    mapped = addr is not None and addr.startswith('10.') and 192 <= int(addr.split('.')[1]) <= 255
    bad += say(mapped, 'DNSPort maps %s... to %s (inside 10.192.0.0/10)' % (onion[:16], addr))
    try:
        t = socket.create_connection(('127.0.0.1', 9053), timeout=2)
        t.close()
        print('  INFO  DNSPort also accepts TCP')
    except OSError:
        print('  INFO  DNSPort answers over UDP only (TCP 9053 is refused): '
              'the DNS filter must forward TCP queries as UDP')
    if mapped:
        # Watch stream events: without a consensus tor may give up on the
        # stream quickly, so a later stream-status could miss it.
        r = cmd(f, 'SETEVENTS STREAM')
        del EVENTS[:]
        c = socket.create_connection((addr, 80), timeout=5)
        read_events(f, s, 5, onion + ':80')
        c.close()
        cmd(f, 'SETEVENTS')
        hit = [l for l in EVENTS if onion + ':80' in l]
        bad += say(r == ['250 OK'] and bool(hit),
                   'TCP to %s:80, redirected by iptables to TransPort, becomes a stream to the .onion name: %s'
                   % (addr, (hit[0][4:] if hit else ' | '.join(EVENTS) or 'no stream event')))

    # Back to offline: the listeners must close again.
    r = cmd(f, 'SETCONF DisableNetwork=1')
    bad += say(r == ['250 OK'], 'SETCONF DisableNetwork=1: ' + ' '.join(r))
    now = wait_listening(set())
    bad += say(now == set(), 'with DisableNetwork 1 again, the listeners are closed: %s'
               % (sorted(now) or 'none'))

    # The bridge commands the module uses after the Welcome screen.
    r = cmd(f, 'SETCONF UseBridges=1 Bridge="192.0.2.10:443 4352E58420E68F5E40BF7C74FADDCCD9D1349413"')
    bad += say(r == ['250 OK'], 'SETCONF UseBridges=1 Bridge=...: ' + ' '.join(r))
    r = cmd(f, 'GETCONF Bridge')
    bad += say(any('192.0.2.10:443' in l for l in r), 'GETCONF Bridge: ' + ' '.join(r))
    r = cmd(f, 'RESETCONF UseBridges Bridge')
    bad += say(r == ['250 OK'], 'RESETCONF UseBridges Bridge: ' + ' '.join(r))
    r = cmd(f, 'GETCONF DisableNetwork')
    bad += say(r == ['250 DisableNetwork=1'], 'network still disabled: ' + ' '.join(r))
    s.close()
    return bad

def noaccess(sock, cookie_path, status_path):
    bad = 0
    try:
        connect(sock)
        bad += say(False, 'uid %d cannot connect to the control socket (it could)' % os.getuid())
    except PermissionError:
        bad += say(True, 'uid %d cannot connect to the control socket' % os.getuid())
    try:
        open(cookie_path, 'rb').read()
        bad += say(False, 'uid %d cannot read the control cookie (it could)' % os.getuid())
    except PermissionError:
        bad += say(True, 'uid %d cannot read the control cookie' % os.getuid())
    try:
        open(status_path).read()
        bad += say(True, 'uid %d can read run/status.json' % os.getuid())
    except OSError as e:
        bad += say(False, 'uid %d can read run/status.json (%s)' % (os.getuid(), e))
    return bad

def shutdown(sock, cookie_path):
    s, f = connect(sock)
    cmd(f, 'AUTHENTICATE ' + open(cookie_path, 'rb').read().hex())
    r = cmd(f, 'SIGNAL SHUTDOWN')
    return say(r == ['250 OK'], 'SIGNAL SHUTDOWN: ' + ' '.join(r))

mode = sys.argv[1]
if mode == 'session':
    sys.exit(min(session(*sys.argv[2:6]), 100))
elif mode == 'noaccess':
    sys.exit(min(noaccess(*sys.argv[2:5]), 100))
elif mode == 'shutdown':
    sys.exit(shutdown(*sys.argv[2:4]))
sys.exit(2)
EOF
)

# inner TOR VERSION HERE: the runtime checks, run by the outer script inside
# new mount and network namespaces.
inner() {
  local tor=$1 version=$2 here=$3 d=/mnt/antumbra bad=0 st
  ipass() { printf '  PASS  %s\n' "$*"; }
  ifail() { printf '  FAIL  %s\n' "$*"; bad=$((bad + 1)); }
  cleanup() { if [[ -n ${pid-} ]]; then kill -9 "$pid" 2>/dev/null || true; fi; }
  trap cleanup EXIT

  mount --make-rprivate / &&
  mount -t tmpfs -o mode=0755,size=64m antumbra-hostcheck /mnt &&
  ip link set lo up &&
  # An app's packets carry its Wi-Fi address; 192.0.2.1 (a documentation
  # address) plays that part here. Without a source address the kernel
  # cannot route to 10.192.0.0/10 at all.
  ip addr add 192.0.2.1/32 dev lo &&
  ip route add 10.192.0.0/10 dev lo src 192.0.2.1 &&
  iptables -w -t nat -A OUTPUT -p tcp -d 10.192.0.0/10 -j REDIRECT --to-ports 9040 ||
    { ifail "could not set up the test namespaces"; return 1; }

  # The layout from the torrc header.
  install -m 0755 "$tor" /mnt/tor
  install -d -m 0711 "$d" "$d/state"
  install -d -m 0700 -o 2950 -g 2950 "$d/state/tor"
  install -d -m 0751 -o 2950 -g 2950 "$d/run"
  install -d -m 0750 -o 2950 -g 2950 "$d/log"
  printf '{"hostcheck":true}\n' >"$d/run/status.json"
  chmod 0644 "$d/run/status.json"
  "$here/render-torrc.sh" "$d" >/mnt/torrc
  chmod 0644 /mnt/torrc
  printf '%s\n' "$CTL_PY" >/mnt/ctl.py

  setpriv --reuid=2950 --regid=2950 --clear-groups --inh-caps=-all --bounding-set=-all \
    --no-new-privs -- /mnt/tor -f /mnt/torrc >/mnt/tor.out 2>&1 &
  pid=$!  # global, so the EXIT trap can still see it
  for _ in $(seq 1 60); do
    [[ -S $d/run/tor-control.sock && -s $d/run/tor-control.authcookie ]] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if [[ ! -S $d/run/tor-control.sock ]]; then
    ifail "tor started as uid 2950 and opened its control socket"
    sed 's/^/        /' /mnt/tor.out "$d/log/tor.log" 2>/dev/null || true
    return 1
  fi
  ipass "tor started as uid 2950 with the rendered torrc and opened its control socket"

  st=$(awk '/^(Uid|Gid|Groups|CapEff|CapPrm|NoNewPrivs):/ { $1 = $1; print }' "/proc/$pid/status" | tr '\n' ';')
  if [[ $st == *"Uid: 2950 2950 2950 2950;"* && $st == *"Gid: 2950 2950 2950 2950;"* &&
        $st == *"CapEff: 0000000000000000;"* && $st == *"CapPrm: 0000000000000000;"* ]]; then
    ipass "process runs as 2950:2950 with no capabilities ($st)"
  else
    ifail "process runs as 2950:2950 with no capabilities ($st)"
  fi
  st=$(stat -c '%a %u %g' "$d/run/tor-control.sock")
  [[ $st == '660 2950 2950' ]] && ipass "control socket mode and owner: $st" ||
    ifail "control socket mode and owner: $st (want 660 2950 2950)"
  st=$(stat -c '%a %u %g' "$d/run/tor-control.authcookie")
  [[ $st == '600 2950 2950' ]] && ipass "cookie file mode and owner: $st" ||
    ifail "cookie file mode and owner: $st (want 600 2950 2950)"

  python3 -I /mnt/ctl.py session "$d/run/tor-control.sock" "$d/run/tor-control.authcookie" \
    "$version" "$ONION" || bad=$((bad + 1))
  setpriv --reuid=2951 --regid=2951 --clear-groups --inh-caps=-all --bounding-set=-all \
    --no-new-privs -- python3 -I /mnt/ctl.py noaccess "$d/run/tor-control.sock" \
    "$d/run/tor-control.authcookie" "$d/run/status.json" || bad=$((bad + 1))
  python3 -I /mnt/ctl.py shutdown "$d/run/tor-control.sock" "$d/run/tor-control.authcookie" ||
    bad=$((bad + 1))

  st=timeout
  for _ in $(seq 1 40); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" && st=0 || st=$?
      pid=''
      break
    fi
    sleep 0.25
  done
  [[ $st == 0 ]] && ipass "tor exited with status 0 after SIGNAL SHUTDOWN" ||
    ifail "tor exited after SIGNAL SHUTDOWN (status: $st)"

  printf '  tor.log:\n'
  sed 's/^/        /' "$d/log/tor.log"
  if grep -q '\[err\]' "$d/log/tor.log"; then ifail "tor.log has no [err] lines"; else ipass "tor.log has no [err] lines"; fi
  if grep -q '\[warn\]' "$d/log/tor.log"; then
    printf '  INFO  tor.log has [warn] lines (listed above)\n'
  fi
  [[ -s /mnt/tor.out ]] && { printf '  tor stdout/stderr:\n'; sed 's/^/        /' /mnt/tor.out; }
  return $((bad > 0))
}

if [[ ${1-} == --inner ]]; then
  shift
  inner "$@"
  exit $?
fi
VERSION='' REQUIRE_RUNTIME=0 TOR=''
LIBS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --expect-version)  VERSION=${2:?}; shift 2 ;;
    --expect-library)  LIBS+=("${2:?}"); shift 2 ;;
    --require-runtime) REQUIRE_RUNTIME=1; shift ;;
    -*) echo "hostcheck-tor.sh: unknown option $1" >&2; exit 2 ;;
    *)  TOR=$1; shift ;;
  esac
done
[[ -n $TOR && -x $TOR ]] || { echo "hostcheck-tor.sh: no executable tor given" >&2; exit 2; }
TOR=$(cd "$(dirname "$TOR")" && pwd -P)/$(basename "$TOR")

failures=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; failures=$((failures + 1)); }
info() { printf '  INFO  %s\n' "$*"; }

printf 'hostcheck-tor: %s\n' "$TOR"

# --- 1 and 2: version, libraries, configuration ---------------------------
out=$("$TOR" --version 2>&1) || true
if [[ -z $VERSION ]] || grep -qF "Tor version $VERSION" <<<"$out"; then
  pass "tor runs on this host: $(head -n 1 <<<"$out")"
else
  fail "tor --version: expected $VERSION, got: $(head -n 1 <<<"$out")"
fi
libs=$("$TOR" --library-versions 2>&1) || true
for l in "${LIBS[@]}"; do
  if grep -qF -- "$l" <<<"$out"$'\n'"$libs"; then pass "library version: $l"; else fail "library version: $l not reported"; fi
done
sed 's/^/        /' <<<"$libs"

rendered=$(mktemp "${TMPDIR:-/tmp}/antumbra-torrc.XXXXXX")
trap 'rm -f "$rendered"' EXIT
"$HERE/render-torrc.sh" /data/adb/antumbra >"$rendered"
if out=$("$TOR" --verify-config -f "$rendered" 2>&1); then
  pass "tor --verify-config accepts the torrc for /data/adb/antumbra"
else
  fail "tor --verify-config rejects the torrc:"
  sed 's/^/        /' <<<"$out"
fi

# --- 3 to 8: runtime, as root in private namespaces --------------------------
missing=()
[[ $EUID -eq 0 ]] || missing+=("root")
for c in unshare setpriv ip iptables python3 mount; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [[ ${#missing[@]} -gt 0 ]]; then
  if ((REQUIRE_RUNTIME)); then
    fail "runtime checks need: ${missing[*]}"
  else
    info "runtime checks skipped (need: ${missing[*]}); run this script as root to include them"
  fi
else
  # The inner part runs in new mount and network namespaces: the tmpfs on
  # /mnt and the iptables rule exist only there, and the only interface is
  # loopback.
  if unshare --mount --net --fork bash "$HERE/hostcheck-tor.sh" --inner "$TOR" "$VERSION" "$HERE"; then
    :
  else
    failures=$((failures + 1))
  fi
fi

if ((failures > 0)); then
  printf 'hostcheck-tor: %d check(s) failed\n' "$failures"
  exit 1
fi
printf 'hostcheck-tor: all checks passed\n'
