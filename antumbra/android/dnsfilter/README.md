# antumbra-dnsfilter

The tracker-blocking DNS filter of the Antumbra module (layer L2 of the
design). The firewall redirects every DNS query on the phone, from every
app and from the system, to `127.0.0.1:5335`. The filter answers blocked
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
| `lists/antumbra-extra.txt` | Antumbra's own block list (LineageOS, Qualcomm, OnePlus endpoints, Google's ad domains). |
| `lists/allow.txt`, `lists/exodus-exclude.txt` | The allowlist, and the Exodus exclusions (Exodus is off for now). |
| `build.sh` | Builds the two executables (and `listc` for the host); runs the tests and the fuzzers. |
| `fetch-lists.sh` | Downloads the sources and compiles the lists (CI only). |

No third-party code or list is kept here. The Go module cache and the
downloaded lists live outside the repository.

## How queries are answered

In this order:

| Query | Answer | Sent to tor? |
|---|---|---|
| Not a query (a reply, shorter than a header, unparsable header) | none | no |
| Opcode other than QUERY | NOTIMP | no |
| No question, more than one, or a malformed one (a dot inside a label among them) | FORMERR | no |
| Class other than IN, or type ANY, AXFR, IXFR, OPT, 0 or 128-255 | REFUSED | no |
| A name with any byte other than `A-Z a-z 0-9 - _` in a label (NUL and other control bytes, spaces, UTF-8), an empty label, a label over 63 bytes or more than 253 bytes in all | NXDOMAIN, counted as `bad_name` | no |
| The root name (`.`) | empty answer | no |
| `localhost` and names below it | A 127.0.0.1; other types empty | no |
| Local names: `.local`, `.lan`, `.home`, `.home.arpa`, `.internal`, `.intranet`, `.private`, `.localdomain`, `.corp`, `.test`, `.invalid`, `.alt`, `fritz.box`, and reverse lookups of private, loopback, link-local, shared, benchmarking (198.18.0.0/15), IETF (192.0.0.0/24) and documentation addresses | NXDOMAIN | no |
| A name on the block list, or below one | NXDOMAIN (or, with `-blocked-answer zero`, A 0.0.0.0 / AAAA ::) | no |
| AAAA (IPv6 is off on the phone) | empty answer | no |
| Any type but A, AAAA and PTR (tor's DNSPort answers only those) | empty answer | no |
| A and PTR (and AAAA with `-aaaa forward`) | tor's answer | yes |

Why bad names are refused: the list holds plain names, so `doubleclick.net`
followed by a NUL byte matches nothing, but tor reads names as C strings
(libevent's `evdns`) and cuts them at the NUL: it would look up
`doubleclick.net` at an exit. Any app could get blocked names resolved that
way, or carry data in labels to a tracker's own name server. Only names
made of letters, digits, `-` and `_` are matched and forwarded; the fuzz
test checks that nothing else ever reaches tor. Names with other bytes do
not exist on the Internet in practice (international names travel as
`xn--` punycode).

Answers made by the filter carry an SOA record with a 60-second TTL
(`-blocked-ttl`), so Android's resolver caches them. `.onion` and `.exit`
names go to tor, which maps them (`AutomapHostsOnResolve`).

What reaches tor is a new query: a fresh random ID and only the question.
Nothing else from the app's message (EDNS options such as a client subnet,
cookies, other sections) goes further. From tor's reply only A, AAAA, PTR
and CNAME records are kept (at most 32). A CNAME that points at a blocked
name, or at a name with bytes that cannot be matched, makes the whole
answer blocked; tor's DNSPort never sends CNAMEs, so this matters only if
the upstream changes. Replies over UDP longer than 512 bytes are sent with
TC set and no records, and the client asks again over TCP (the filter does
not speak EDNS).

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
exchange, and again once the reply has arrived, the filter reads
`/proc/net/udp` and `/proc/net/udp6` (or the `tcp` tables with
`-upstream-net tcp`) and uses the answer only if every socket that can
receive traffic for `127.0.0.1:9053` belongs to uid 2950 (`-upstream-uid`).
If one does not, or the tables cannot be read, the answer is SERVFAIL
(status code `owner` or `owner-unknown`).

What the check cannot do on its own: a socket that binds the port, receives
the query and closes again between the two reads is not seen. It has
learnt the name (the query then times out), and it could have answered.
Only the firewall can stop its answer: `antumbra-fw` must drop packets
from source port 9053 (and from the filter's own 5335 and 5380, and tor's
9040) that do not belong to the port's rightful uid. That rule belongs to
the firewall part; until it is there, this check narrows the window but
does not close it.

Cost: each forwarded query reads the UDP tables twice. On the build
machine one check takes about 26 µs (`go test -bench OwnerCheck
./internal/dnsfilter`, nearly empty tables). On the phone's 4.14 kernel
each read walks the whole UDP hash table; that cost is not measured yet.

On the phone this needs read access to `/proc/net` for the filter's
SELinux domain (the `proc_net` type). `-upstream-uid -1` turns the check
off; do not do that on the phone.

### Other hardening

- Refuses to run with root's uid or gid as any of its real, effective,
  saved or file-system ids, in the supplementary groups root (0),
  `net_raw` (3004) or `net_admin` (3005), which carry network powers on
  kernels built with `CONFIG_ANDROID_PARANOID_NETWORK`, or with any
  permitted, effective or ambient capability (`-insecure-allow-privileged`
  is for tests only). Sets `PR_SET_NO_NEW_PRIVS`.
- Listens only on IPv4 loopback addresses, and binds its UDP socket
  without `SO_REUSEADDR`, so no other socket can share `127.0.0.1:5335`
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
list paths. The module starts it: `start_dnsfilter` in
`../module/lib/antumbra.sh`, through the module's helper `antumbra-run`:

```sh
antumbra-run -u 2951 -g 2951 -G 3003 -s -- antumbra-dnsfilter \
    -list /data/adb/antumbra/lists/dnsfilter.list -list $MODDIR/lists/dnsfilter.list
```

That is: uid and gid 2951; supplementary group `inet` (3003) and no other,
because a kernel built with `CONFIG_ANDROID_PARANOID_NETWORK` lets only
that group open IPv4 sockets; every capability dropped (the filter refuses
to start otherwise); after the firewall's `arm`, so that nothing leaves
before it is ready; standard error appended to
`/data/adb/antumbra/log/dnsfilter.log`; read access to the list files, to
`/data/adb/antumbra/run/status.json` and to `/proc/net`.

The first `-list` that loads and verifies is used: the updated copy if
there is one, else the copy shipped in the module.

| Flag | Default | Meaning |
|---|---|---|
| `-listen` | `127.0.0.1:5335` | UDP and TCP address (IPv4 loopback only) |
| `-status-listen` | `127.0.0.1:5380` | status page (loopback only; `""` turns it off) |
| `-status-refresh` | `1m` | take the status page's counters and upstream state afresh at most this often; `0` shows them live |
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
| `-debug-log-queries` | off | log every name and decision (CI emulator only; see below) |
| `-self-test` | | check the filter on loopback with a fake tor, then exit |
| `-check-list FILE` | | verify a list and print its summary, then exit |
| `-version` | | print the version, then exit |

Signals: `SIGHUP` reloads the list; `SIGINT` and `SIGTERM` stop the filter.

`-debug-log-queries` is for the CI emulator, where the leak test lists
every name the system looked up. Never on the phone: it writes every name
to the log. It adds one line per query to standard error, after the
startup line `debug mode: query names will be logged`:

```
antumbra-dnsfilter: 2026/10/11 06:38:19 query "www.example.org." A -> forwarded
antumbra-dnsfilter: 2026/10/11 06:38:19 query "x.doubleclick.net." AAAA -> blocked
antumbra-dnsfilter: 2026/10/11 06:38:20 query "doubleclick.net\x00." A -> nxdomain (bad name)
```

The name is quoted as Go's `%q` does (`\x00` for a NUL, `\"` for a quote),
with its final dot and the letter case the app used; the type is `A`,
`AAAA`, `PTR`, `HTTPS` and so on (a number for unknown types); the
decision is one of `forwarded`, `forwarded nxdomain`, `blocked`,
`blocked (cname)`, `local`, `empty (type)`, `empty (root)`,
`nxdomain (bad name)`, `refused (class)`, `refused (type)` or
`servfail (CODE)`, where CODE is one of the status page's `last_error`
codes, or `rcode` and tor's own error code.
Queries that are not answered or not parsed (FORMERR, NOTIMP, dropped)
are not logged.

### Status page

`GET http://127.0.0.1:5380/status` (also `HEAD`) returns one JSON object.
Only the host names `127.0.0.1`, `localhost` and `::1` are answered (a web
page that rebinds its own name to 127.0.0.1 gets 421). Example:

```json
{
 "service": "antumbra-dnsfilter", "version": "0.1.0", "uptime_seconds": 2,
 "queries": 13, "blocked": 5, "forwarded": 3, "local": 3, "servfail": 1,
 "refused": 1, "formerr": 0, "notimp": 0, "bad_name": 0, "rate_limited": 0,
 "dropped": 0, "upstream_errors": 1,
 "list": {"loaded": true, "version": "20261011", "size": 196477, "exceptions": 0,
          "sha256": "5b9cdb69…", "loaded_at": "2026-10-11T06:38:17Z"},
 "upstream": {"address": "127.0.0.1:9053", "network": "udp", "owner_uid": 2950,
              "state": "ok", "last_seen": "2026-10-11T06:38:19Z"},
 "policy": {"blocked_answer": "nxdomain", "filter_aaaa": true, "local_names": true},
 "module": {"dnsfilter": {"running": true},
            "firewall": {"hash": "3f2a9c0d5e7b1a42", "state": "live"},
            "module": {"problem": "", "updated": "2026-10-11T06:38:15Z", "version": "0.1.0"},
            "schema": 1,
            "tor": {"bootstrap": 100, "error": "", "network": "enabled", "running": true,
                    "summary": "Done"},
            "welcome": {"started": true}}
}
```

(`module` here is the `status.json` that `status_write` in
`../module/lib/antumbra.sh` writes.)

`upstream.state` is `unknown` before the first forwarded query, then `ok`
or `error` with `last_error` one of `refused`, `timeout`, `owner`,
`owner-unknown`, `malformed`, `io`, `overload`. `list.reload_error`
appears after a failed reload. `module` is the module's `status.json`,
or `null` when it is missing; `module_error` says why when it is
unreadable, larger than 64 KiB or not JSON.

Every app on the phone can read this page (the firewall lets every uid
reach 5380). Two things follow. The counters and the upstream state
(`last_seen` included) are taken afresh at most once a minute
(`-status-refresh`), so that an app cannot watch them move with other
apps' lookups. And `welcome.session_id` is removed from the module's part
before it is shown; everything else in `status.json` is passed on (with
its keys sorted), so the module must not put anything there that apps
should not read.
The firmer fix, letting only Welcome's uid and the shell reach 5380, is
the firewall's.

## The block list

### File format

```
# antumbra-dnsfilter block list
# format: 1
# version: 20261011
# entries: 196477
# exceptions: 0
# body-sha256: <SHA-256 of everything after the header>
# source hagezi-pro format=domains valid=193358 … sha256=… from=https://…
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
| HaGeZi Multi PRO, wildcard form (it includes HaGeZi's OPPO/Realme native list) | 193,358 | GPL-3.0 |
| HaGeZi Encrypted DNS Bypass (DoH/DoT server names, so apps fall back to the system's lookups) | 3,272 | GPL-3.0 |
| `antumbra-extra.txt` | 9 | GPL-3.0 |
| Result | 196,477 | |
| Exodus Privacy tracker list: **off** (see below) | | ODbL 1.0, contents DbCL 1.0 |

The list is the same for everyone, so it does not single anyone out.

The Exodus Privacy tracker list is off until queue item DNS3 is settled,
for two reasons. Its network signatures are regular expressions written to
recognise SDKs in app code, not block-list entries. Read as domains, 203 of
its 622 are in no HaGeZi list, and many of those block more than a
tracker: whole company sites (`matomo.org`, `qualtrics.com`,
`onesignal.com`, `dynatrace.com`, `urbanairship.com`), Huawei's whole
cloud (`hicloud.com`), and working services (Mapbox map tiles, the GIPHY
API, ID-verification SDKs that banking apps use). And its data is under
the Open Database Licence 1.0 (contents: Database Contents Licence 1.0;
Exodus' own README), whose attribution and share-alike terms have not
been checked against HaGeZi's GPL-3.0 for one merged list. Turning it back
on means: settle the licence, review those 203 entries into
`exodus-exclude.txt`, and uncomment the three lines in `sources.conf`.
`doubleclick.net`, which only Exodus blocked as a whole (HaGeZi lists only
its ad subdomains), is now in `antumbra-extra.txt`, with
`googleadservices.com`.

`guard` lines name sites that no source may block as a whole (google.com,
wikipedia.org, torproject.org, f-droid.org, lineageos.org, github.com and
others). If an update blocks one of them, or a parent of one, `listc`
fails and the CI job stops; this catches over-broad entries and a poisoned
source.

`fetch-lists.sh` also writes `doh-ipv4.txt` from HaGeZi's DoH server
addresses (1,434), for `antumbra-fw`, which reads it from
`/data/adb/antumbra/lists/doh-ipv4.txt`. Only single addresses are taken
(a `/32`, or no prefix); a wider prefix is counted as invalid, so that a
bad download cannot make the firewall reject whole ranges for every app.
Private, loopback, link-local, shared, multicast, reserved and
documentation addresses are left out too, so the firewall never rejects
the phone's own services. More than 4,096 addresses stop the build, as
fewer than `MIN` do.

### Updating the lists

In CI only, never on the phone:

```sh
antumbra/android/dnsfilter/fetch-lists.sh --out OUT [--version 20261011] [--fallback DIR]
```

It downloads every `https://` source with curl (HTTPS only, also after
redirects; TLS 1.2 or later, verified; at most 64 MiB; retried), keeps
each download under `OUT/sources/` (with `OUT/sources/SHA256SUMS`), and
writes `OUT/dnsfilter.list`, `OUT/doh-ipv4.txt` and `OUT/SHA256SUMS`,
which lists only those two files, so that it still checks once they are
copied without the downloads. The lists change several times a day, so
their content cannot be pinned in advance; the URLs are pinned, each
download's SHA-256 is written into the list header, and `MIN` in
`sources.conf` stops the build on a truncated or empty download.

