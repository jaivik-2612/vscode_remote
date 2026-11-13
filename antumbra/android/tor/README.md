# tor for Antumbra on Android

This folder builds the system tor that the Antumbra module runs on the phone,
and holds its configuration template.

| File | What it is |
|---|---|
| `build-tor.sh` | Cross-compiles tor for `arm64-v8a` and `x86_64` with the Android NDK. |
| `sources.lock` | Pinned versions, SHA-256 sums, download URLs and signing-key fingerprints. |
| `torrc.in` | The torrc, with `@ANTUMBRA_DIR@` for the runtime directory. |
| `render-torrc.sh` | Writes a torrc from `torrc.in` for a given directory. |
| `check-tor-binary.sh` | Checks the form of a built binary (PIE, linker, libraries, RELRO, API level). |
| `hostcheck-tor.sh` | Runs a static x86_64 copy of the same build on a Linux host and checks its behaviour. |
| `cache-key.txt` | What changes the build output; used for the CI cache key. |
| `patches/` | Antumbra's own patches to tor, applied after unpacking (one so far, below). |
| `keys/` | Copies of the pinned OpenPGP public keys, for when no key server answers. |

No third-party source is kept here. `build-tor.sh` downloads the pinned
tarballs and refuses any whose SHA-256 differs from `sources.lock`.

## Building

```sh
antumbra/android/tor/build-tor.sh --out OUT [--abi arm64-v8a|x86_64|all] [--jobs 2]
```

Needs: a Linux x86_64 host, the Android NDK at the revision in `sources.lock`
(`sdkmanager "ndk;28.2.13676358"`), `curl`, `make`, `perl`, `tar`, GNU
`patch`, and optionally `gpg` (signature checks) and `python3` (host check).

Output, per ABI: `OUT/<abi>/tor` (stripped executable, about 8 MB) and
`OUT/<abi>/tor.buildinfo`, plus `OUT/SHA256SUMS`. The module zip carries these
as `bin/<abi>/tor`.

Current pins (checked 2026-10-11): tor 0.4.9.14, OpenSSL 3.5.9 (LTS until
2030), libevent 2.1.12-stable, zlib 1.3.2, NDK r28c (28.2.13676358),
API level 29.

## How the binary is built, and why

- **A PIE linked against the system's bionic.** OpenSSL, libevent and zlib
  are linked in statically; the binary needs only `libc.so`, `libm.so` and
  `libdl.so`, loaded by `/system/bin/linker64`. A fully static binary was
  tried: bionic's `libc.a` cannot start a static PIE (it crashes before
  `main`), and a static non-PIE binary would load tor's code at a fixed
  address, without ASLR. The allocator is then the system's (Scudo on
  Android 11 and later).
- **API level 29** (Android 10), so one binary runs everywhere it is needed:
  on the phone's stock OxygenOS 10 to 12 (API 29 to 31), in Termux, for a
  smoke test before the bootloader is unlocked; on the CI emulator (API 36);
  and on LineageOS 23.2 (API 36). The arm64 binary in CI's
  `antumbra-android-tor-<run>` artifact is that binary. Compared with a
  build for API 34, it imports the same bionic functions (the same
  `_FORTIFY_SOURCE` checks among them) except `backtrace`,
  `backtrace_symbols` and `backtrace_symbols_fd` (API 33), so tor prints no
  stack trace when it crashes.
- **One patch** (`patches/0001-dnsport-no-reuseaddr.patch`): tor sets
  `SO_REUSEADDR` on every listening socket. On Linux, two UDP sockets that
  both set it may bind the same address and port whatever their uids, and
  the one bound last gets the datagrams; so any app could bind
  127.0.0.1:9053 next to tor and receive the DNS filter's queries, every
  name the phone looks up. The patch leaves the flag off tor's UDP socket
  (DNSPort) only; TCP listeners keep it, and Linux does not let another uid
  bind a port a TCP socket listens on. `build-tor.sh` stops if the patch
  does not apply, and `hostcheck-tor.sh` checks the result.
- **Client only.** `--disable-module-relay` and `--disable-module-dirauth`
  leave out the relay and directory-authority code. Bridges still work: a
  client that uses bridges does not need the relay module.
