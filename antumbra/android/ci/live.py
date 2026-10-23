#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra Live: helpers for the virtual phone the owner uses in a browser
(standard library only).

Antumbra Live (.github/workflows/antumbra-live.yml) boots the CI's virtual
phone with a window on a virtual X display, shows that display through
x11vnc (on 127.0.0.1 only), noVNC and websockify (on 127.0.0.1 only), and
reaches it from the Internet through a Cloudflare quick tunnel. The
repository and its Actions logs are public: the tunnel's address may be
seen by anyone, so every WebSocket connection to the screen must carry a
token derived from the owner's password (the repository secret
ANTUMBRA_LIVE_PASSWORD), and websockify's TokenFile plugin refuses any
other before it connects to anything.

The token is PBKDF2-HMAC-SHA256 (600,000 rounds, 32 bytes, in hex) of the
password, with the salt

    "antumbra-live" LF HOST                       (the screen)
    "antumbra-live-end" LF HOST                   (the page's End session)

where HOST is the tunnel's host name as the browser sees it (lower case,
with a port only when it is not the default one) and the password is in
Unicode NFC with spaces, tabs and line breaks at either end removed. The
landing page (live/index.html) computes the same with crypto.subtle; the
password itself never leaves the browser, a token is good for one
session's host name only, and the slow hash makes a token that leaked (to
Cloudflare, which carries it inside the HTTPS connection, for example) a
poor start for guessing the password.

