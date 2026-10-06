# Tails porting map

Every Tails mechanism, where it comes from in the Tails 7.11 tree
(`vendor/tails/`), and what Antumbra does with it. "Verbatim" means the
file is installed unchanged; "adapted" means edited with a header comment
saying what changed; "re-implemented" means rewritten for the phone.

| Mechanism | Tails source | Antumbra | Status |
|---|---|---|---|
| Tor-enforcement firewall | `etc/ferm/ferm.conf` (iptables via ferm) | `config/rootfs/etc/nftables.conf`, native nftables, rule by rule, same users and ports; `inet` family drops all IPv6 | re-implemented; syntax-checked in CI |
| Never flush the firewall on stop | `ferm.service.d/no-drop-on-stop.conf` | `nftables.service.d/antumbra.conf` | adapted |
| Re-apply on interface up, session rules | `dispatcher.d/00-firewall.sh`, `tails-add-session-firewall-rule` | `00-firewall.sh`, `antumbra-add-session-firewall-rule` (nft) | adapted |
| Network namespaces per app | `tails-create-netns`, `.service` | `antumbra-create-netns` (nft inside the namespaces) | adapted |
| torrc | `etc/tor/torrc` | verbatim | verbatim; `tor --verify-config` in CI |
| Tor unit drop-ins | `tor@default.service.d/*` | verbatim | verbatim |
| Control-port filter | `onion-grater` + `etc/onion-grater.d/*.yml` | verbatim | verbatim |
| Tor bootstrap flag | `tails-wait-until-tor-has-bootstrapped`, `tails-tor-has-bootstrapped*`, `tor_wait_until_bootstrapped`, `tor_variable` | verbatim | verbatim |
| Pluggable transports | from the Tor Browser tarball; `tor-pt-configuration-helper` | lyrebird from the aarch64 tarball as `/usr/bin/obfs4proxy`; helper verbatim | adapted |
| Tor Connection assistant (tca) | `tca`, `tca-portal` | not ported; `antumbra-tor-connect` (direct/bridges/status/disconnect) and the Welcome screen's bridge field | re-implemented, reduced |
| Time sync | `htpdate` (Perl), `htpdate.service`, pools, tmpfiles | verbatim | verbatim |
| Pre-Tor clock fix | `tails-get-network-time` as `clearnet` | user `clearnet` and firewall rules kept; the script is not wired to a prompt yet | pending |
| DNS to Tor | `etc/resolv.conf`, NM `dns=none`, nat redirect 53→5353 | same | verbatim |
| Clearnet resolver for bridges | `resolv-over-clearnet.conf`, dispatcher `00-resolv-over-clearnet` | verbatim | verbatim |
| MAC spoofing | `tails-spoof-mac`, `00-mac-spoof.rules`, NM `spoof-mac.conf` | `antumbra-spoof-mac` (no GNOME notification; state file), rule adapted | adapted |
| Block network drivers until the Welcome decision | hook `80-block-network`, `tails-unblock-network` | hook `42-network-block-drivers.sh`, `antumbra-unblock-network` | adapted |
| Wireless device state | `tails-set-wireless-devices-state` | Wi-Fi only (no WWAN) | adapted |
| NetworkManager privacy | `conf.d/{dhcp-send-hostname,dhcp,dns,ipv6,spoof-mac}.conf` | verbatim plus `antumbra-privacy.conf` (hostname-mode, scan MAC randomisation, stable client id) | verbatim + additions |
| sysctl hardening | `etc/sysctl.d/*.conf` | verbatim except `mmap_aslr.conf`, generated from the kernel configuration; `dmesg_restrict` and `no-coredumps` added | adapted |
| Module blocklists | `etc/modprobe.d/*` | verbatim minus x86-only files; Bluetooth list extended to this phone's stack; NFC and USB gadget lists added | adapted |
| Kernel cmdline hardening | `config/variables` (live-build) | `device/oneplus-hotdog/cmdline.txt` without x86-only options | adapted |
| Amnesia (live-boot, overlay) | live-boot from deb.tails.net with patches | Debian's live-boot 1:20250815 unpatched, overlay in `/run/live/overlay` | adapted |
| Memory erasure | `initramfs-pre-shutdown-hook`, `initramfs-restore`, `initramfs-shutdown.service`, `run-initramfs.mount`, hook `shutdown`, `tails-remove-overlayfs-dirs.service`, `system-shutdown/tails` | all adapted: initrd from `/boot`, no removable medium or random-seed sector, loop device detached | adapted |
| Emergency shutdown on medium removal | `udev-watchdog`, `tails-shutdown-on-media-removal` | dropped (no removable medium); replaced by long-press power-off and the lock-triggered auto-shutdown timer | re-implemented |
| Swap | `05-replace_swapon`, zramswap | swapon diverted to a zram-only wrapper; `systemd-zram-generator` | adapted |
| Welcome Screen | `tails-greeter` (GDM extension, as `Debian-gdm`), `PostLogin/Default` | `antumbra-welcome` (GTK4) as `antumbra-greeter` under greetd, `antumbra-apply-welcome-settings` as root; same settings file format, and Tails' files and keys for the settings Tails has; Antumbra's own for bridges, administration, Android apps and Persistent Storage | re-implemented |
| Settings library | `tails-shell-library/tails-greeter.sh` | adapted (paths) | adapted |
| Admin password, sudo, polkit | `PostLogin/Default` | in the applier: `chpasswd -e`, sudoers, polkit admin rule | adapted |
| Persistent Storage | `tps` (D-Bus service, Python) | `antumbra-persistence` (bash: LUKS2/argon2id with tps' parameters, features file, bind mounts) | re-implemented, reduced |
| Tor Browser launch | `tor-browser`, `launch-tor-browser`, `netnsdrop`, Flatpak sandbox, AppArmor | `tor-browser` → `antumbra-run-tor-browser` (sudo, `ip netns exec tbb`, drop to user) → `launch-tor-browser`; prefs from `tor-browser-prefs.js`; no Flatpak, no AppArmor yet | adapted, reduced |
| Tor Browser control cookie | `etc/skel/.tor/control_auth_cookie` | verbatim | verbatim |
| Unsafe Browser | `unsafe-browser`, chroot/overlay, `clearnet` namespace | not ported (namespace and firewall rules kept) | pending |
| AppArmor adjustments for Tor | `apparmor-adjust-tor-{profile,abstraction}.diff` | applied at build by hook `46-network-enable.sh` | verbatim patches |
| AppArmor on the live root | hook `48-tweak-AppArmor-profiles`, `tunables/alias.d/tails`, `tunables/home.d/tails` | hook `48-network-apparmor.sh` (`attach_disconnected` on every profile, every profile must parse), the tunables for trixie's live-boot paths, and an `apparmor.service` override, since Debian's unit skips an overlayfs live root | adapted |
| Users | hooks `06-adduser_{clearnet,htp}`, `04-change-gids-and-uids` | `htp` 1101, `clearnet` 1102, `antumbra-greeter` 1104, `amnesia` 1000 | adapted |
| Journal, logs | `Storage=volatile` | same, plus no core dumps | verbatim |
| memlockd | `etc/memlockd.cfg` | adapted to Antumbra's units | adapted |
| sudoers | `always-ask-password`, `allow-closefrom` | verbatim; plus the Tor Browser launcher rule | verbatim + addition |
| Applications | `tails-common.list` | `config/packages/apps.list` (phone-adaptive subset) | adapted |
| Upgrades | IUK, `tails-upgrade-frontend` | not ported; full re-flash (see roadmap) | pending |
| Accessibility bus over TCP (port 4101) | ferm rules, `tails-a11y-bus-proxy` | dropped | dropped |
| USB protection | `12-usbguard` hook | usbguard with an explicit hub-only policy | adapted |
