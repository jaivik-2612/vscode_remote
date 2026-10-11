#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Antumbra CI: small helpers for the emulator scenarios (standard library).

  citool.py ui-find [--id ID] [--text REGEX] < window_dump.xml
      Prints "X Y CHECKED ENABLED" for the first node of a uiautomator dump
      whose resource-id is ID (Compose test tags appear as resource ids when
      the app sets testTagsAsResourceId; "pkg:id/ID" also matches) or whose
      text or content description matches REGEX (case-insensitive). Prints
      nothing and exits 1 when there is no such node.

  citool.py dns-query --port PORT --name NAME [--server 127.0.0.1] [--type A]
                      [--timeout 10]
      Sends one DNS query over TCP (the DNS filter listens on TCP 5353 as
      well as UDP; adb forwards only TCP) and prints the answer as JSON:
      rcode, answers, authority records, time taken.

  citool.py json-get FILE KEY.PATH
      Prints the value at a dotted path of a JSON file ("" if missing).

  citool.py pack DIR --limit-mb N [--optional GLOB]...
      Keeps an artifact directory under N MB: deletes the optional files in
      the order given, then the largest files under DIR/logs, until it fits.
      Lists what it removed in DIR/omitted.txt. Exit 1 if it cannot fit.
"""

import argparse
import fnmatch
import json
import os
import random
import re
import socket
import struct
import sys
import time
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}
QTYPES = {"A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "PTR": 12, "MX": 15, "TXT": 16, "AAAA": 28}


# ---------------------------------------------------------------------------
# uiautomator
# ---------------------------------------------------------------------------

def ui_find(xml_text, node_id=None, text=None):
    """(x, y, checked, enabled) of the first matching node, or None."""
    try:
        root = ET.fromstring(xml_text)
    except ET.ParseError:
        return None
    rx = re.compile(text, re.I) if text else None

    def by_id(n):
        rid = n.get("resource-id", "")
        return bool(node_id) and (rid == node_id or rid.endswith(":id/" + node_id))

    def by_text(n):
        return bool(rx) and bool(rx.search(n.get("text", "") or "") or rx.search(n.get("content-desc", "") or ""))

    # The test tag first, anywhere on screen; the text only when no node
    # carries the tag.
    for match in (by_id, by_text):
        for n in root.iter("node"):
            if not match(n):
                continue
            m = re.match(r"^\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]$", n.get("bounds", ""))
            if not m:
                continue
            x1, y1, x2, y2 = (int(v) for v in m.groups())
            if x2 <= x1 or y2 <= y1:
                continue
            return ((x1 + x2) // 2, (y1 + y2) // 2, n.get("checked", "false"), n.get("enabled", "true"))
    return None


# ---------------------------------------------------------------------------
# DNS over TCP
# ---------------------------------------------------------------------------

def dns_build_query(name, qtype, qid):
    labels = [l for l in name.rstrip(".").split(".") if l]
    q = b"".join(struct.pack("B", len(l)) + l.encode("ascii") for l in labels) + b"\x00"
    return struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + q + struct.pack(">HH", qtype, 1)


def _read_name(msg, pos):
    labels, jumps, end = [], 0, None
    while True:
        n = msg[pos]
        if n == 0:
            pos += 1
            break
        if n & 0xC0 == 0xC0:
            if jumps > 16:
                raise ValueError("compression loop")
            if end is None:
                end = pos + 2
            pos = ((n & 0x3F) << 8) | msg[pos + 1]
            jumps += 1
            continue
        labels.append(msg[pos + 1:pos + 1 + n].decode("ascii", "replace"))
        pos += 1 + n
    return ".".join(labels), (end if end is not None else pos)


def dns_parse_response(msg, qid=None):
    """A dict describing a DNS response message."""
    if len(msg) < 12:
        raise ValueError("response shorter than a DNS header")
    rid, flags, qd, an, ns, _ar = struct.unpack(">HHHHHH", msg[:12])
    if qid is not None and rid != qid:
        raise ValueError("response for another query id")
    pos = 12
    for _ in range(qd):
        _, pos = _read_name(msg, pos)
        pos += 4
    records = []
    for section, count in (("answer", an), ("authority", ns)):
        for _ in range(count):
            name, pos = _read_name(msg, pos)
            rtype, _rclass, ttl, rdlen = struct.unpack(">HHIH", msg[pos:pos + 10])
            pos += 10
            rdata = msg[pos:pos + rdlen]
            pos += rdlen
            if rtype == 1 and rdlen == 4:
                value = socket.inet_ntop(socket.AF_INET, rdata)
            elif rtype == 28 and rdlen == 16:
                value = socket.inet_ntop(socket.AF_INET6, rdata)
            elif rtype in (5, 12, 2):
                value = _read_name(msg, pos - rdlen)[0]
            else:
                value = rdata.hex()
            records.append({"section": section, "name": name, "type": rtype, "ttl": ttl, "value": value})
    rcode = flags & 0x000F
    return {
        "rcode": RCODES.get(rcode, str(rcode)),
        "truncated": bool(flags & 0x0200),
        "answers": [r["value"] for r in records if r["section"] == "answer"],
        "records": records,
    }


def dns_query_tcp(server, port, name, qtype="A", timeout=10.0):
    qid = random.SystemRandom().randrange(0, 65536)
    query = dns_build_query(name, QTYPES.get(qtype.upper(), 1), qid)
    t0 = time.monotonic()
    out = {"server": "%s:%d" % (server, port), "name": name, "type": qtype.upper(), "transport": "tcp"}
    try:
        with socket.create_connection((server, port), timeout=timeout) as s:
            s.settimeout(timeout)
            s.sendall(struct.pack(">H", len(query)) + query)
            head = _recv_exact(s, 2)
            msg = _recv_exact(s, struct.unpack(">H", head)[0])
        out.update(dns_parse_response(msg, qid))
    except (OSError, ValueError, struct.error, IndexError) as e:
        out.update({"rcode": None, "error": "%s: %s" % (type(e).__name__, e), "answers": []})
    out["elapsed_ms"] = round((time.monotonic() - t0) * 1000, 1)
    return out


def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("connection closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return buf


def blocked(result):
    """True when a filter answer means "blocked": NXDOMAIN, or only the
    zero addresses (the filter's -blocked-answer zero mode)."""
    if result.get("rcode") == "NXDOMAIN":
        return True
    ans = result.get("answers") or []
    return result.get("rcode") == "NOERROR" and bool(ans) and all(a in ("0.0.0.0", "::") for a in ans)


# ---------------------------------------------------------------------------
# JSON and artifact size
# ---------------------------------------------------------------------------

def json_get(path, dotted):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
    except (OSError, ValueError):
        return ""
    for part in dotted.split("."):
        if isinstance(v, dict) and part in v:
            v = v[part]
        elif isinstance(v, list) and part.isdigit() and int(part) < len(v):
            v = v[int(part)]
        else:
            return ""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (dict, list)):
        return json.dumps(v, sort_keys=True)
    return str(v)