- `--fallback DIR`: when a download fails, use `DIR/NAME` (an earlier
  `OUT/sources`, for example from a CI cache) and write a line to
  `OUT/warnings.txt` (empty otherwise) instead of failing. The copy goes
  through the same checks (`MIN`, guards, `--expect`).
- `--downloads DIR --expect NAME=SHA256`: rebuild an earlier list from
  saved downloads, refusing any that differ.
- `--sources FILE`: another sources file (tests, or trying a source).

The output depends only on the inputs and the version.

## Building

```sh
antumbra/android/dnsfilter/build.sh --out OUT [--version V] [--test] [--fuzz 60s] [--check [--require-selftest]]
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
different output directories, the executables and the `.buildinfo` files
are byte-identical (checked).

- `--test` runs `go vet` and the tests, under the race detector when a C
  compiler is there (the race detector needs cgo; the shipped executables
  do not use it).
- `--fuzz TIME` runs `FuzzHandle` and `FuzzReply` for TIME each. A failing
  input is written to `internal/dnsfilter/testdata/fuzz/`; keep it there
  as a regression test once fixed.
- `--check` checks the ELF header and static linking and runs `-self-test`
  (natively for x86_64, under `qemu-aarch64` or `qemu-aarch64-static` for
  arm64 when one is installed). With `--require-selftest`, a self-test
  that cannot run fails the build instead of being skipped. Meant for CI
  with `qemu-user-static` installed, so that the arm64 build has run
  before it ships.

## Testing

```sh
cd antumbra/android/dnsfilter
go vet ./... && go test -race ./...
go test -run '^$' -fuzz '^FuzzHandle$' -fuzztime 60s ./internal/dnsfilter
go test -run '^$' -fuzz '^FuzzReply$'  -fuzztime 60s ./internal/dnsfilter
```

(`build.sh --test --fuzz 60s` runs the same.) The tests cover name
matching and the list format; the source parsers, the reduction, the
guards and the DoH address limits; the wire format (malformed queries,
opcodes, classes, types, names with NUL, control and other bytes, the
root, truncation, ID and question echo); failing closed (tor down, slow,
wrong ID, wrong question, malformed reply, wrong socket owner, a socket
that joins the port while a query is out, over UDP and TCP, overload); TCP
framing (pipelined, dribbled, short, cut, idle, connection cap); the rate
limit; that no other socket can share the port; the privilege checks; the
status page (the once-a-minute counters, the session ID kept off it); and
the whole program on loopback with a fake tor, including SIGHUP reloads
and shutdown. `FuzzHandle` feeds arbitrary bytes as queries and checks
that every name that reaches tor is a plain name; `FuzzReply` feeds them
as tor's replies.

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
- The filter listened on 5353 until the first emulator run showed
  Android's mDNS service (uid 1020) already holding `0.0.0.0:5353` when the
  module starts, so the filter could not bind and DNS stopped (closed, not
  open). 5335 is a port no Android component is known to use; the module's
  port check still treats any other holder as a squatter.
- If the filter is not running, nothing answers on 5335 and DNS fails.
  Any app could then bind 127.0.0.1:5335 (or 5380) itself, receive every
  app's lookups and answer them; the same holds for tor's 9040 and 9053
  while tor's network is off. Only the firewall (dropping replies from
  those ports that do not come from the right uid) and the module
  (checking who holds them) can close this; see the upstream owner check
  above.
- The upstream owner check leaves a short window (above), and its cost on
  the phone is not measured.
- The status page is readable by every app; its counters are only
  coarsened, not hidden.
- The Exodus Privacy tracker list is off (licence and over-blocking; see
  Sources).
