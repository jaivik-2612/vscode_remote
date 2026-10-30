# SPDX-License-Identifier: GPL-3.0-or-later
"""Welcome-screen settings in Tails' file format (shell KEY=value lines).

Written by the Welcome screen as the greeter user into
/var/lib/antumbra/settings/{persistent,transient}; copied and applied by
root (antumbra-apply-welcome-settings) into .../applied."""
import os
import re
import shlex
import subprocess
import time

SETTINGS_ROOT = "/var/lib/antumbra/settings"
PERSISTENT = os.path.join(SETTINGS_ROOT, "persistent")
TRANSIENT = os.path.join(SETTINGS_ROOT, "transient")
APPLIED = os.path.join(SETTINGS_ROOT, "applied")
DONE_MARKER = os.path.join(TRANSIENT, "welcome-done")
APPLIED_MARKER = "/run/antumbra/welcome-applied"
# The applier's report of a failure, with its message; it stays until the
# applier runs again (root's, in a directory the greeter cannot write).
FAILED_MARKER = "/run/antumbra/welcome-failed"

# Bridges Tor can use here, besides plain ones (an IPv4 address first): the
# transports tor-pt-configuration-helper names in Tor's ClientTransportPlugin
# line, all run by lyrebird from Tor Browser (/usr/bin/obfs4proxy). The
# Welcome screen and antumbra-tor-connect accept exactly these
# (tests/unit/test_tor_connect.py checks them against the helper).
BRIDGE_TRANSPORTS = ("obfs2", "obfs3", "obfs4", "webtunnel", "meek_lite")
# lyrebird has snowflake too, but the firewall lets Tor's user make only TCP
# connections and DNS queries, and snowflake needs UDP.
SNOWFLAKE_REFUSED = ("Snowflake bridges do not work in Antumbra: snowflake reaches its proxies through "
                     "WebRTC over UDP, and the firewall lets Tor make only TCP connections and DNS queries. "
                     "Use obfs4 or webtunnel bridges.")
# The transports that connect to the bridge line's address, as Tor does for
# a plain bridge. IPv6 is off (/etc/sysctl.d/disable_ipv6.conf) and the
# firewall lets Tor's user connect only over IPv4, so such an address must
# be IPv4. webtunnel and meek_lite connect to the server their arguments
# name (url=, front=) instead, and their address is a placeholder, often an
# IPv6 one.
ADDRESSED_TRANSPORTS = ("obfs2", "obfs3", "obfs4")
IPV6_REFUSED = ("{address} is an IPv6 address. IPv6 bridges do not work in Antumbra: IPv6 is off, and the "
                "firewall lets Tor connect only over IPv4. Use bridges with IPv4 addresses.")


def normalise_bridges(text):
    """TEXT (bridges as typed or pasted: one per line, or separated by ';')
    as the Welcome screen stores it: on one line, with ';' between bridges,
    each trimmed and empty ones left out. The NetworkManager dispatcher
    splits the stored value at ';' and reads only its first line."""
    return ";".join(b.strip() for b in re.split(r"[\r\n;]", text) if b.strip())


def bridge_lines(lines):
    """LINES (bridge lines) as Tor takes them: trimmed, without empty lines,
    '#' comments or a leading "Bridge". Raises ValueError, saying why, for a
    bridge Tor cannot use here: snowflake, an unknown transport, or an IPv6
    address that Tor or lyrebird would connect to."""
    out = []
    for line in lines:
        line = line.strip()
        words = line.split(None, 1)
        if words and words[0].lower() == "bridge":
            line = words[1] if len(words) > 1 else ""
        if not line or line.startswith("#"):
            continue
        words = line.split()
        kind = words[0]
        if kind.lower() == "snowflake":
            raise ValueError(SNOWFLAKE_REFUSED)
        if kind not in BRIDGE_TRANSPORTS and "." not in kind and ":" not in kind:
            raise ValueError(f"Unsupported bridge type: {kind}. Antumbra takes obfs4, webtunnel, "
                             "meek_lite, obfs2, obfs3 and plain bridges.")
        if kind not in BRIDGE_TRANSPORTS:
            address = kind              # a plain bridge
        elif kind in ADDRESSED_TRANSPORTS and len(words) > 1:
            address = words[1]
        else:
            address = ""
        # "[2001:db8::5]:443", or "2001:db8::5" without a port, which Tor
        # also takes; an IPv4 address has at most one ':'.
        if address.startswith("[") or address.count(":") > 1:
            raise ValueError(IPV6_REFUSED.format(address=address))
        out.append(line)
    return out


def failure_report_id(path=FAILED_MARKER):
    """The applier's failure report as it is now (None if there is none),
    to tell a report left by an earlier attempt from a new one."""
    try:
        st = os.stat(path)
    except FileNotFoundError:
        return None
    return (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size)


def submit(model, root=SETTINGS_ROOT, failed=FAILED_MARKER):
    """Hand MODEL (WelcomeSettings) to the applier for this attempt and
    return the failure report there before it (for wait_for_applier). Not
    written while the applier has not finished the previous attempt (its
    welcome-done still there, after a time-out): once Persistent Storage is
    active the settings directory is the volume's, and a second write could
    leave a passphrase hash there."""
    stale = failure_report_id(failed)
    if not os.path.lexists(os.path.join(root, "transient", "welcome-done")):
        model.write(root)
    return stale


