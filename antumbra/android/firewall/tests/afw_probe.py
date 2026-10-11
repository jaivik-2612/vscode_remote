#!/usr/bin/env python3
"""Listeners and probes for sandbox-test.sh. Standard library only.

serve  --log FILE --ready FILE SPEC...
    Opens every listener in SPEC, writes FILE (--ready) once all are bound,
    and logs one JSON line per connection or datagram to the --log file. Each
    listener answers with its own name, so a probe knows who it reached; a TCP
    listener also reports the connection's original destination (from
    conntrack, SO_ORIGINAL_DST), which shows where a redirected connection was
    first addressed. SPEC is one of
        tcp:NAME:ADDR:PORT    udp:NAME:ADDR:PORT    (IPv6 ADDR in [brackets])
        unix:NAME:PATH:UID:GID:MODE

tcp HOST PORT TOKEN [--timeout S]
udp HOST PORT TOKEN [--timeout S] [--sport P]
unix PATH TOKEN
ping HOST TOKEN
    Prints exactly one line: "ok <answer>" or "err <ERRNO name>".
"""

import argparse
import errno
import json
import os
import socket
import struct
import sys
import threading

SO_ORIGINAL_DST = 80  # also IP6T_SO_ORIGINAL_DST

_log_lock = threading.Lock()


def _log(path, **event):
    with _log_lock, open(path, "a", encoding="utf-8") as f:
        f.write(json.dumps(event, sort_keys=True) + "\n")


def _split_addr(text):
    """'1.2.3.4:80' or '[::1]:80' -> (host, port)."""
    if text.startswith("["):
        host, _, port = text[1:].partition("]:")
    else:
        host, _, port = text.rpartition(":")
    return host, int(port)


def _family(host):
    return socket.AF_INET6 if ":" in host else socket.AF_INET


def _orig_dst(conn, family):
    try:
        if family == socket.AF_INET:
            raw = conn.getsockopt(socket.SOL_IP, SO_ORIGINAL_DST, 16)
            port = struct.unpack_from("!H", raw, 2)[0]
            return "%s:%d" % (socket.inet_ntop(socket.AF_INET, raw[4:8]), port)
        raw = conn.getsockopt(socket.IPPROTO_IPV6, SO_ORIGINAL_DST, 28)
        port = struct.unpack_from("!H", raw, 2)[0]
        return "[%s]:%d" % (socket.inet_ntop(socket.AF_INET6, raw[8:24]), port)
    except OSError:
        return "-"


def _read_line(conn):
    data = b""
    while b"\n" not in data and len(data) < 256:
        chunk = conn.recv(256)
        if not chunk:
            break
        data += chunk
    return data.split(b"\n", 1)[0].decode("ascii", "replace")


def _tcp_client(conn, peer, name, family, logfile):
    with conn:
        conn.settimeout(3)
        orig = _orig_dst(conn, family)
        try:
            token = _read_line(conn)
            conn.sendall(("%s orig=%s\n" % (name, orig)).encode())
        except OSError:
            token = "?"
        _log(logfile, proto="tcp", name=name, token=token, peer=str(peer), orig=orig)


def _tcp_loop(sock, name, family, logfile):
    while True:
        conn, peer = sock.accept()
        threading.Thread(target=_tcp_client, args=(conn, peer, name, family, logfile), daemon=True).start()


def _udp_loop(sock, name, logfile):
    while True:
        data, peer = sock.recvfrom(2048)
        token = data.decode("ascii", "replace").strip()
        try:
            sock.sendto(("%s\n" % name).encode(), peer)
        except OSError:
            pass
        _log(logfile, proto="udp", name=name, token=token, peer=str(peer))


def _unix_loop(sock, name, logfile):
    while True:
        conn, _ = sock.accept()
        with conn:
            conn.settimeout(3)
            try:
                token = _read_line(conn)
                conn.sendall(("%s\n" % name).encode())
            except OSError:
                token = "?"
            _log(logfile, proto="unix", name=name, token=token)


