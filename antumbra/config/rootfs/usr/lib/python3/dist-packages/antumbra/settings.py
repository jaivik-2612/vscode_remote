# SPDX-License-Identifier: GPL-3.0-or-later
"""Welcome-screen settings in Tails' file format (shell KEY=value lines).

Written by the Welcome screen as the greeter user into
/var/lib/antumbra/settings/{persistent,transient}; copied and applied by
root (antumbra-apply-welcome-settings) into .../applied."""
import os
import shlex
import subprocess

SETTINGS_ROOT = "/var/lib/antumbra/settings"
PERSISTENT = os.path.join(SETTINGS_ROOT, "persistent")
TRANSIENT = os.path.join(SETTINGS_ROOT, "transient")
APPLIED = os.path.join(SETTINGS_ROOT, "applied")
DONE_MARKER = os.path.join(TRANSIENT, "welcome-done")
APPLIED_MARKER = "/run/antumbra/welcome-applied"


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