def wait_for_applier(stale, timeout=600, applied=APPLIED_MARKER, failed=FAILED_MARKER, poll=0.5):
    """Wait for the root-side applier to apply the settings just written:
    return once they are applied; raise RuntimeError with the applier's
    message once it reports a failure other than STALE (failure_report_id()
    taken before the settings were written: an earlier attempt's report
    stays until the applier starts again, which can take a while), or
    after TIMEOUT seconds."""
    deadline = time.monotonic() + timeout
    while not os.path.exists(applied):
        report = failure_report_id(failed)
        if report is not None and report != stale:
            text = ""
            for _ in range(3):      # the applier may be writing it right now
                try:
                    with open(failed, encoding="utf-8") as f:
                        text = f.read().strip()
                except OSError:
                    pass
                if text:
                    break
                time.sleep(poll)
            raise RuntimeError(text or "settings could not be applied")
        if time.monotonic() > deadline:
            raise RuntimeError("timed out waiting for the settings to be applied")
        time.sleep(poll)


def read_setting(path, key, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{key}="):
                    value = line[len(key) + 1:]
                    return shlex.split(value)[0] if value else ""
    except OSError:
        pass
    return default


def write_setting(path, values, mode=0o640):
    """Atomically write KEY=value lines."""
    os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for key, value in values.items():
            f.write(f"{key}={shlex.quote(str(value))}\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def hash_password(plain):
    """sha512crypt hash via openssl (Python 3.13 has no crypt module)."""
    out = subprocess.run(["openssl", "passwd", "-6", "-stdin"], input=plain + "\n",
                         capture_output=True, text=True, check=True).stdout.strip()
    if not out.startswith("$6$"):
        raise RuntimeError("unexpected password hash format")
    return out


class WelcomeSettings:
    """What the Welcome screen collects."""

    def __init__(self):
        self.mac_spoof = True
        self.network = "direct"        # direct | bridges | offline
        self.bridges = ""
        self.user_password = ""        # screen-lock passphrase (empty: none)
        self.admin = False             # sudo for the user with that passphrase
        self.persistence = "none"      # none | unlock | create
        self.persistence_passphrase = ""
        self.android = False           # Android apps (Waydroid) this session; images built with ANTUMBRA_ANDROID=1
        self.android_persistent = False  # keep Android's data in Persistent Storage (the "android" feature)

    def write(self, root=SETTINGS_ROOT):
        persistent = os.path.join(root, "persistent")
        transient = os.path.join(root, "transient")
        os.makedirs(persistent, mode=0o750, exist_ok=True)
        os.makedirs(transient, mode=0o750, exist_ok=True)
        write_setting(os.path.join(persistent, "tails.macspoof"),
                      {"TAILS_MACSPOOF_ENABLED": "true" if self.mac_spoof else "false"})
        write_setting(os.path.join(persistent, "tails.network"),
                      {"TAILS_NETWORK": "false" if self.network == "offline" else "true",
                       "ANTUMBRA_TOR_MODE": self.network})
        write_setting(os.path.join(persistent, "tails.bridges"), {"ANTUMBRA_BRIDGES": self.bridges})
        if self.user_password:
            write_setting(os.path.join(persistent, "tails.password"),
                          {"TAILS_USER_PASSWORD": hash_password(self.user_password)}, mode=0o600)
        else:
            try:
                os.unlink(os.path.join(persistent, "tails.password"))
            except FileNotFoundError:
                pass
        write_setting(os.path.join(persistent, "antumbra.admin"),
                      {"ANTUMBRA_ADMIN_ENABLED": "true" if self.admin else "false"})
        # Keeping Android's data needs Android on and Persistent Storage in use.
        keep_android = self.android and self.android_persistent and self.persistence in ("unlock", "create")
        write_setting(os.path.join(persistent, "antumbra.android"),
                      {"ANTUMBRA_ANDROID_ENABLED": "true" if self.android else "false",
                       "ANTUMBRA_ANDROID_PERSISTENT": "true" if keep_android else "false"})
        write_setting(os.path.join(transient, "tails.create-persistence"),
                      {"CREATE_PERSISTENT_STORAGE": "true" if self.persistence == "create" else "false"})
        write_setting(os.path.join(transient, "antumbra.persistence"),
                      {"ANTUMBRA_PERSISTENCE": self.persistence})
        pp = os.path.join(transient, "antumbra.persistence-passphrase")
        if self.persistence in ("unlock", "create") and self.persistence_passphrase:
            with open(os.open(pp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w", encoding="utf-8") as f:
                f.write(self.persistence_passphrase)
        else:
            try:
                os.unlink(pp)
            except FileNotFoundError:
                pass
        # The marker is what the root-side path unit waits for.
        with open(os.path.join(transient, "welcome-done"), "w", encoding="utf-8") as f:
            f.write("1\n")
