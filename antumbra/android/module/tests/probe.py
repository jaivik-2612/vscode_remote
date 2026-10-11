# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra module tests: network probes run as an app's uid in the sandbox.

Usage (python3 -I probe.py ...):
  dns NAME [SERVER]   send an A query over UDP to SERVER:53 (default
                      8.8.8.8, which the firewall redirects to the DNS
                      filter); print NOERROR, NXDOMAIN, SERVFAIL, REFUSED,
                      timeout or "senderror ERRNO"
  status              print the DNS filter's status page (127.0.0.1:5380)
  udp HOST PORT       send one UDP datagram; print "sent" or "error ERRNO"
"""

import random
import socket
import struct
import sys
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


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    {"dns": dns, "status": status, "udp": udp}[cmd](*args)