Commands:

  live.py secret-check
      ANTUMBRA_LIVE_PASSWORD (environment) is set and 20 characters or
      longer. Exit 0, else 1; prints one plain sentence, never the value.
  live.py minutes VALUE
      The session's length in minutes: VALUE as a whole number from 10 to
      180 (60 when it is not a number).
  live.py token --host HOST --tokens FILE [--vnc 127.0.0.1:5917]
                [--end 127.0.0.1:5998] [--mask]
      Writes websockify's token file (mode 0600): the screen's token to the
      VNC server, the End token to the end listener. --mask prints GitHub's
      ::add-mask:: command for both tokens (the runner hides them in logs).
  live.py probe --url URL --tokens FILE --web DIR [--vnc-log FILE] [--ip ADDRESS]
      Checks the link as a stranger and as the owner. First a file with a
      random word is put in DIR (the web root) and fetched through URL: the
      link must reach this websockify, else nothing that follows proves
      anything. Then WebSockets to URL/websockify as a stranger would open
      them (no token, a wrong one): each must be refused, and with
      --vnc-log (x11vnc's log) x11vnc must have seen no client. Then the
      owner's token, which must get the VNC server's greeting. Each step is
      tried up to --tries times while it gets no answer. --ip connects to
      ADDRESS instead of looking up URL's host (TLS still checks the host
      name). Prints the outcome in plain words (no token). Exit 0 when all
      hold; 2 when a stranger got through; 3 when the strangers' check
      could not be made (the link never answered); 1 when strangers were
      refused but the owner's token got no screen.
  live.py end-listener --port N --flag FILE
      Listens on 127.0.0.1:N; each connection (websockify makes one only for
      the End token) writes FILE, which ends the session.
  live.py state --web DIR [--start EPOCH --end EPOCH --minutes M] [--set KEY=VALUE]...
      Writes DIR/session.json, which the landing page reads: the session's
      start and end (UTC) and its state (starting, ready, started, ending,
      ended, failed). Public: it holds nothing else.
  live.py report REPORT_DIR --out DIR [--run N] [--build TEXT]
      The privacy check of the session, from live/analysis.json (analyse.sh),
      live/checks.tsv and live/events.tsv: DIR/report.md (also printed, for
      the job summary), DIR/report.json and DIR/checks.tsv. The artifact is
      public, so it holds counts and leaks only: no capture of the phone,
      no names or destinations reached through Tor, no screenshots, no
      bridges (what the owner did is theirs). Public Internet addresses in
      the reasons and the checks are left out (tor's connections, which
      may be the owner's bridges, are named there), and a "leak" to one of
      tor's own connections or bridges is shown without its address.
"""

import argparse
import base64
import datetime
import hashlib
import ipaddress
import json
import os
import re
import secrets
import socket
import ssl
import sys
import time
import unicodedata
import urllib.parse

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import applab  # noqa: E402  the leak analysis in the app lab's words

PASSWORD_ENV = "ANTUMBRA_LIVE_PASSWORD"
MIN_PASSWORD = 20
MINUTES_DEFAULT, MINUTES_MIN, MINUTES_MAX = 60, 10, 180
LABELS = {"screen": "antumbra-live", "end": "antumbra-live-end"}
# PBKDF2 rounds for the tokens; live/index.html uses the same number.
TOKEN_ROUNDS = 600000
# x11vnc's log line for each client it accepts.
X11VNC_CLIENT_RE = re.compile(r"Got connection from client")


# ---------------------------------------------------------------------------
# The password and the tokens
# ---------------------------------------------------------------------------

def normalize_password(password):
    """The password as both sides use it: NFC, without spaces, tabs or line
    breaks at either end (the landing page does the same)."""
    return unicodedata.normalize("NFC", password or "").strip(" \t\r\n")


def secret_problem(password):
    """None when the password will do, else why not (never the value)."""
    p = normalize_password(password)
    if not p:
        return ("The repository secret %s is missing. Create it once (Settings, Secrets and variables, "
                "Actions, New repository secret) with a password of %d characters or more, then start "
                "Antumbra Live again." % (PASSWORD_ENV, MIN_PASSWORD))
    if len(p) < MIN_PASSWORD:
        return ("The repository secret %s is shorter than %d characters. Replace it with a longer password "
                "(Settings, Secrets and variables, Actions), then start Antumbra Live again."
                % (PASSWORD_ENV, MIN_PASSWORD))
    return None


def normalize_host(host):
    return (host or "").strip().lower().rstrip(".")


def token(host, password, kind="screen"):
    salt = "%s\n%s" % (LABELS[kind], normalize_host(host))
    return hashlib.pbkdf2_hmac("sha256", normalize_password(password).encode("utf-8"), salt.encode("utf-8"),
                               TOKEN_ROUNDS, 32).hex()


def token_file_text(host, password, vnc, end):
    return "%s: %s\n%s: %s\n" % (token(host, password, "screen"), vnc, token(host, password, "end"), end)


def write_private(path, text):
    """Writes PATH readable by its owner only, replacing it atomically."""
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_tokens(path):
    """[(token, target)] from websockify's token file."""
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                tok, _, target = line.partition(": ")
                out.append((tok, target.strip()))
    return out


def clamp_minutes(value):
    try:
        m = int(float(str(value).strip()))
    except (TypeError, ValueError, OverflowError):
        return MINUTES_DEFAULT
    return max(MINUTES_MIN, min(MINUTES_MAX, m))


# ---------------------------------------------------------------------------
# A WebSocket client, for the probe
# ---------------------------------------------------------------------------

def _recv_until(sock, marker, limit=65536):
    buf = b""
    while marker not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
        if len(buf) > limit:
            break
    return buf


def _recv_exact(sock, n, buf=b""):
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def _connect(u, timeout, connect_host=None):
    """A socket to URL u's server (TLS for https and wss, the host name
    checked against its certificate), at CONNECT_HOST when given."""
    tls = u.scheme in ("https", "wss")
    port = u.port or (443 if tls else 80)
    sock = socket.create_connection((connect_host or u.hostname, port), timeout)
    sock.settimeout(timeout)
    if tls:
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=u.hostname)
    return sock


def http_get(url, path, timeout=20.0, connect_host=None):
    """GET URL's PATH: ("ok", body) for a 200 answer, ("refused", detail)
    for another answer, ("error", detail) when the server could not be
    reached or did not answer."""
    u = urllib.parse.urlsplit(url)
    try:
        sock = _connect(u, timeout, connect_host)
    except (OSError, ssl.SSLError) as e:
        return "error", "cannot connect: %s" % e.__class__.__name__
    try:
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\nCache-Control: no-cache\r\n"
               "User-Agent: antumbra-live-probe\r\n\r\n") % ((u.path.rstrip("/") or "") + path, u.netloc)
        sock.sendall(req.encode("ascii"))
        data = b""
        while len(data) < 65536:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
        if not data:
            return "error", "the connection was closed before any answer"
        head, _, body = data.partition(b"\r\n\r\n")
        m = re.match(r"HTTP/1\.[01] (\d{3})", head.split(b"\r\n", 1)[0].decode("latin-1", "replace"))
        if not m:
            return "refused", "no HTTP answer"
        if m.group(1) != "200":
            return "refused", "HTTP %s" % m.group(1)
        return "ok", body.decode("utf-8", "replace")
    except socket.timeout:
        return "error", "no answer within %d s" % timeout
    except (OSError, ssl.SSLError) as e:
        return "error", e.__class__.__name__
    finally:
        try:
            sock.close()
        except OSError:
            pass


