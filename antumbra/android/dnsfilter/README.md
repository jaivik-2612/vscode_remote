# antumbra-dnsfilter

The tracker-blocking DNS filter of the Antumbra module (layer L2 of the
design). The firewall redirects every DNS query on the phone, from every
app and from the system, to `127.0.0.1:5353`. The filter answers blocked
names and local names itself and forwards everything else to tor's DNSPort
on `127.0.0.1:9053`. If tor does not answer, the query fails: there is no
other server, so the filter fails closed.

It is a small Go program: the standard library plus
`golang.org/x/net/dns/dnsmessage` (the Go team's DNS message parser), pinned
in `go.sum`. It runs as uid/gid 2951 with no capabilities, as a static
executable that needs nothing from Android.

| File | What it is |
|---|---|
| `cmd/antumbra-dnsfilter/` | The filter (`main.go`), its privilege checks and its `-self-test`. |
| `cmd/listc/` | The list compiler: merges the sources into one block list. Runs in CI only. |
| `internal/dnsfilter/` | Query policy, the upstream (tor) exchange, the UDP/TCP listeners, rate limits. |
| `internal/blocklist/` | The block-list file format: reading, checking, writing, matching. |
| `internal/listc/` | Source formats, `sources.conf`, merging and reduction. |
| `internal/status/` | The status page on `127.0.0.1:5380`. |
| `internal/fakedns/` | A stand-in for tor's DNSPort, for the tests and the self-test. |
| `lists/sources.conf` | Where the lists come from (pinned URLs), exclusions, guards. |
| `lists/antumbra-extra.txt` | Antumbra's own block list (LineageOS, Qualcomm, OnePlus endpoints). |
| `lists/allow.txt`, `lists/exodus-exclude.txt` | The allowlist and the Exodus exclusions. |
| `build.sh` | Builds the two executables (and `listc` for the host). |
| `fetch-lists.sh` | Downloads the sources and compiles the lists (CI only). |

No third-party code or list is kept here. The Go module cache and the
downloaded lists live outside the repository.

## How queries are answered

In this order:

| Query | Answer | Sent to tor? |
|---|---|---|
| Not a query (a reply, shorter than a header, unparsable header) | none | no |
| Opcode other than QUERY | NOTIMP | no |
| No question, more than one, or a malformed one | FORMERR | no |
| Class other than IN, or type ANY, AXFR, IXFR, OPT, 0 or 128-255 | REFUSED | no |
| `localhost` and names below it | A 127.0.0.1; other types empty | no |
| Local names: `.local`, `.lan`, `.home`, `.home.arpa`, `.internal`, `.localdomain`, `.corp`, `.test`, `.invalid`, `.alt`, and reverse lookups of private, loopback, link-local, shared and documentation addresses | NXDOMAIN | no |
| A name on the block list, or below one | NXDOMAIN (or, with `-blocked-answer zero`, A 0.0.0.0 / AAAA ::) | no |
| AAAA (IPv6 is off on the phone) | empty answer | no |
| Any type but A, AAAA and PTR (tor's DNSPort answers only those) | empty answer | no |
| A and PTR (and AAAA with `-aaaa forward`) | tor's answer | yes |

Answers made by the filter carry an SOA record with a 60-second TTL
(`-blocked-ttl`), so Android's resolver caches them. `.onion` and `.exit`
names go to tor, which maps them (`AutomapHostsOnResolve`).

What reaches tor is a new query: a fresh random ID and only the question.
Nothing else from the app's message (EDNS options such as a client subnet,
cookies, other sections) goes further. From tor's reply only A, AAAA, PTR
and CNAME records are kept (at most 32). A CNAME that points at a blocked
name makes the whole answer blocked; tor's DNSPort never sends CNAMEs, so
this matters only if the upstream changes. Replies over UDP longer than
512 bytes are sent with TC set and no records, and the client asks again
over TCP (the filter does not speak EDNS).

### Failing closed

- tor not listening (DisableNetwork 1 before the Welcome screen, offline
  mode, or tor dead): SERVFAIL at once.
- tor slow: SERVFAIL after `-upstream-timeout` (4 s, below Android's 5 s).
- tor's reply malformed, for another ID or another question: ignored, then
  SERVFAIL. tor's own SERVFAIL, REFUSED or NOTIMP: SERVFAIL.
- More than `-max-inflight` (128) queries waiting for tor: SERVFAIL.
- The upstream must be an IPv4 loopback address; the filter refuses to
  start otherwise. There is no fallback server.
- No block list loads at start: the filter exits (status 1), so DNS stops
  rather than running unfiltered. `-allow-no-list` exists for development.
- A list that fails to load on SIGHUP is refused; the previous list stays.

### The upstream owner check

tor opens its DNSPort with `SO_REUSEADDR`, and does not open it at all
while `DisableNetwork` is 1. Any app can then bind `127.0.0.1:9053` itself,
alone or next to tor (Linux gives each datagram to the most recently bound
socket). It would see every name the filter forwards and could answer
them, and the firewall lets its answers through as replies. So before each
exchange the filter reads `/proc/net/udp` and `/proc/net/udp6` (or the
`tcp` tables with `-upstream-net tcp`) and talks to the port only if every
socket that can receive traffic for `127.0.0.1:9053` belongs to uid 2950
(`-upstream-uid`). If one does not, or the tables cannot be read, the
answer is SERVFAIL (status code `owner` or `owner-unknown`).

On the phone this needs read access to `/proc/net` for the filter's
SELinux domain (the `proc_net` type). `-upstream-uid -1` turns the check
off; do not do that on the phone.

### Other hardening

- Refuses to run as root or with any permitted, effective or ambient
  capability (`-insecure-allow-privileged` is for tests only). Sets
  `PR_SET_NO_NEW_PRIVS`.
- Listens only on IPv4 loopback addresses, and binds its UDP socket
  without `SO_REUSEADDR`, so no other socket can share `127.0.0.1:5353`
  (tested).
- Rate limit per client address and port (default 20 queries/s, bursts of
  40; over it, UDP queries are dropped and TCP connections closed); at most
  256 UDP queries in progress, 64 TCP connections, 1000 queries and a 10 s
  idle time per connection.
- Never logs a query name, unless started with `-debug-log-queries`. The
  status page has counters only.
- A panic while answering one query drops that query, not the filter.

## Running it

Defaults are the shared contract, so on the phone the filter needs only its
list paths. The module's `service.sh` must start it:

- as uid 2951 and gid 2951, with every capability dropped (with Magisk's
  `su`, `--drop-cap`; the filter refuses to start otherwise);
- after the firewall's `arm`, so that nothing leaves before it is ready;
- with its standard error appended to `/data/adb/antumbra/log/`;
- with read access to the list files, to `/data/adb/antumbra/run/status.json`
  (the run directory is 0751 for this) and to `/proc/net`.

For example (the module part decides the exact launcher):

```sh
su 2951 -g 2951 --drop-cap -c "exec $MODDIR/bin/antumbra-dnsfilter \
    -list /data/adb/antumbra/lists/dnsfilter.list \
    -list $MODDIR/lists/dnsfilter.list" \
    >>/data/adb/antumbra/log/dnsfilter.log 2>&1 &
```

The first `-list` that loads and verifies is used: the updated copy if
there is one, else the copy shipped in the module.

| Flag | Default | Meaning |
|---|---|---|
| `-listen` | `127.0.0.1:5353` | UDP and TCP address (IPv4 loopback only) |
| `-status-listen` | `127.0.0.1:5380` | status page (loopback only; `""` turns it off) |
| `-upstream` | `127.0.0.1:9053` | tor's DNSPort (IPv4 loopback only) |
| `-upstream-net` | `udp` | `udp` or `tcp` (tor's DNSPort is UDP only) |
| `-upstream-timeout` | `4s` | wait for tor before SERVFAIL |
| `-upstream-uid` | `2950` | uid that must own the upstream port; `-1` skips the check |
| `-list` | `/data/adb/antumbra/lists/dnsfilter.list` | block list; repeat for fallbacks |
| `-blocked-answer` | `nxdomain` | or `zero` (0.0.0.0 and ::) |
| `-blocked-ttl` | `60` | TTL of answers made by the filter |
| `-aaaa` | `empty` | or `forward` |
| `-local-names` | `true` | answer local names here |
| `-rate`, `-burst` | `20`, `40` | per-client-port limit; `-rate 0` turns it off |
| `-max-inflight` | `128` | queries waiting for tor at once |
| `-max-tcp-conns` | `64` | open TCP connections |
| `-module-status` | `/data/adb/antumbra/run/status.json` | shown under `"module"` |
| `-bind-wait` | `10s` | keep retrying the bind this long |
| `-debug-log-queries` | off | log every name and decision |
| `-self-test` | | check the filter on loopback with a fake tor, then exit |
| `-check-list FILE` | | verify a list and print its summary, then exit |
| `-version` | | print the version, then exit |

Signals: `SIGHUP` reloads the list; `SIGINT` and `SIGTERM` stop the filter.

### Status page

`GET http://127.0.0.1:5380/status` (also `HEAD`) returns one JSON object.
Only the host names `127.0.0.1`, `localhost` and `::1` are answered (a web
page that rebinds its own name to 127.0.0.1 gets 421). Example:

```json
{
 "service": "antumbra-dnsfilter", "version": "0.1.0", "uptime_seconds": 2,
 "queries": 13, "blocked": 5, "forwarded": 3, "local": 3, "servfail": 1,
 "refused": 1, "formerr": 0, "notimp": 0, "rate_limited": 0, "dropped": 0,
 "upstream_errors": 1,
 "list": {"loaded": true, "version": "20261011", "size": 195887, "exceptions": 0,
          "sha256": "4da468eb…", "loaded_at": "2026-10-11T06:38:17Z"},
 "upstream": {"address": "127.0.0.1:9053", "network": "udp", "owner_uid": 2950,
              "state": "ok", "last_seen": "2026-10-11T06:38:19Z"},
 "policy": {"blocked_answer": "nxdomain", "filter_aaaa": true, "local_names": true},
 "module": {"fw": {"armed": "3f2a9c"}, "tor": {"mode": "offline"}}
}
```

`upstream.state` is `unknown` before the first forwarded query, then `ok`
or `error` with `last_error` one of `refused`, `timeout`, `owner`,
`owner-unknown`, `malformed`, `io`. `list.reload_error` appears after a
failed reload. `module` is the module's `status.json` as it is, or `null`
when it is missing; `module_error` says why when it is unreadable, larger
than 64 KiB or not JSON.

## The block list

### File format

```
# antumbra-dnsfilter block list
# format: 1
# version: 20261011
# entries: 195887
# exceptions: 0
# body-sha256: <SHA-256 of everything after the header>
# source hagezi-pro format=domains valid=195726 … sha256=… from=https://…
@@exception.example        (allowlist entries, sorted)
blocked.example            (blocked domains, sorted)
```

A blocked domain blocks itself and every name below it. An exception
unblocks itself and every name below it, whatever the block entries say.
The filter refuses a file whose body hash, counts, order or entries are
wrong. A lookup walks the name's suffixes with a binary search each. With
the 195,887-entry list on x86-64: about 0.4 µs per lookup, 50 ms to load,
16 MB resident for the whole process (measured; not yet on the phone).

### Sources

`lists/sources.conf` names them; `listc` merges them and drops entries
already covered by a parent, entries the allowlist covers and allowlist
entries with no effect. Checked on 2026-10-11:

| Source | Entries | Licence |
|---|---|---|
| HaGeZi Multi PRO, wildcard form (it includes HaGeZi's OPPO/Realme native list) | 195,726 | GPL-3.0 |
| HaGeZi Encrypted DNS Bypass (DoH/DoT server names, so apps fall back to the system's lookups) | 3,276 | GPL-3.0 |
| Exodus Privacy tracker list, network signatures read as domains | 622 signature domains (9 regular expressions skipped; 7 too-broad domains excluded) | not yet confirmed (see below) |
| `antumbra-extra.txt` | 7 | GPL-3.0 |
| Result | 195,887 | |

The list is the same for everyone, so it does not single anyone out.

`guard` lines name sites that no source may block as a whole (google.com,
wikipedia.org, torproject.org, f-droid.org, lineageos.org, github.com and
others). If an update blocks one of them, or a parent of one, `listc`
fails and the CI job stops; this catches over-broad entries and a poisoned
source. Exodus signatures that name a whole service (`\.facebook\.com`,
`\.google\.com`, Microsoft sign-in, Baidu and Tencent maps, firebase.com)
are excluded by `exodus-exclude.txt`.

`fetch-lists.sh` also writes `doh-ipv4.txt` from HaGeZi's DoH server
addresses (1,434), for `antumbra-fw`, which reads it from
`/data/adb/antumbra/lists/doh-ipv4.txt`. Private, loopback, link-local,
shared, multicast, reserved and documentation addresses are left out, so a
bad download cannot make the firewall reject the phone's own services.

### Updating the lists

In CI only, never on the phone:

```sh
antumbra/android/dnsfilter/fetch-lists.sh --out OUT [--version 20261011]
```

It downloads every `https://` source with curl (HTTPS only, also after
redirects; TLS 1.2 or later, verified; at most 64 MiB; retried), keeps
each download under `OUT/sources/`, and writes `OUT/dnsfilter.list`,
`OUT/doh-ipv4.txt` and `OUT/SHA256SUMS`. The lists change several times a
day, so their content cannot be pinned in advance; the URLs are pinned,
each download's SHA-256 is written into the list header, and `MIN` in
`sources.conf` stops the build on a truncated or empty download.
`--downloads DIR --expect NAME=SHA256` rebuilds an earlier list from saved
downloads and refuses any that differ. The output depends only on the
inputs and the version.

## Building

```sh
antumbra/android/dnsfilter/build.sh --out OUT [--version V] [--test] [--check]
```

Needs Go (any version from 1.21 on can start it: the go command fetches the
pinned toolchain, go1.27.2, and checks it against the Go checksum
database). Writes:

- `OUT/arm64-v8a/antumbra-dnsfilter` (about 6.4 MB) for the phone,
- `OUT/x86_64/antumbra-dnsfilter` (about 6.9 MB) for the CI emulator,
- `OUT/<abi>/antumbra-dnsfilter.buildinfo` and `OUT/SHA256SUMS`,
- `OUT/host/listc` (not shipped).

They are static Linux executables (`CGO_ENABLED=0`): Android's kernel runs
them directly, with no bionic and no linker. Go 1.27 needs Linux 3.2 or
later; the phone has 4.14. The build is reproducible: built twice, from two
different directories, the executables are byte-identical (checked).
`--check` checks the ELF header and static linking and runs `-self-test`
(natively for x86_64, under `qemu-aarch64` for arm64 when it is installed).

## Testing

```sh
cd antumbra/android/dnsfilter
go vet ./... && go test -race ./...
go test -run '^$' -fuzz '^FuzzHandle$' -fuzztime 60s ./internal/dnsfilter
go test -run '^$' -fuzz '^FuzzReply$'  -fuzztime 60s ./internal/dnsfilter
```

The tests cover name matching and the list format; the source parsers, the
reduction and the guards; the wire format (malformed queries, opcodes,
classes, types, truncation, ID and question echo); failing closed (tor
down, slow, wrong ID, wrong question, malformed reply, wrong socket owner,
overload); TCP framing (pipelined, dribbled, short, cut, idle, connection
cap); the rate limit; that no other socket can share the port; the status
page; and the whole program on loopback with a fake tor, including SIGHUP
reloads and shutdown. `FuzzHandle` feeds arbitrary bytes as queries,
`FuzzReply` as tor's replies.

`antumbra-dnsfilter -self-test [-list FILE]` runs the same checks inside
the shipped executable, without root and without the real ports: on the
phone in Termux before the module is installed, or under qemu-user. In
Termux, `/proc/net` is not readable to apps, so the owner check is skipped
there and says so.

## Known limits

- The filter cannot see what tor's resolver hides: CNAME chains are
  resolved at the exit, so trackers behind another name (CNAME cloaking)
  pass unless their final name is listed.
- It cannot stop apps that resolve names some other way: DNS-over-HTTPS to
  servers on neither list, hard-coded addresses, or a tor of their own
  (Tor Browser is deliberately not filtered).
- Port 5353 is also the mDNS port. Android's mDNS sockets bind it with
  `SO_REUSEADDR` on each interface; whichever binds first keeps it. The
  filter starts early in `service.sh` and retries for `-bind-wait`; if
  Android's mDNS holds the port, the filter cannot start and DNS stops
  (closed, not open).
- If the filter is not running, nothing answers on 5353 and DNS fails.
  Any app could then bind 127.0.0.1:5353 itself; the firewall would let its
  answers back as replies (see the cross-part notes in the report).
- The licence of the Exodus Privacy tracker data is not yet confirmed; it
  must be before a list containing it is published.