- **GPL mode.** `--enable-gpl` turns on the onion-service proof-of-work
  module, which Tor Browser's tor has. Without it the phone would get the
  lowest priority at onion services under attack and would differ from Tor
  Browser users. The tor binary is then GPL-3.0, like Antumbra itself; its
  corresponding source is the pinned tarballs plus this folder.
- **Left out:** lzma and zstd (zlib is enough for a client), libscrypt,
  systemd, the unit tests and documentation, and tor's seccomp sandbox (it
  needs libseccomp and is written for glibc's system calls).
- **No system torrc.** `--disable-system-torrc` makes tor read only the file
  given with `-f`; there is no `torrc-defaults` to plant.
- **OpenSSL 3.5** is built with `no-shared no-module no-dso no-engine no-comp
  no-quic no-apps no-docs no-tests no-ui-console no-autoload-config
  no-weak-ssl-ciphers`: nothing is loaded at run time, and `openssl.cnf` is
  never read.
- **Hardening:** tor's own (`-fstack-protector-all`, `_FORTIFY_SOURCE=2`,
  `-fwrapv`, PIE, full RELRO, `BIND_NOW`, non-executable stack), and
  `-fstack-protector-strong -D_FORTIFY_SOURCE=2` for the libraries. Segments
  are 16 KiB-aligned (NDK r28's default).
- **Transparent proxy support** is required at configure time: the build
  stops if `USE_TRANSPARENT` or `linux/netfilter_ipv4.h` is missing, because
  TransPort needs `SO_ORIGINAL_DST`.

### Source verification

For each tarball, `build-tor.sh`:

1. downloads it over HTTPS only (`curl --proto =https`, TLS verified),
2. compares its SHA-256 with `sources.lock` and stops on any difference,
3. if `gpg` is installed (or `--signatures require`), imports the signing
   keys, downloads the signature, and accepts only a valid signature by a
   primary key listed in `sources.lock` (`signer`) whose signing key had not
   expired when it made the signature. gpg itself calls a signature made by
   an already expired key valid (`EXPKEYSIG` with `VALIDSIG`), so the
   script compares the signature's time with the key's expiry from its
   newest self-signature. tor signs a `.sha256sum` file, which must name
   the tarball with the pinned hash. OpenSSL signs with a subkey of its
   signing certificate; the check uses the primary key's fingerprint.

The tarball is unpacked only after these steps pass.

The keys come from `keys/<name>.asc` (copies in this folder, reduced to the
pinned keys with gpg's `export-minimal`) and from every `keyurl`, which is
fetched on every run so that renewals and revocations are seen. A key URL
that fails is skipped, so a key-server outage does not stop CI. The
checksum file and signature of tor also have a second source,
archive.torproject.org. On 2026-10-11 the Tor Project's key directory
(WKD) still served the copies of David Goulet's and Nick Mathewson's keys
that had expired (2026-03 and 2025-10); keys.openpgp.org had their
renewals, so both are listed, and `keys/tor.asc` holds the renewed copies.
keys.openpgp.org serves libevent's key without a user ID, which gpg will
not import, so libevent has only keyserver.ubuntu.com plus
`keys/libevent.asc`.

### Reproducibility

Every step uses `SOURCE_DATE_EPOCH` from `sources.lock`, `LC_ALL=C`, `TZ=UTC`
and deterministic archives (`llvm-ar`). Libraries other than OpenSSL are
compiled with `-ffile-prefix-map`; OpenSSL compiles with relative paths and
names its compiler by the bare NDK target name, so the "compiler:" string it
stores carries no host path. `check-tor-binary.sh` fails if the work
directory or the NDK path appears in the binary. Checked on 2026-10-11 for
x86_64: two builds in different work directories gave the same SHA-256.

### Updating a source

Download the new tarball and signature, check the signature by hand against
the fingerprints in `sources.lock`, then change the version, file name,
SHA-256 and URLs together and run `build-tor.sh --signatures require`. For
a new tor, check that `patches/` still applies and is still needed. When a
signer renews or replaces a key, refresh `keys/<name>.asc`:

```sh
gpg --armor --export-options export-minimal,export-clean --export FINGERPRINT... > keys/NAME.asc
```

## The torrc

`torrc.in` follows the shared contract. Its comments explain each line and
list what Tails' torrc does that it keeps or drops. In short:

- `DataDirectory /data/adb/antumbra/state/tor`, `RunAsDaemon 0`, no `User`
  line (the module starts tor as uid 2950), `AvoidDiskWrites 1`.
- `SocksPort 0` and `ControlPort 0`. Only `TransPort 127.0.0.1:9040
  IsolateClientAddr IsolateDestAddr` and `DNSPort 127.0.0.1:9053` listen,
  with `AutomapHostsOnResolve 1` and `VirtualAddrNetworkIPv4 10.192.0.0/10`.
- `ControlSocket unix:/data/adb/antumbra/run/tor-control.sock GroupWritable
  RelaxDirModeCheck`, `CookieAuthentication 1`, cookie in `run/`.
- `DisableNetwork 1`, `ClientUseIPv6 0`, `Log notice file
  /data/adb/antumbra/log/tor.log`.
- `SafeLogging 1` keeps what the person visits (stream destinations, client
  addresses) out of the log, but not the addresses of the relays and
  bridges tor connects to: a warning about a relay or a bridge names its IP
  address and port. So `tor.log` can hold the person's bridges, and must
  never be shown or exported as it is: not on the status page, not in the
  Welcome app, not in a CI artifact from a run with real bridges.

## What the module has to provide

The layout below is what `module/lib/antumbra.sh` makes and what
`hostcheck-tor.sh` tests. tor checks the owner and mode of its own
directories and will not start otherwise.

| Path | Owner | Mode | Why |
|---|---|---|---|
| `/data/adb` | root | `0711` | uid 2950 and 2951 must pass through it (Magisk sets it to 0700 at every boot) |
| `/data/adb/antumbra` | root | `0711` | a tmpfs mounted at every boot: nothing in it reaches flash |
| `state/` | root | `0711` | |
| `state/tor/` | `2950:2950` | `0700` | tor's DataDirectory; guard and time-stamp state stay in RAM |
| `run/` | `2950:2950` (group 0 also accepted) | `0751` | tor requires its own uid to own the socket's directory; `o+x` lets uid 2951 open `status.json` (needs `RelaxDirModeCheck`) |
| `log/` | root | `0755` | tor cannot create files here, so it cannot plant a link that root's own log writes would follow |
| `log/tor.log` | `2950:2950` | `0600` | a plain file that root creates (replacing anything else there) before every start of tor; tor only appends to it |

Start tor as uid and gid 2950, with every capability dropped and no new
privileges, a clean environment, and `-f <rendered torrc>`. On the phone's
4.14 kernel, sockets for non-app uids may also need supplementary group 3003
(`inet`, Android's paranoid-network check); the emulator's kernel uses the
eBPF check instead. Track the process ID yourself; tor writes no PID file.

After the Welcome screen, over the control socket (authenticate with the
cookie as hex), send one command and wait for its reply:

```
SETCONF UseBridges=1 Bridge="<line 1>" [Bridge="<line 2>" ...] DisableNetwork=0    (bridges)
SETCONF DisableNetwork=0                                                          (direct)
                                                                                  (offline: nothing)
```

- **One command, never two.** tor applies a SETCONF entirely or not at
  all: if it refuses any part, for example a bridge line it cannot parse
  (`513 Unacceptable option value: Bridge line did not parse`), nothing
  changes and the network stays off. A separate `SETCONF DisableNetwork=0`
  after a refused bridge command would connect straight to public relays
  although the person chose bridges.
- **Check every bridge line before it goes between the quotes**: printable
  ASCII only, no `"` and no `\`, which rules out CR and LF as well (as
  `bridges_check` in `module/lib/antumbra.sh` does). A quote, backslash or
  line break would let a bridge line end the string and add control
  commands of its own.

`hostcheck-tor.sh` sends both forms, a refused one and an accepted one, and
checks what changed.

Facts other parts depend on (all seen in `hostcheck-tor.sh`):

- **With `DisableNetwork 1`, tor opens no TransPort or DNSPort at all**, only
  the control socket. Until the module sets `DisableNetwork=0`, TCP
  redirected to 127.0.0.1:9040 is refused and the DNS filter's upstream
  is closed; the filter must then answer SERVFAIL (fail closed). Setting
  `DisableNetwork=1` again closes both listeners.
- **While the network is off, any uid can bind 127.0.0.1:9040 and :9053**,
  because nothing holds them; tor cannot prevent that. An app that binds
  9040 during the Welcome screen receives every connection the firewall
  redirects there. If another process still holds either port when the
  module sends `DisableNetwork=0`, tor refuses the whole command (`553
  Unable to set option: Failed to bind one of the listener ports.`) and
  the network stays off. So the module has to check who holds 9040, 5335
  and 5380 (and the filter who holds 9053) before and after Start, and
  treat any owner other than 2950 or 2951 as a failure.
- **Once tor holds 9040 and 9053, no other uid can bind them as well**:
  for TCP the kernel refuses, for UDP only because of
  `patches/0001-dnsport-no-reuseaddr.patch` (without it, an app could share
  9053 and receive the filter's queries).
- **The redirect works with the app's own source address.** A connection
  from a non-loopback source address, redirected by `iptables -t nat ...
  -j REDIRECT --to-ports 9040`, arrives at TransPort and keeps its original
  destination (`CLIENT_PROTOCOL=TRANS`, isolated by destination and client
  address).
- **tor's DNSPort is UDP only.** A TCP query to 127.0.0.1:9053 is refused.
  The DNS filter must forward TCP queries to tor as UDP, and the firewall
  rule for uid 2951 must allow UDP to 127.0.0.1:9053.
- **`run/` belongs to tor.** Because tor insists on owning the directory of
  its control socket, uid 2950 can replace or delete any file in `run/`,
  including `status.json` written there by root. Nothing that decides
  whether the network is safe should trust a file in `run/`; the firewall
  state is published with `resetprop` by root.
- **`tor.log` can name bridges and relays** (see "The torrc" above).

## Checks

`check-tor-binary.sh --abi ABI [--api N] --expect-version 0.4.9.14 OUT/ABI/tor`
checks, with `readelf`: ELF64 for the ABI, type DYN, interpreter
`/system/bin/linker64`, only `libc.so`/`libm.so`/`libdl.so` needed, no
RPATH/RUNPATH or text relocations, `BIND_NOW`, `FLAGS_1 NOW PIE`, GNU_RELRO,
non-executable stack, no writable-and-executable segment, that the API
level in the Android note is exactly N (by default the `api` record in
`sources.lock`), the version string, and that no build path is embedded.

`hostcheck-tor.sh` needs the static x86_64 copy that `build-tor.sh` links in
the work directory (`WORK/x86_64/tor-hostcheck`). As any user it checks
`--version`, `--library-versions` and `--verify-config` with the rendered
torrc. As root it also runs tor as uid 2950 in private mount and network
namespaces on a tmpfs laid out as in the table above, and checks:

- the process's uid and capabilities, the socket and cookie modes,
  cookie-only authentication;
- that nothing listens while the network is disabled, and that with 9040
  or 9053 held by an app (uid 10123) tor refuses to enable the network and
  changes nothing;
- the listeners and their owner once the network is enabled, and that an
  app cannot bind either port as well;
- the DNSPort's `.onion` mapping, and a redirected TCP connection reaching
  TransPort;
- that bridges and the network go in one command, all or nothing;
- that uid 2951 cannot use the control socket or read the cookie, that
  uid 2950 cannot create files in `log/`, and that `tor.log` stays a plain
  file, owner 2950, mode 0600;
- a clean shutdown with no `[err]` in the log.

The namespace has only a loopback interface and no route out, so nothing
leaves the host. In CI, run it with `sudo` after a non-root build.

Neither check can run the arm64 binary or the shipped x86_64 binary: both
need Android. The CI emulator job runs the x86_64 binary; the arm64 binary
first runs in Termux on the phone's stock Android, as below, then on
LineageOS.

### Smoke test in Termux (no computer, no root)

The arm64 `tor` from CI's `antumbra-android-tor-<run>` artifact runs on
Android 10 and later. In Termux, with `tor`, `torrc.in` and
`render-torrc.sh` copied to the home directory:

```sh
chmod 0755 tor
./tor --version                      # Tor version 0.4.9.14 ...
sh render-torrc.sh "$HOME/at" torrc.in > torrc
./tor --verify-config -f torrc       # Configuration was valid
mkdir -p at/state/tor at/run at/log && chmod 0700 at/state/tor at/run
./tor -f torrc                       # network off: it opens only its control socket
```

The last command never touches the network (`DisableNetwork 1`); stop it
with Ctrl-C after `at/log/tor.log` shows "Opened Control listener". A
failure to start (a missing symbol, "cannot execute") is what this test is
for: it shows that the binary is built for the wrong Android version.