def ws_probe(url, tok, timeout=20.0, connect_host=None):
    """Opens a WebSocket to URL/websockify[?token=TOK] and reads the first
    frame. Returns ("answered", detail) when the VNC server's greeting
    ("RFB ...") came, ("refused", detail) when the server refused the
    upgrade or closed without sending data, ("error", detail) when the
    server could not be reached or did not answer at all."""
    u = urllib.parse.urlsplit(url)
    tls = u.scheme in ("https", "wss")
    path = (u.path.rstrip("/") or "") + "/websockify"
    if tok is not None:
        path += "?token=" + urllib.parse.quote(tok, safe="")
    try:
        sock = _connect(u, timeout, connect_host)
    except (OSError, ssl.SSLError) as e:
        return "error", "cannot connect: %s" % e.__class__.__name__
    try:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        origin = "%s://%s" % ("https" if tls else "http", u.netloc)
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: binary\r\n"
               "Origin: %s\r\nUser-Agent: antumbra-live-probe\r\n\r\n") % (path, u.netloc, key, origin)
        sock.sendall(req.encode("ascii"))
        head = _recv_until(sock, b"\r\n\r\n")
        if not head:
            return "refused", "the connection was closed before any answer"
        status = head.split(b"\r\n", 1)[0].decode("latin-1", "replace")
        m = re.match(r"HTTP/1\.[01] (\d{3})", status)
        if not m:
            return "refused", "no HTTP answer"
        if m.group(1) != "101":
            return "refused", "HTTP %s" % m.group(1)
        rest = head.split(b"\r\n\r\n", 1)[1]
        hdr = _recv_exact(sock, 2, rest[:2])
        rest = rest[2:]
        if len(hdr) < 2:
            return "refused", "upgraded, then closed with no data"
        opcode, n = hdr[0] & 0x0F, hdr[1] & 0x7F
        if n == 126:
            ext = _recv_exact(sock, 2, rest[:2])
            rest = rest[2:]
            n = int.from_bytes(ext, "big")
        elif n == 127:
            ext = _recv_exact(sock, 8, rest[:8])
            rest = rest[8:]
            n = int.from_bytes(ext, "big")
        if hdr[1] & 0x80:  # a server never masks; read past a mask anyway
            _recv_exact(sock, 4, rest[:4])
            rest = rest[4:]
        payload = _recv_exact(sock, min(n, 64), rest[:min(n, 64)])
        if opcode == 8:
            return "refused", "upgraded, then closed (%s)" % (
                int.from_bytes(payload[:2], "big") if len(payload) >= 2 else "no code")
        if payload.startswith(b"RFB "):
            return "answered", payload.strip().decode("ascii", "replace")
        return "refused", "upgraded, but no VNC greeting (opcode %d)" % opcode
    except socket.timeout:
        return "error", "no answer within %d s" % timeout
    except (OSError, ssl.SSLError) as e:
        return "error", e.__class__.__name__
    finally:
        try:
            sock.close()
        except OSError:
            pass


def count_vnc_clients(log):
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            return sum(1 for line in f if X11VNC_CLIENT_RE.search(line))
    except OSError:
        return None


# probe()'s exit codes.
PROBE_OK, PROBE_NO_SCREEN, PROBE_STRANGER_IN, PROBE_UNCHECKED = 0, 1, 2, 3


def _tries(fn, tries, wait, sleep):
    """fn() until its result is not "error", TRIES times at most."""
    res = ("error", "not tried")
    for i in range(max(1, tries)):
        res = fn()
        if res[0] != "error":
            break
        if i + 1 < tries:
            sleep(wait)
    return res


