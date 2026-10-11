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

No third-party source is kept here. `build-tor.sh` downloads the pinned
tarballs and refuses any whose SHA-256 differs from `sources.lock`.

## Building

```sh
antumbra/android/tor/build-tor.sh --out OUT [--abi arm64-v8a|x86_64|all] [--jobs 2]
```

Needs: a Linux x86_64 host, the Android NDK at the revision in `sources.lock`
(`sdkmanager "ndk;28.2.13676358"`), `curl`, `make`, `perl`, `tar`, and
optionally `gpg` (signature checks) and `python3` (host check).

Output, per ABI: `OUT/<abi>/tor` (stripped executable, about 8 MB) and
`OUT/<abi>/tor.buildinfo`, plus `OUT/SHA256SUMS`. The module zip carries these
as `bin/<abi>/tor`.

Current pins (checked 2026-10-11): tor 0.4.9.14, OpenSSL 3.5.9 (LTS until
2030), libevent 2.1.12-stable, zlib 1.3.2, NDK r28c (28.2.13676358),
API level 34.

## How the binary is built, and why

- **A PIE linked against the system's bionic.** OpenSSL, libevent and zlib
  are linked in statically; the binary needs only `libc.so`, `libm.so` and
  `libdl.so`, loaded by `/system/bin/linker64`. A fully static binary was
  tried: bionic's `libc.a` cannot start a static PIE (it crashes before
  `main`), and a static non-PIE binary would load tor's code at a fixed
  address, without ASLR. The allocator is then the system's (Scudo on
  Android 11 and later).
- **API level 34** (Android 14). The phone runs LineageOS 23.2 (API 36) and
  the CI emulator runs API 36. To smoke-test on an older Android (for
  example in Termux on OxygenOS 11, API 30), build with `--api 30`.
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
3. if `gpg` is installed (or `--signatures require`), downloads the signing
   keys and the signature, and accepts only a valid signature by a primary
   key listed in `sources.lock`. tor signs a `.sha256sum` file, which must
   name the tarball with the pinned hash. OpenSSL signs with a subkey of its
   signing certificate; the check uses the primary key's fingerprint.

The tarball is unpacked only after these steps pass.

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
SHA-256 and URLs together and run `build-tor.sh --signatures require`.

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

## What the module has to provide

tor checks the owner and mode of these directories itself and will not start
otherwise:

| Path | Owner | Mode | Why |
|---|---|---|---|
| `/data/adb` and `/data/adb/antumbra` | root | at least `o+x` | uid 2950 and 2951 must reach their files |
| `run/` | `2950:2950` (group 0 also accepted) | `0751` | tor requires its own uid to own the socket's directory; `o+x` lets uid 2951 open `status.json` (needs `RelaxDirModeCheck`) |
| `state/tor/` | `2950:2950` | `0700` | on a tmpfs mounted at every boot, so guard and time-stamp state never reaches flash |
| `log/` | writable by 2950 | `0750` | |

Start tor as uid and gid 2950, with every capability dropped and no new
privileges, a clean environment, and `-f <rendered torrc>`. On the phone's
4.14 kernel, sockets for non-app uids may also need supplementary group 3003
(`inet`, Android's paranoid-network check); the emulator's kernel uses the
eBPF check instead. Track the process ID yourself; tor writes no PID file.

After the Welcome screen, over the control socket (authenticate with the
cookie as hex):

```
SETCONF UseBridges=1 Bridge="<bridge line>"     (only if bridges were chosen)
SETCONF DisableNetwork=0                         (not when offline was chosen)
```

`hostcheck-tor.sh` exercises the bridge commands (without enabling the
network).

Facts other parts depend on (all seen in `hostcheck-tor.sh`):

- **With `DisableNetwork 1`, tor opens no TransPort or DNSPort at all**, only
  the control socket. Until the module sets `DisableNetwork=0`, TCP
  redirected to 127.0.0.1:9040 is refused and the DNS filter's upstream
  is closed; the filter must then answer SERVFAIL (fail closed). Setting
  `DisableNetwork=1` again closes both listeners.
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

## Checks

`check-tor-binary.sh --abi ABI --api 34 --expect-version 0.4.9.14 OUT/ABI/tor`
checks, with `readelf`: ELF64 for the ABI, type DYN, interpreter
`/system/bin/linker64`, only `libc.so`/`libm.so`/`libdl.so` needed, no
RPATH/RUNPATH or text relocations, `BIND_NOW`, `FLAGS_1 NOW PIE`, GNU_RELRO,
non-executable stack, no writable-and-executable segment, the API level in
the Android note, the version string, and that no build path is embedded.

`hostcheck-tor.sh` needs the static x86_64 copy that `build-tor.sh` links in
the work directory (`WORK/x86_64/tor-hostcheck`). As any user it checks
`--version`, `--library-versions` and `--verify-config` with the rendered
torrc. As root it also runs tor as uid 2950 in private mount and network
namespaces on a tmpfs laid out as above, and checks the process's uid and
capabilities, the socket and cookie modes, cookie-only authentication, that
nothing listens while the network is disabled, the listeners once it is
enabled, the DNSPort's `.onion` mapping, a redirected TCP connection
reaching TransPort, the bridge commands, that uid 2951 cannot use the
control socket, and a clean shutdown. The namespace has only a loopback
interface and no route out, so nothing leaves the host. In CI, run it with
`sudo` after a non-root build.

Neither check can run the arm64 binary or the shipped x86_64 binary: both
need Android. The CI emulator job runs the x86_64 binary; the arm64 binary
first runs on the phone (or in Termux, built with a lower `--api`).