def serve(args):
    threads = []
    for spec in args.spec:
        kind, rest = spec.split(":", 1)
        if kind == "unix":
            name, path, uid, gid, mode = rest.split(":")
            if os.path.exists(path):
                os.unlink(path)
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.bind(path)
            os.chown(path, int(uid), int(gid))
            os.chmod(path, int(mode, 8))
            sock.listen(16)
            threads.append(threading.Thread(target=_unix_loop, args=(sock, name, args.log), daemon=True))
            continue
        name, addr = rest.split(":", 1)
        host, port = _split_addr(addr)
        family = _family(host)
        if kind == "tcp":
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((host, port))
            sock.listen(64)
            threads.append(threading.Thread(target=_tcp_loop, args=(sock, name, family, args.log), daemon=True))
        elif kind == "udp":
            sock = socket.socket(family, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((host, port))
            threads.append(threading.Thread(target=_udp_loop, args=(sock, name, args.log), daemon=True))
        else:
            raise SystemExit("unknown listener kind: " + spec)
    for t in threads:
        t.start()
    with open(args.ready, "w", encoding="utf-8") as f:
        f.write("ready\n")
    threading.Event().wait()


def _err(exc):
    if isinstance(exc, socket.timeout):
        return "err ETIMEDOUT"
    return "err " + errno.errorcode.get(exc.errno or 0, str(exc.errno))


def probe_tcp(args):
    sock = socket.socket(_family(args.host), socket.SOCK_STREAM)
    sock.settimeout(args.timeout)
    try:
        sock.connect((args.host, args.port))
        sock.sendall((args.token + "\n").encode())
        answer = _read_line(sock)
        return "ok " + answer if answer else "err NOANSWER"
    except OSError as exc:
        return _err(exc)
    finally:
        sock.close()


def probe_udp(args):
    sock = socket.socket(_family(args.host), socket.SOCK_DGRAM)
    sock.settimeout(args.timeout)
    try:
        if args.sport:
            sock.bind(("0.0.0.0" if _family(args.host) == socket.AF_INET else "::", args.sport))
        # A connected socket reports ICMP errors as ECONNREFUSED.
        sock.connect((args.host, args.port))
        sock.send((args.token + "\n").encode())
        data = sock.recv(2048)
        return "ok " + data.decode("ascii", "replace").strip()
    except OSError as exc:
        return _err(exc)
    finally:
        sock.close()


def probe_ping(args):
    """One ICMP echo through an unprivileged ping socket, as Android apps may
    open (net.ipv4.ping_group_range)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)
    sock.settimeout(args.timeout)
    try:
        # Type 8 (echo request); the kernel fills in the identifier and checksum.
        sock.sendto(struct.pack("!BBHHH", 8, 0, 0, 0, 1) + args.token.encode(), (args.host, 0))
        data = sock.recv(2048)
        return "ok echo-reply" if data[:1] == b"\x00" else "err NOTREPLY"
    except OSError as exc:
        return _err(exc)
    finally:
        sock.close()


def probe_unix(args):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(args.timeout)
    try:
        sock.connect(args.path)
        sock.sendall((args.token + "\n").encode())
        return "ok " + _read_line(sock)
    except OSError as exc:
        return _err(exc)
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("serve")
    p.add_argument("--log", required=True)
    p.add_argument("--ready", required=True)
    p.add_argument("spec", nargs="+")
    for kind in ("tcp", "udp"):
        p = sub.add_parser(kind)
        p.add_argument("host")
        p.add_argument("port", type=int)
        p.add_argument("token")
        p.add_argument("--timeout", type=float, default=2.0)
        if kind == "udp":
            p.add_argument("--sport", type=int, default=0)
    p = sub.add_parser("unix")
    p.add_argument("path")
    p.add_argument("token")
    p.add_argument("--timeout", type=float, default=2.0)
    p = sub.add_parser("ping")
    p.add_argument("host")
    p.add_argument("token")
    p.add_argument("--timeout", type=float, default=2.0)
    args = parser.parse_args()
    if args.cmd == "serve":
        serve(args)
        return
    print({"tcp": probe_tcp, "udp": probe_udp, "unix": probe_unix, "ping": probe_ping}[args.cmd](args))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