def _all_files(root):
    for d, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            if not os.path.islink(p):
                yield p


def pack(root, limit_mb, optional):
    limit = int(limit_mb * 1024 * 1024)
    omitted = []

    def total():
        return sum(os.path.getsize(p) for p in _all_files(root))

    for pattern in optional:
        if total() <= limit:
            break
        for p in sorted(_all_files(root)):
            rel = os.path.relpath(p, root)
            if fnmatch.fnmatch(rel, pattern) and total() > limit:
                omitted.append("%s (%d bytes): over the artifact's size limit" % (rel, os.path.getsize(p)))
                os.remove(p)
    logs = os.path.join(root, "logs")
    while total() > limit and os.path.isdir(logs):
        files = sorted(_all_files(logs), key=os.path.getsize, reverse=True)
        if not files:
            break
        p = files[0]
        omitted.append("%s (%d bytes): over the artifact's size limit" % (os.path.relpath(p, root), os.path.getsize(p)))
        os.remove(p)
    if omitted:
        with open(os.path.join(root, "omitted.txt"), "a", encoding="utf-8") as f:
            for line in omitted:
                f.write(line + "\n")
    size = total()
    print("pack: %s holds %.1f MB (limit %d MB); %d file(s) left out" % (root, size / 1048576.0, limit_mb, len(omitted)))
    return 0 if size <= limit else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    u = sub.add_parser("ui-find")
    u.add_argument("--id")
    u.add_argument("--text")
    d = sub.add_parser("dns-query")
    d.add_argument("--server", default="127.0.0.1")
    d.add_argument("--port", type=int, required=True)
    d.add_argument("--name", required=True)
    d.add_argument("--type", default="A")
    d.add_argument("--timeout", type=float, default=10.0)
    j = sub.add_parser("json-get")
    j.add_argument("file")
    j.add_argument("path")
    p = sub.add_parser("pack")
    p.add_argument("dir")
    p.add_argument("--limit-mb", type=int, required=True)
    p.add_argument("--optional", action="append", default=[])
    a = ap.parse_args(argv)

    if a.cmd == "ui-find":
        if not a.id and not a.text:
            ap.error("ui-find needs --id or --text")
        hit = ui_find(sys.stdin.read(), a.id, a.text)
        if not hit:
            return 1
        print("%d %d %s %s" % hit)
        return 0
    if a.cmd == "dns-query":
        res = dns_query_tcp(a.server, a.port, a.name, a.type, a.timeout)
        res["blocked"] = blocked(res)
        print(json.dumps(res, sort_keys=True))
        return 0 if res.get("rcode") else 1
    if a.cmd == "json-get":
        print(json_get(a.file, a.path))
        return 0
    if a.cmd == "pack":
        return pack(a.dir, a.limit_mb, a.optional)
    return 2


if __name__ == "__main__":
    sys.exit(main())
