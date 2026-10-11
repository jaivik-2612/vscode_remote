# antumbra-fw: the Tor-only firewall

`antumbra-fw` is the firewall of the Antumbra Magisk module on LineageOS 23.2
(Android 16, kernel 4.14). It lets only tor's own process reach the network.
Other TCP is passed into tor's TransPort, DNS goes to the DNS filter, and
everything else is refused, for apps, system services and root alike. It is
a POSIX sh script that calls `iptables`, `ip6tables` and their `-restore`
tools, so it runs under Android's mksh and toybox, under Magisk's busybox ash,
and under dash or bash on Linux for the tests.

The rules were written from scratch for Android. They are not a translation
of Tails' rules or of the archived Debian Antumbra's `nftables.conf`, which
give Tails' one trusted desktop user three exceptions that would be leaks
here: direct access to the local network, any loopback TCP port (including
tor's ControlPort), and "accept established" for everyone. The design checks
rated that a blocker (see [Why not Tails' rules](#why-not-tails-rules)).

## Commands

| Command | What it does | Exit status |
|---|---|---|
| `antumbra-fw arm` | Loads the arm set: only loopback traffic is allowed, IPv4 and IPv6; no packet leaves on, arrives from, or is forwarded between other interfaces. One `iptables-restore` call per address family. `post-fs-data.sh` runs it first, before zygote starts. If `iptables-restore` fails or is missing, it loads the same rules one command at a time ([below](#the-arm-set)). Each family is armed on its own: a missing `ip6tables` does not stop IPv4 from being armed. | 0 both armed, 1 not |
| `antumbra-fw apply` | Loads the full rule set, checks it in the kernel, records its SHA-256 in `$ANTUMBRA_DIR/state/fw/fw.hash` and prints it (64 hex digits, alone on standard output). On any failure it goes back to the armed state. Needs all four tools. | 0 live, 1 failed (armed) |
| `antumbra-fw status` | Prints `state=`, `ipv4=`, `ipv6=`, `hash=` (the Antumbra rules now in the kernel) and `recorded=` (the hash of the last successful apply). | 0 live, 1 armed, 2 partial, 3 open or unknown |
| `antumbra-fw flush` | Goes back to the armed state and deletes the full rule set. It never opens the network: an applied rule is removed only once the arm set is in front of it, so if the arm set cannot be put in front (a failing `iptables-restore` and failing single commands, as an xtables-lock timeout would cause), the rules that are loaded stay and it exits 1. | 0 armed, 1 not |
| `antumbra-fw print` | Prints the full rule set as `iptables-restore` input without loading it. Needs no root. Not part of the contract; for review and debugging. | 0 |

`state=live` means: every Antumbra jump is the first rule of its built-in
chain in both families, no arm jump is left, the FORWARD policy is DROP, and
the hash of the Antumbra rules in the kernel equals the recorded one.
`armed` means the three arm jumps are first in both families and the arm
chains are intact. `partial` means both egress gates (mangle POSTROUTING and
filter OUTPUT) are Antumbra's in both families, but the rules are neither the
recorded full set nor the arm set (a failed or tampered load); nothing leaves
except what those gates allow. `open` means an egress gate is missing.

How the module uses it (`module/post-fs-data.sh`, `module/service.sh` and
`fw()`/`fw_publish()` in `module/lib/antumbra.sh`; the module part owns them):

```sh
# post-fs-data.sh, blocking, before anything else; /dev is in RAM
ANTUMBRA_DIR=/dev/antumbra-fw "$MODDIR/bin/antumbra-fw" arm
# service.sh, after tor (uid 2950) and the DNS filter (uid 2951) are started:
# the firewall gets a root-only directory and the input files by name
fw() {
	ANTUMBRA_DIR=/data/adb/antumbra/state/module/fw \
		ANTUMBRA_FW_EXEMPT=/data/adb/antumbra/state/fw-exempt.conf \
		ANTUMBRA_FW_RELAYS=/data/adb/antumbra/state/fw-relays.conf \
		ANTUMBRA_FW_DOH=/data/adb/antumbra/lists/doh-ipv4.txt \
		"$MODDIR/bin/antumbra-fw" "$@"
}
if hash=$(fw apply) && [ "$(fw status | sed -n 's/^hash=//p')" = "$hash" ]; then
	resetprop -n antumbra.fw.armed "$(echo "$hash" | cut -c1-16)"
else
	resetprop --delete antumbra.fw.armed; fw flush
fi
# every 30 s: 'fw status'; when it is not live, remove the property and apply again
```

The firewall keeps its lock (`fw.lock`, a directory) and the recorded hash
(`fw.hash`) in its own directory, `$ANTUMBRA_DIR/state/fw` (or
`ANTUMBRA_FW_DIR`), never in `run/`, which belongs to tor (uid 2950)
because tor insists on owning its ControlSocket's directory. It creates the
directory (mode 0700) when it is missing, and writes there only when the
directory and its parent are real directories (not links) owned by root and
writable by no one else; the temporary hash file is created with
no-clobber semantics (`O_EXCL`). Otherwise `apply` fails, `status` reports
no recorded hash, and `arm` and `flush` go ahead without the lock. `apply`
takes the lock so that two applies cannot interleave; `arm` and `flush` take
it when they can and go ahead anyway when they cannot, because arming is
always safe.

### Files it reads

All three are optional. Invalid lines are left out with a warning on standard
error: an app loses its exemption, or a server stays reachable through Tor.
A bad line never opens anything.

| File | Format | Meaning |
|---|---|---|
| `$ANTUMBRA_DIR/state/fw-exempt.conf` | `<uid> [<port>[,<port>\|<lo>:<hi>]...]` | Apps with their own tor (Tor Browser, Briar, OnionShare). The UID must be an app's (app ID 10000-19999 in any Android user), so never root, a system UID, tor or the DNS filter. The ports are the app's own loopback ports (its tor's SOCKS port), at most 15 (a range counts as two). Refused, so the whole line is ignored: a port below 1024, a port or range that includes 9040, 9053, 5353 or 5380, and a range that reaches into 32768-60999 (where tor's pluggable transports and other apps' listeners are). A single port in that range is accepted (Briar's tor uses 59050): only a socket of the app itself can answer on its listed ports, so a pluggable transport or another app listening there cannot. Each session is a new Android user, so the module rewrites this file and re-runs `apply` every session. |
| `$ANTUMBRA_DIR/state/fw-relays.conf` | `<IPv4> <port>` | Tor relays and configured bridges that the exempt apps may connect to directly. Contract v0: empty (no file). Filling it from tor's consensus every hour is later work (W9). |
| `$ANTUMBRA_DIR/lists/doh-ipv4.txt` | `<IPv4>[/32]` | DNS-over-HTTPS servers no app may reach, even through Tor (design layer L1), so apps fall back to the system's DNS and its filter. Single addresses only: a line with a wider prefix is ignored as invalid, as the list compiler does. Absent until the list job provides it. |

Environment variables, for the module, tests and debugging: `ANTUMBRA_DIR`
(default `/data/adb/antumbra`), `ANTUMBRA_FW_DIR` (the lock and the recorded
hash; default `$ANTUMBRA_DIR/state/fw`), `ANTUMBRA_FW_EXEMPT`, `ANTUMBRA_FW_RELAYS`,
`ANTUMBRA_FW_DOH` (the three files), `ANTUMBRA_FW_IPTABLES`,
`ANTUMBRA_FW_IP6TABLES`, `ANTUMBRA_FW_IPTABLES_RESTORE`,
`ANTUMBRA_FW_IP6TABLES_RESTORE` (the tools), and `ANTUMBRA_FW_NFLOG_GROUP`
(0-65535: also log redirected flows and refused packets to that NFLOG group,
rate-limited, for the CI leak test). The UIDs, ports and networks are fixed
in the script, as the shared contract fixes them.

## Why not Tails' rules

| Tails grants its desktop user | On a phone that would mean | Here |
|---|---|---|
| direct TCP and UDP to the LAN | any app can ask the router for the public IP (UPnP `GetExternalIPAddress`, router status pages) and send it out through Tor | every app's TCP to the LAN is passed into tor, which refuses private addresses; other LAN traffic is refused. tor itself may not reach the LAN either. |
| any loopback TCP port | an app reaches tor's ControlPort, sets a bridge or entry guard it controls, and tor connects there directly, revealing the real IP; it also reaches other apps' local servers (Tor Browser's tor, adbd, Shizuku) | apps may use only 127.0.0.1:9040, 5353 and 5380, and an exempt app its own listed ports; only tor can answer on 9040, only the filter on 5353 and 5380, only the exempt app on its ports, so an app that takes one of them while its owner is not listening serves no one. Any other loopback TCP goes into the TransPort, where tor refuses it. There is no ControlPort: tor uses a ControlSocket (a 0660 file, uid and gid 2950), which netfilter does not reach and file permissions protect. |
| `ct state established accept` for everyone | listening app sockets answer inbound LAN connections | inbound packets from other interfaces are dropped unless they belong to a connection the firewall let out (tor's, an exempt app's to a relay, the DHCP client's). |

## Where the rules hook in, and why there

netd builds its own chains when it starts and again whenever it restarts
(`Controllers::initChildChains` in AOSP and LineageOS `system/netd`). It
flushes some built-in chains and leaves others alone:

| Built-in chain | netd | Antumbra uses it for |
|---|---|---|
| filter OUTPUT | keeps existing rules in place and appends its own chains after them | `ANTUMBRA_OUT` (the policy) and `ANTUMBRA_ARM_OUT`, as rule 1 |
| nat OUTPUT | does not touch it | `ANTUMBRA_NAT` (the redirects), as rule 1 |
| mangle PREROUTING | does not touch it | `ANTUMBRA_IN` and `ANTUMBRA_ARM_IN` (inbound), as rule 1 |
| mangle POSTROUTING | keeps existing rules, appends its own | `ANTUMBRA_POST` and `ANTUMBRA_ARM_POST` (the egress gate), as rule 1 |
| filter FORWARD | flushes the rules, keeps the policy | policy DROP only |
| filter INPUT, mangle INPUT and OUTPUT, nat PRE/POSTROUTING, raw PREROUTING | flushes them | nothing: a rule there would vanish when netd starts |

Allowed packets are not ACCEPTed but RETURNed, so they still pass through
netd's own chains (data accounting, LineageOS' per-app network switches,
strict mode). Refused packets never reach them. The sandbox test replays
netd's start-up (its flushes, appended chains and connection-mark rules)
after `apply` and checks that the rule set is still live and still works.

Two layers do the work. The filter table decides, per UID, what a packet may
do. mangle POSTROUTING is a second, independent gate: it runs after routing,
sees the real output interface, and lets a packet out of a non-loopback
interface only if its connection carries the mark (`0x10000000`, bit 28)
that the filter table sets on connections it allowed out. A forwarded packet
never passes the filter table's OUTPUT chain, so it never carries the mark:
the gate drops it whatever netd does to FORWARD.

Why bit 28: AOSP's packet mark (`system/netd/include/Fwmark.h`, Android 16)
uses bits 0-20 (network, permission and billing state), marks bits 21-28
`reserved`, gives bits 29-30 to vendors ("reserved for vendor") and bit 31
to wake-up packets. netd copies only the low 20 bits into the connection mark
(`CONNMARK_FWMARK_MASK 0x000FFFFF`). Antumbra's two connection-mark bits,
bit 28 for the egress gate and bit 27 (`0x08000000`) for tor's connections
to its pluggable transports, come from the reserved field, away from the
vendor bits: a Qualcomm rule that saved its vendor bits into the connection
mark (`CONNMARK --save-mark` with a mask over bits 29-30) cannot open the
gate. A vendor rule whose mask covers bit 27 or 28 would still matter; the
phone check (W16) is that `iptables-save -t mangle | grep CONNMARK` on
LineageOS lists no rule but netd's 0xfffff ones and Antumbra's.

## The arm set

```
mangle  ANTUMBRA_ARM_IN    -i lo -j RETURN ; -j DROP     (rule 1 of PREROUTING)
mangle  ANTUMBRA_ARM_POST  -o lo -j RETURN ; -j DROP     (rule 1 of POSTROUTING)
filter  ANTUMBRA_ARM_OUT   -o lo -j RETURN ; -j DROP     (rule 1 of OUTPUT)
filter  FORWARD policy DROP
```

The same in IPv6. It has no per-UID rule and needs no conntrack, so it loads
in milliseconds and cannot go wrong in an interesting way. While it is
loaded, loopback is open (the system needs it) and nothing else moves: no
packet leaves, arrives or is forwarded, for any UID, including tor. `flush`
returns here, and so does a failed `apply`. The arm chains stay in the kernel
after `apply`, unreferenced, so `flush` only has to put the jumps back.

Normally the arm set, and for `flush` the removal of the jumps into the full
rule set, is one atomic `iptables-restore` commit per table. When that fails
(or there is no `-restore` tool), the same is done one command at a time, in
an order where every step is closed: FORWARD's policy; then each arm chain
(egress gate first, then filter OUTPUT, then inbound), which, if it is not
exactly the two rules above, first gets a DROP in front, loses its other
rules, and gets its loopback rule back last; then its jump, inserted as rule
1 unless it already is. Only when the family is armed (the three jumps first,
the chains exact, FORWARD DROP) does `flush` delete the jumps into the full
rule set, one at a time, checking before each that the arm set is still in
front. If an insert fails, nothing is deleted: the family keeps whatever
closed it, and `flush` exits 1. The applied chains are deleted only from a
family that is armed, in one commit per table that fails as a whole while
anything still jumps to them.

What the arm set cannot stop: packets sent through `AF_PACKET` sockets, which
never enter netfilter. Android's DHCP client sends its DISCOVER and REQUEST
that way. The module's tmpfs over the Wi-Fi configuration store means a phone
that boots has no saved network to join until Welcome adds one.

## The full rule set (IPv4)

`antumbra-fw print` shows it exactly. In order of evaluation:

### nat `ANTUMBRA_NAT` (rule 1 of nat OUTPUT)

nat sees only the first packet of each connection. ACCEPT here means "leave
the destination as it is"; netd has no rules in nat OUTPUT to skip.

1. **tor (2950) and the DNS filter (2951): not translated.** tor must reach
   the Internet as itself; the DNS filter is held to tor's DNSPort by the
   filter table.
2. **UDP and TCP to port 53, any address: to 127.0.0.1:5353.** Every DNS
   query, whoever sends it and wherever it was addressed (the router, a
   public resolver, 127.0.0.1:53), reaches the DNS filter. The system
   resolver's sockets (Android's DnsResolver hands them to `AID_DNS`, 1051)
   and apps' own sockets are redirected alike, so this covers apps that use
   `getaddrinfo` and apps that send their own queries. If the filter is not
   running, the query fails: the filter fails closed and nothing falls back
   to direct DNS, because other UDP is refused.
3. **TCP to 127.0.0.1:9040, 5353, 5380: not translated.** The three loopback
   services apps may use: tor's TransPort, the DNS filter and its status page.
4. **Exempt apps: their own listed loopback ports, and Tor relays: not
   translated.** The relay chain `ANTUMBRA_RELAYS` holds one ACCEPT rule per
   relay or bridge (IP and port); it is empty in v0.
5. **All other TCP: to 127.0.0.1:9040.** Internet, LAN, link-local, the
   phone's own addresses, any other loopback port: everything goes into
   tor's TransPort. tor refuses private and loopback destinations
   (`ClientRejectInternalAddresses`), so LAN and loopback TCP ends there.

### filter `ANTUMBRA_OUT` (rule 1 of filter OUTPUT)

After a nat redirect the filter table sees the new destination
(127.0.0.1:9040), but `-o` still names the interface of the original route,
so the rules match addresses, ports and conntrack state, and use `-o lo`
only where no translation can have happened.

1. **Only a service's owner may answer on its loopback port** (to
   `ANTUMBRA_SQUAT`, which drops). Packets on loopback from TCP source port
   9040 or 9053, or UDP 9053, whose socket is not tor's (2950); from TCP 5353
   or 5380, or UDP 5353, whose socket is not the DNS filter's (2951); answers
   (the reply direction) from an exempt app's listed ports whose socket is not
   that app's (tor's own connections aside; only answers, because such a port
   can be in the ephemeral range, where the kernel also picks other apps'
   source ports); and on tor's connections to its pluggable-transport
   ports, from any socket but uid 2950's. tor holds no TransPort or DNSPort
   until Welcome's Start (`DisableNetwork 1`), and both services are down
   while they restart, so without this an app that bound 127.0.0.1:9040
   first would receive every other app's and root's redirected TCP, with the
   original destination (`SO_ORIGINAL_DST`), and answer it; the same for DNS
   on 5353 and the status page on 5380. Now its SYN-ACKs and answers are
   dropped: no handshake completes and no answer arrives. A SYN-ACK belongs
   to the listening socket (the kernel attributes it with `skb_to_full_sk`
   since Linux 4.4), so the owner match sees the listener's UID. Packets the
   kernel sends itself (resets from a closed port, TIME_WAIT
   acknowledgements) own no socket and are not matched, so a closed port
   still refuses at once. What iptables cannot do: see which socket
   *receives* a packet. A UDP squatter still receives the query datagrams it
   cannot answer, and a TCP squatter the SYNs; a check in the module of
   which UID holds these ports (module part) is the second half.
2. **Other replies inside the phone are allowed** (`-o lo`, conntrack
   ESTABLISHED/RELATED in the REPLY direction). tor's TransPort, the DNS
   filter and the status page must answer the apps whose connections the
   rules below allowed. The contract's "established only for uid 2950"
   applies to traffic leaving the phone; this rule cannot let anything leave,
   and the egress gate checks that again.
3. **tor (2950) goes to `ANTUMBRA_TOR`:**
   - its connections to its pluggable transports are allowed: new TCP to
     127.0.0.1 ports 32768-60999 (lyrebird listens on a random port in the
     kernel's ephemeral range) gets bit 27 of the connection mark, and only
     a socket of uid 2950 (lyrebird runs as tor's uid) may answer on such a
     connection (rule 1). Another app's listener in that range never
     completes the handshake, so a bridge line pointing at a loopback port
     cannot make tor talk to an app;
   - everything else local is refused, even connections tor opened before
     the full rule set was loaded: other loopback ports (the status page, the
     DNS filter, other apps' listeners) and the phone's own addresses;
   - its established connections are allowed;
   - the LAN and other networks that are never the Internet are refused:
     0.0.0.0/8, 10/8, 100.64/10 (carrier NAT), 169.254/16, 172.16/12,
     192.0.0.0/24, 192.168/16, 198.18/15, multicast 224/4 and 240/4
     (including broadcast). A compromised or misconfigured tor cannot talk to
     the router;
   - anything else to the Internet (TCP, UDP or ICMP) is allowed, and its
     connection gets the mark that opens the egress gate.
4. **The DNS filter (2951) goes to `ANTUMBRA_DNSF`:** UDP and TCP to
   127.0.0.1:9053, tor's DNSPort, and nothing else. A bug in the filter's DNS
   parser cannot be turned into a direct connection.
5. **Packets the kernel sends on a marked connection are allowed** (no
   owning process, mark set, established). These are TCP TIME_WAIT
   acknowledgements and resets on tor's connections, sent from the kernel's
   own socket rather than tor's.
6. **Everyone else goes to `ANTUMBRA_APP`:** apps, system services, root,
   and packets with no owner. The contract treats every UID except 2950 the
   same; the leak check's suggestion to refuse rather than redirect UIDs below
   10000 was not taken, so system traffic that the module does not switch off
   (L0) goes through Tor rather than being blocked.
   - DNS to 127.0.0.1:5353 (redirected or sent there directly): allowed.
   - New TCP whose original destination port is 853 (DNS over TLS, Android's
     Private DNS): refused with a reset, so Android falls back to plain DNS
     at once, which the filter sees.
   - New TCP whose original destination is a DNS-over-HTTPS server in
     `ANTUMBRA_DOH`: refused (layer L1).
   - TCP to 127.0.0.1:9040 and 5380: allowed (redirected or direct).
   - Exempt apps: TCP to their own loopback ports; new TCP to an address in
     the filter table's `ANTUMBRA_RELAYS` (which refuses LAN, loopback and
     anything not listed) gets the mark; their established connections with
     the mark are allowed. An exempt app's other TCP was already redirected
     into the TransPort by nat, so the exemption only adds direct access to
     relays and never takes anything else away.
   - DHCP renewals (UDP 68 to 67) from the network stack, UID 1073
     (`AID_NETWORK_STACK`), to a private, carrier-NAT or link-local address
     (10/8, 100.64/10, 169.254/16, 172.16/12, 192.168/16) or to
     255.255.255.255 (rebinding): allowed and marked (`ANTUMBRA_DHCP`
     refuses any other destination, so a rogue DHCP server that names a
     public server identifier cannot steer renewals to the Internet).
     Android's DHCP client renews its lease through an ordinary UDP socket;
     without this the lease would lapse every lease period. A network whose
     DHCP server has a public address loses renewals and gets a new lease
     through the packet socket instead. This is the one exception the
     contract does not list; the facts check asked for it ("DHCP allowed only
     for the NetworkStack UID"). When NetworkStack runs inside the system
     server (uid 1000) rather than as its own app (uid 1073), renewals are
     refused the same way and the lease is obtained again through the packet
     socket; the phone check is that the renewals come from uid 1073.
   - Everything else is refused: TCP with a reset, the rest with ICMP port
     unreachable, so apps fail at once. That includes all other UDP (NTP,
     QUIC, mDNS, SSDP, STUN), ICMP and multicast. Packets the kernel sends
     itself (IGMP reports, ICMP errors) are dropped without an answer.

### mangle `ANTUMBRA_IN` (rule 1 of PREROUTING) and `ANTUMBRA_POST` (rule 1 of POSTROUTING)

- **Inbound:** from loopback, or a reply on a marked connection, or a DHCP
  reply (UDP 67 to 68) from a private, carrier-NAT or link-local address;
  everything else is dropped silently, before routing,
  so it is never delivered or forwarded. No app can run a server that the
  network can reach, and nothing answers a probe.
- **Egress gate:** to loopback, or on a marked connection; everything else is
  dropped. Only three kinds of connection are ever marked: tor's to the
  Internet, an exempt app's to a listed relay, and DHCP renewals.

## IPv6

The kernel has no IPv6 NAT, so IPv6 cannot be passed into Tor: it is
refused. mangle drops every IPv6 packet that arrives from or leaves on an
interface other than loopback, filter FORWARD's policy is DROP, and filter
`ANTUMBRA_OUT` allows only `::1` to `::1`, only for user 0's system UIDs
(0-9999) except tor and the DNS filter, plus replies and kernel packets on
`::1`. Apps get no IPv6 at all, not even loopback (a dual-stack server
listening on `::` would otherwise be reachable on `[::1]`). IPv4 loopback is
stricter for system UIDs than IPv6 loopback, because the contract keeps
`::1` for the system.

An app's IPv6 socket connected to an IPv4-mapped address (`::ffff:a.b.c.d`)
sends IPv4 packets, which the IPv4 rules handle like any other (the test
checks it). IPv6-only networks with NAT64 are to check on the phone: with
the old clatd (a tun device) its IPv6 packets are dropped and nothing
connects; with Android's tc-BPF clat, IPv4 is translated to IPv6 after the
egress gate, so tor's marked IPv4 might leave as IPv6. Only tor's marked
traffic passes the gate either way, so this is not a leak, but neither
outcome has been seen.

Refusing IPv6 packets does not stop the phone from getting an IPv6 address:
the address comes from router advertisements, which the inbound drop does
stop, but NetworkStack re-enables IPv6 on each interface it brings up. The
module must also write `disable_ipv6=1` and `accept_ra=0` per interface
(checks: "IPv6 off per interface"), so that no app can read a global IPv6
address and send it through Tor.

## Loading, checking and the hash

`apply` first arms, unless the full set is already in place (then it reloads
in place, so tor's connections are not interrupted). It then loads IPv6, then
IPv4, each with one `iptables-restore --noflush` call. Each table is one
atomic commit, and the tables are committed in an order where every
intermediate state is closed: nat first, then filter (which refuses traffic
nat has not passed on), and the mangle egress gate last. In the same commit
as each new jump, the old jumps (arm or applied) are deleted.

It then checks the kernel: every chain has as many rules as the input, every
jump is rule 1 of its built-in chain and the only jump there, no arm jump is
left, FORWARD's policy is DROP. Only then does it record and print the hash:
the SHA-256 of every line of `iptables -S` and `ip6tables -S` (all tables)
that mentions `ANTUMBRA_`, plus the FORWARD policies. The hash describes what
the kernel holds, not what was sent to it, and it is the same for the same
configuration on every run, shell and userland (the test checks this).

## What this firewall does not cover

- **Packets below netfilter.** `AF_PACKET` sockets (root and system daemons
  with `CAP_NET_RAW`; Android's DHCP client), Wi-Fi firmware offloads
  (hardware keepalives, APF), tethering offload (tc-BPF, Qualcomm IPA) and the
  modem never pass through iptables. The module turns keepalive offload off
  and the device owner forbids tethering; the threat model lists the rest.
- **The modem.** On SM8150 the Wi-Fi firmware runs in the modem DSP.
- **When the module does not run** (Magisk Safe Mode, a LineageOS update
  without the Magisk step), there is no firewall. The module's answer is to
  keep saved Wi-Fi networks only in RAM; see the design, risk 4.
- **System traffic through Tor.** Anything the module does not switch off
  reaches its server through Tor rather than being blocked (L0).
- **Rules added by other root processes.** A rule inserted above Antumbra's,
  or a vendor rule that saved packet-mark bits 27 or 28 into the connection
  mark, would change the result. `status` notices the first (`partial` or
  `open`); the second has to be ruled out on the phone (W16), though the
  vendor bits (29-30) are already out of the way.
- **Packets an app receives on a port it took.** The owner checks stop a
  squatting app from answering on 9040, 9053, 5353 or 5380, but it still
  receives the SYNs and UDP queries sent there while it holds the port
  (iptables cannot match the receiving socket), and tor cannot bind the port
  until it is free. A check in the module of which UID holds the ports, and
  its supervision, have to handle that;
  binding the services to privileged ports (below 1024) would stop it at
  the source, a contract change.
- **Exempt apps.** A compromised Tor Browser can connect to a relay it
  chooses (design, risk 6). Bridges on LAN or loopback addresses are refused
  for exempt apps; Snowflake and meek cannot be allowlisted.
- **Connections opened before `apply`.** None exist at boot (everything but
  loopback is dropped from post-fs-data on), but a re-apply leaves existing
  allowed connections alone.

## Kernel features

The rules use only these: `owner` (`--uid-owner`, ranges and negation, two
in one rule), `conntrack` (`--ctstate`, `--ctdir`, `--ctorigdst`,
`--ctorigdstport`), `connmark` (with negation) and `CONNMARK`, `multiport`
(`--sports` and `--dports`), `limit`, `REDIRECT`, `REJECT` (IPv4 and IPv6),
`NFLOG`, and the filter, nat and mangle tables. The owner checks rely on
SYN-ACKs carrying the listener's socket (`skb_to_full_sk` in `xt_owner`,
Linux 4.4 and later, so in 4.14); the sandbox shows it on its kernel, the
phone has to. All of them are
built into the hotdog kernel (LineageOS `kernel/oneplus/sm8150`
`hotdog_defconfig`) and the Android 16 GKI emulator kernel (6.12 x86_64);
both configs were checked during the design. Neither kernel has the
`addrtype` match, `ipset` or IPv6 NAT, so the rules do not use them.

## Tests

`tests/sandbox-test.sh` builds two network namespaces joined by a veth pair:
the "phone", where `antumbra-fw` runs with fake tor, DNS filter and exempt
app services under their real UIDs, and an "upstream" with a LAN router and
Internet servers. The upstream interface is a veth pair rather than a dummy
interface: a dummy interface only discards what it is given, so no server
behind it could show which probes got through. It probes the rules as root, the network stack (1073), tor
(2950), the DNS filter (2951), an app (10100), an exempt app (10101) and
others, using `setpriv --reuid`. Every listener answers with its name and the
connection's original destination, so a probe shows whether it reached its
target or was redirected; the phone's veth transmit counter shows whether
anything left the phone. It covers: the sandbox working without the
firewall; arm (nothing leaves, loopback works, idempotent); apply (every
probe the contract lists, from every UID, IPv4 and IPv6; only tor and DHCP
leave; DHCP only to the LAN or broadcast, and inbound DHCP only from the
LAN; tor reaching its pluggable transport but not another uid's listener in
the ephemeral range; netd starting afterwards; tampering detected and
repaired); an app holding 9040, 9053, 5353 and 5380 while the fake tor and
filter are stopped (no handshake completes and no answer arrives, for apps,
root and the filter; nothing leaves; the real services work again after);
exempt apps (their own port taken by another app, a listed port held by
tor's uid), the refused exempt lines, relays, DNS-over-HTTPS servers and
NFLOG; flush (nothing leaves, same hash as arm); failure paths (a failing
`iptables-restore` during apply, flush and arm; a flush where the arm jumps
cannot be inserted either, which must keep the rules and let nothing out; a
tampered arm chain rebuilt; a missing `-restore` tool; a missing
`ip6tables`, which still arms IPv4); the lock and hash directory (never in
tor's `run/`, a planted link not followed, a linked or app-owned directory
refused); the same hash, the single-command paths and the directory checks
from bash, dash, busybox (with busybox's tools), mksh and mksh with toybox's
tools; and 8000 relays.

```sh
sudo tests/sandbox-test.sh                     # prints PASS/FAIL/SKIP per probe
sudo AFW_TEST_REQUIRE_IPV6=1 AFW_TEST_REQUIRE_SHELLS="bash dash busybox mksh" tests/sandbox-test.sh
shellcheck -s sh antumbra-fw && shellcheck tests/sandbox-test.sh   # both clean
sudo AFW_TEST_BACKEND=nft tests/sandbox-test.sh  # the nf_tables iptables
```

It needs root, iproute2, util-linux, python3 and iptables (legacy, as on
Android, when available). It exits 1 if any probe failed and 2 if the sandbox
could not be built. On a kernel without IPv6 it loads the IPv6 rules with the
nf_tables tools (so their syntax is still checked) and skips the IPv6
traffic probes; `AFW_TEST_REQUIRE_IPV6=1` turns those skips into failures, as
CI should. `AFW_TEST_MKSH` and `AFW_TEST_TOYBOX` point at mksh and toybox when
they are not on `PATH`. The test creates four local users (`afw-tor` 2950,
`afw-dns` 2951, `afw-app` 10100, `afw-exempt` 10101) and deletes them at the
end; `AFW_TEST_CREATE_USERS=0` skips that, since the probes use numeric IDs.

What it cannot show: Android itself. The emulator job (CI) and the phone
(January) have to confirm netd's behaviour, SELinux, the Magisk boot timing,
the hotdog kernel's 4.14 netfilter (among it the owner match on SYN-ACKs)
and LineageOS' per-app firewall working together with these rules. Phone
checks that belong to the firewall: no foreign `CONNMARK` rule whose mask
covers bits 27-28; DHCP renewals come from uid 1073; what happens on an
IPv6-only network with NAT64.
