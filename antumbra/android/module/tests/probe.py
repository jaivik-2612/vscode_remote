# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra module tests: network probes run as an app's uid in the sandbox.

Usage (python3 -I probe.py ...):
  dns NAME [SERVER]   send an A query over UDP to SERVER:53 (default
                      8.8.8.8, which the firewall redirects to the DNS
                      filter); print NOERROR, NXDOMAIN, SERVFAIL, REFUSED,
                      timeout or "senderror ERRNO"
  status              print the DNS filter's status page (127.0.0.1:5380)
  udp HOST PORT       send one UDP datagram; print "sent" or "error ERRNO"
  tcp HOST PORT       connect (5 s); print "connected", "timeout" or
                      "error ERRNO"
  squat PROTO PORT SECONDS
                      bind 127.0.0.1:PORT (tcp: and listen) and hold it for
                      SECONDS, as an app taking a service port; print
                      "bound" (or "error ERRNO") at once, then, for tcp,
                      "accepted" for each connection that completes
"""

import random
import socket
import struct
import sys
import time
import urllib.request

RCODES = {0: "NOERROR", 2: "SERVFAIL", 3: "NXDOMAIN", 5: "REFUSED"}


def dns(name, server="8.8.8.8"):
    qid = random.randrange(65536)
    qname = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"
    query = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + qname + struct.pack(">HH", 1, 1)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(8)
    try:
        sock.sendto(query, (server, 53))
    except OSError as e:
        print("senderror", e.errno)
        return
    try:
        reply, _ = sock.recvfrom(4096)
    except socket.timeout:
        print("timeout")
        return
    rcode = reply[3] & 15
    print(RCODES.get(rcode, rcode))


def status():
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    print(opener.open("http://127.0.0.1:5380/status", timeout=5).read().decode())


def udp(host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.sendto(b"x", (host, int(port)))
        print("sent")
    except OSError as e:
        print("error", e.errno)


def tcp(host, port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(5)
    try:
        sock.connect((host, int(port)))
        print("connected")
    except socket.timeout:
        print("timeout")
    except OSError as e:
        print("error", e.errno)


def squat(proto, port, seconds):
    kind = socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM
    sock = socket.socket(socket.AF_INET, kind)
    try:
        sock.bind(("127.0.0.1", int(port)))
        if proto == "tcp":
            sock.listen(8)
    except OSError as e:
        print("error", e.errno, flush=True)
        return
    print("bound", flush=True)
    end = time.monotonic() + float(seconds)
    while time.monotonic() < end:
        sock.settimeout(max(0.1, end - time.monotonic()))
        try:
            if proto == "tcp":
                conn, _ = sock.accept()
                print("accepted", flush=True)
                conn.close()
            else:
                sock.recvfrom(4096)
                print("received", flush=True)
        except socket.timeout:
            pass


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"dns": dns, "status": status, "udp": udp, "tcp": tcp, "squat": squat}[cmd](*args)
