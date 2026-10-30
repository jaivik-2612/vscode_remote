# Provenance of the vendored Tails files

Every file under `vendor/tails/` is copied unmodified from the Tails
source tree, licensed GPL-3.0-or-later by the Tails project
(https://tails.net). Tails is a trademark of the Tails project; these
files are used here to build an independent derivative.

| Field | Value |
|---|---|
| Upstream repository | https://gitlab.tails.boum.org/tails/tails (branch `master`) |
| Snapshot used | Software Heritage archive of 2026-08-19, revision `fd415c38dac2abe05206771e82fee8be2cbdcd20` |
| Tails version in that tree | 7.11 (`debian/changelog`), Debian 13 "trixie" based |
| Current Tails release at vendoring time | 7.14 (2026-09-30); configuration changes between 7.11 and 7.14 have not been diffed |
| Integrity | the vendoring verifier re-fetched the directory listings and confirmed every file's `sha1_git` matches the Software Heritage listing; `ferm.conf` and `torrc` were byte-compared against raw re-downloads |

Layout: paths under `config/chroot_local-includes/` keep Tails' relative
paths (they map onto `/` of the live system). `config/chroot_local-hooks/`
and `config/chroot_local-packageslists/` are the build-time hooks and
package lists. `design/` holds the design documents (`.mdwn`) from
`wiki/src/contribute/design/`.

Antumbra does not ship these files verbatim: the files it actually
installs live under `config/rootfs/` and record, in a header comment,
which vendored file they derive from and what changed.