def probe(url, tokens_path, web=None, vnc_log=None, tries=6, wait=10.0, probe_fn=ws_probe, get_fn=http_get,
          sleep=time.sleep):
    """(exit code, lines); see the module's docstring. A stranger's
    "refused" counts only once the link has been seen to reach this
    websockify (the random word in WEB came back through it): a broken
    tunnel refuses everything too, which would prove nothing."""
    # The screen's token is the file's first line (token_file_text); the
    # End token is never used here.
    entries = read_tokens(tokens_path)
    right = entries[0][0] if entries else None
    lines = []
    reached, through, unchecked = False, False, False
    if web:
        word = secrets.token_hex(16)
        name = "probe-%s.txt" % secrets.token_hex(8)
        path = os.path.join(web, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(word + "\n")
        try:
            res, detail = _tries(lambda: get_fn(url, "/" + name), tries, wait, sleep)
        finally:
            os.remove(path)
        if res == "ok" and detail.strip() == word:
            reached = True
            lines.append("ok: the link reaches this session's web server")
        else:
            lines.append("not checked: the link did not reach this session's web server (%s)" % (
                detail if res != "ok" else "another answer"))
    else:
        lines.append("not checked: no web root given, so the link was not seen to reach this web server")
    before = count_vnc_clients(vnc_log) if vnc_log else None
    # Without the link, once each: a refusal would prove nothing, but a
    # screen that answers is still a stranger getting through.
    again = tries if reached else 1
    for what, tok in (("no password", None), ("a wrong password", secrets.token_hex(32))):
        res, detail = _tries(lambda: probe_fn(url, tok), again, wait, sleep)
        if res == "answered":
            through = True
            lines.append("FAIL: with %s the screen answered (%s)" % (what, detail))
        elif res == "error" or not reached:
            unchecked = True
            lines.append("not checked: with %s, %s (%s)" % (
                what, "no answer from the link" if res == "error" else "refused, but the link was not seen "
                "to reach this web server", detail))
        else:
            lines.append("ok: with %s, refused (%s)" % (what, detail))
    if vnc_log:
        after = count_vnc_clients(vnc_log)
        if before is None or after is None:
            unchecked = True
            lines.append("not checked: x11vnc's log could not be read")
        elif after != before:
            through = True
            lines.append("FAIL: x11vnc saw %d client(s) while strangers knocked" % (after - before))
        else:
            lines.append("ok: x11vnc saw no client while strangers knocked")
    if through:
        return PROBE_STRANGER_IN, lines
    res, detail = "error", "no token in the token file"
    for i in range(again if right else 0):
        res, detail = probe_fn(url, right)
        if res == "answered":
            break
        if i + 1 < again:
            sleep(wait)
    if res == "answered":
        lines.append("ok: with the right password the screen answered (%s)" % detail)
    else:
        lines.append("the right password got no screen: %s (%s)" % (res, detail))
    if unchecked:
        return PROBE_UNCHECKED, lines
    return (PROBE_OK if res == "answered" else PROBE_NO_SCREEN), lines


# ---------------------------------------------------------------------------
# The End listener and the page's state
# ---------------------------------------------------------------------------

def end_listener(port, flag, once=False):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    while True:
        conn, _ = srv.accept()
        conn.close()
        with open(flag, "a", encoding="utf-8") as f:
            f.write("%s End session pressed on the page\n" % utc_iso(time.time()))
        if once:
            srv.close()
            return


def utc_iso(epoch):
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def utc_hm(epoch):
    return datetime.datetime.fromtimestamp(int(epoch), datetime.timezone.utc).strftime("%H:%M")


STATES = ("starting", "ready", "started", "ending", "ended", "failed")


def write_state(web, start=None, end=None, minutes=None, sets=()):
    path = os.path.join(web, "session.json")
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    if not isinstance(st, dict):
        st = {}
    if start is not None:
        st["start"] = utc_iso(start)
    if end is not None:
        st["end"] = utc_iso(end)
    if minutes is not None:
        st["minutes"] = int(minutes)
    st.setdefault("state", "starting")
    for kv in sets:
        k, _, v = kv.partition("=")
        if k == "state" and v not in STATES:
            raise ValueError("unknown state %r" % v)
        if k not in ("state", "note"):
            raise ValueError("unknown key %r" % k)
        st[k] = v[:200]
        if k == "state":
            st["since"] = utc_iso(time.time())
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, sort_keys=True)
        f.write("\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    return st


# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

def _tsv(path, cols):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2:
                    out.append((parts + [""] * cols)[:cols])
    except OSError:
        pass
    return out


VERDICT_WORDS = {
    "pass": "**Pass.** After the firewall went on, nothing left the virtual phone outside Tor.",
    "fail": "**Fail.** Something left the virtual phone outside Tor after the firewall went on, "
            "or a requirement of the check was not met (below).",
    "blind": "**Could not judge.** The recordings do not cover the whole session (below).",
    "error": "**Could not judge.** The leak analysis failed (below).",
}

END_WORDS = {
    "time": "the time was up",
    "page": "End session was pressed on the page",
    "gone": "the virtual phone stopped answering (switched off?)",
    "restarted": "the virtual phone restarted (without Magisk, Antumbra's module does not start again, "
                 "so the session could not go on)",
    "cancelled": "the run was cancelled",
    "failed": "the phone could not be set up",
}


# Internet addresses in free text: IPv4 with an optional port, IPv6 in
# brackets with an optional port, and bare IPv6.
_ADDR_RE = re.compile(r"\[[0-9A-Fa-f:.]+\](?::\d{1,5})?"
                      r"|(?<![\w.:])\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?(?![\w.])"
                      r"|(?<![\w:])(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f:]*[0-9A-Fa-f](?![\w:])")
_HIDDEN = "\x00"


def _host_part(addr):
    """The address without brackets and port, or None."""
    if addr.startswith("["):
        return addr[1:addr.index("]")]
    if addr.count(":") == 1:
        return addr.split(":")[0]
    return addr


# Addresses that stay in the public report: the virtual phone's own
# networks and other addresses that lead nowhere on the Internet.
_LOCAL_NETS = [ipaddress.ip_network(n) for n in (
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
    "192.168.0.0/16", "::/128", "::1/128", "fc00::/7", "fe80::/10")]


def _is_public(addr):
    try:
        ip = ipaddress.ip_address(_host_part(addr))
    except ValueError:
        return False
    return not any(ip.version == n.version and ip in n for n in _LOCAL_NETS)


def redact(text):
    """TEXT with every address outside the virtual phone's own networks
    left out. tor's connections (relays, or the owner's bridges) are named
    in the leak analyser's reasons; 10.0.2.x and the like stay."""
    t = _ADDR_RE.sub(lambda m: _HIDDEN if _is_public(m.group(0)) else m.group(0), str(text))
    t = re.sub(r"\(%s(?:, %s)*\)" % (_HIDDEN, _HIDDEN), "(addresses not shown)", t)
    return re.sub(r"%s(?:, %s)*" % (_HIDDEN, _HIDDEN), "<address not shown>", t)


def tor_addresses(sdir):
    """The addresses (no ports) of tor's own connections at the end and of
    the session's bridges: a flow to one of them is tor's, whatever the
    analysis made of it, and it may be a bridge of the owner's."""
    out = set()
    for name in ("tor-connections.txt", "bridges.txt"):
        for m in _ADDR_RE.finditer(applab._read(os.path.join(sdir, name)) or ""):
            try:
                out.add(str(ipaddress.ip_address(_host_part(m.group(0)))))
            except ValueError:
                pass
    return out


def build_report(root, run=None, build=None):
    s = os.path.join(root, "live")
    analysis = applab._json(os.path.join(s, "analysis.json"))
    leak = applab.leak_section(analysis)
    checks = [(c[0], c[1], redact(c[2])) for c in _tsv(os.path.join(s, "checks.tsv"), 3)]
    events = _tsv(os.path.join(s, "events.tsv"), 3)
    ev = {}
    for name, t, detail in events:
        ev.setdefault(name, (t, detail))
    result = (applab._read(os.path.join(s, "result")) or "").strip() or None

    def when(name):
        try:
            return utc_iso(float(ev[name][0]))
        except (KeyError, ValueError):
            return None

    session = {
        "phone_ready": when("live_ready"),
        "start_pressed": when("live_started"),
        "start_choices": ev.get("live_started", (None, None))[1],
        "ended": when("live_end"),
        "end_reason": ev.get("live_end", (None, None))[1],
        "result": result,
    }
    # A leak's destination, kind and reason, without the names looked up
    # for it (they would say what the owner did); one to tor's own
    # connections or bridges without its address.
    tor = tor_addresses(s)
    leaks = []
    for f in leak.get("leaks") or []:
        f = {k: v for k, v in f.items() if k != "names"}
        try:
            dst = str(ipaddress.ip_address(str(f.get("dst") or "")))
        except ValueError:
            dst = None
        if dst is not None and dst in tor:
            f.update(dst="one of tor's own connections or bridges (address not shown)", dport=None,
                     reason="its address is tor's own: not shown, as it may be a bridge")
        else:
            f["reason"] = redact(f.get("reason") or "")
        leaks.append(f)
    res = {
        "schema": 1, "run": run, "build": build, "generated": utc_iso(time.time()),
        "session": session,
        "leak": {k: leak.get(k) for k in ("verdict", "reasons", "packets_after_arm", "packets_to_tor",
                                          "leak_flows", "names_through_tor", "targets_through_tor")},
        "checks": {"ok": sum(1 for c in checks if c[1] == "ok"),
                   "warn": sum(1 for c in checks if c[1] == "warn"),
                   "fail": sum(1 for c in checks if c[1] == "fail"),
                   "not_ok": [{"name": c[0], "level": c[1], "detail": c[2]} for c in checks if c[1] != "ok"]},
    }
    res["leak"]["reasons"] = [redact(r) for r in (res["leak"].get("reasons") or [])]
    res["leak"]["leaks"] = leaks
    return res, checks


def _n(x):
    return "–" if x is None else "{:,}".format(x) if isinstance(x, int) else str(x)


def markdown(res):
    L = res["leak"]
    ses = res["session"]
    out = ["## Antumbra Live: privacy check of the session" + (" (run %s)" % res["run"] if res.get("run") else ""), ""]
    v = L.get("verdict")
    out.append(VERDICT_WORDS.get(v, "**Not judged.** The leak analysis did not run: the phone's recordings "
                                    "were not collected."))
    out.append("")
    out.append("| | |")
    out.append("|---|---|")
    out.append("| Packets the phone sent after the firewall went on | %s |" % _n(L.get("packets_after_arm")))
    out.append("| … to the Tor network | %s |" % _n(L.get("packets_to_tor")))
    out.append("| Leaks (flows outside Tor) | %s |" % _n(L.get("leak_flows") if v else None))
    out.append("| Names and destinations reached through Tor | %s names, %s destinations (counted, not listed: "
               "they are what you did) |" % (_n(L.get("names_through_tor") if v else None),
                                             _n(L.get("targets_through_tor") if v else None)))
    out.append("")
    if L.get("leaks"):
        out.append("Leaks:")
        out.append("")
        out.append("| Kind | Destination | Packets after arm | Why |")
        out.append("|---|---|---|---|")
        for f in L["leaks"][:20]:
            dst = "%s%s" % (f.get("dst") or "?", (":%s" % f["dport"]) if f.get("dport") else "")
            out.append("| %s | %s %s | %s | %s |" % (
                applab._md(str(f.get("kind") or "")), applab._md(str(f.get("proto") or "")), applab._md(dst),
                _n(f.get("packets_after_arm")), applab._md(str(f.get("reason") or ""))[:200]))
        out.append("")
    if v and v != "pass" and L.get("reasons"):
        out.append("Why:")
        out.append("")
        for r in L["reasons"][:10]:
            out.append("- %s" % applab._md(str(r))[:300])
        out.append("")
    out.append("The session:")
    out.append("")
    out.append("- Phone ready: %s" % (ses["phone_ready"] or "no (it was not set up; see the checks)"))
    if ses["start_pressed"]:
        out.append("- Start pressed in Welcome: %s (%s)" % (ses["start_pressed"], ses["start_choices"] or ""))
    else:
        out.append("- Start was not pressed in Welcome (Tor was never started)")
    out.append("- Ended: %s, because %s" % (ses["ended"] or "–",
                                            END_WORDS.get(ses["end_reason"] or "", ses["end_reason"] or "–")))
    c = res["checks"]
    out.append("- Checks: %d ok, %d warnings, %d failed" % (c["ok"], c["warn"], c["fail"]))
    for x in c["not_ok"][:15]:
        out.append("  - %s %s: %s" % (x["level"], applab._md(x["name"]), applab._md(x["detail"])[:200]))
    out.append("")
    out.append("The same rules as the app lab judge every session, whatever was done in it. The recordings "
               "themselves stay on GitHub's machine, which is wiped after the run: the one inside the phone "
               "holds what apps sent to Tor, which is yours. The artifact holds this report and the checks.")
    out.append("")
    return "\n".join(out)


def report(root, out_dir, run=None, build=None):
    res, checks = build_report(root, run, build)
    md = markdown(res)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "report.json"), "w", encoding="utf-8") as f:
        json.dump(res, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(out_dir, "report.md"), "w", encoding="utf-8") as f:
        f.write(md)
    if checks:
        with open(os.path.join(out_dir, "checks.tsv"), "w", encoding="utf-8") as g:
            for c in checks:
                g.write("\t".join(c) + "\n")
    return md


# ---------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("secret-check")
    m = sub.add_parser("minutes")
    m.add_argument("value", nargs="?", default="")
    t = sub.add_parser("token")
    t.add_argument("--host", required=True)
    t.add_argument("--tokens", required=True)
    t.add_argument("--vnc", default="127.0.0.1:5917")
    t.add_argument("--end", default="127.0.0.1:5998")
    t.add_argument("--mask", action="store_true")
    p = sub.add_parser("probe")
    p.add_argument("--url", required=True)
    p.add_argument("--tokens", required=True)
    p.add_argument("--web")
    p.add_argument("--vnc-log")
    p.add_argument("--ip")
    p.add_argument("--tries", type=int, default=6)
    e = sub.add_parser("end-listener")
    e.add_argument("--port", type=int, required=True)
    e.add_argument("--flag", required=True)
    s = sub.add_parser("state")
    s.add_argument("--web", required=True)
    s.add_argument("--start", type=float)
    s.add_argument("--end", type=float)
    s.add_argument("--minutes", type=int)
    s.add_argument("--set", action="append", default=[])
    r = sub.add_parser("report")
    r.add_argument("root")
    r.add_argument("--out", required=True)
    r.add_argument("--run")
    r.add_argument("--build")
    a = ap.parse_args(argv)

    if a.cmd == "secret-check":
        why = secret_problem(os.environ.get(PASSWORD_ENV, ""))
        print(why or "The password secret is set and long enough.")
        return 1 if why else 0
    if a.cmd == "minutes":
        print(clamp_minutes(a.value))
        return 0
    if a.cmd == "token":
        pw = os.environ.get(PASSWORD_ENV, "")
        if secret_problem(pw):
            print("live: %s" % secret_problem(pw), file=sys.stderr)
            return 1
        if a.mask:
            for kind in ("screen", "end"):
                print("::add-mask::%s" % token(a.host, pw, kind))
        write_private(a.tokens, token_file_text(a.host, pw, a.vnc, a.end))
        return 0
    if a.cmd == "probe":
        ip = a.ip or None

        def ws(url, tok):
            return ws_probe(url, tok, connect_host=ip)

        def get(url, path):
            return http_get(url, path, connect_host=ip)
        code, lines = probe(a.url, a.tokens, a.web, a.vnc_log, a.tries, probe_fn=ws, get_fn=get)
        for line in lines:
            print(line)
        return code
    if a.cmd == "end-listener":
        end_listener(a.port, a.flag)
        return 0
    if a.cmd == "state":
        try:
            write_state(a.web, a.start, a.end, a.minutes, a.set)
        except ValueError as e:
            print("live: %s" % e, file=sys.stderr)
            return 1
        return 0
    if a.cmd == "report":
        sys.stdout.write(report(a.root, a.out, a.run, a.build))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
