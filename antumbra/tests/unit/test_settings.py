# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for the Welcome settings module (runs on the build host)."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "config", "rootfs", "usr", "lib", "python3", "dist-packages"))
from antumbra import settings as S  # noqa: E402


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_write_and_read_back(self):
        m = S.WelcomeSettings()
        m.mac_spoof = False
        m.network = "bridges"
        m.bridges = "obfs4 1.2.3.4:443 ABC cert=xyz iat-mode=0"
        m.persistence = "none"
        m.write(self.root)
        p = os.path.join(self.root, "persistent")
        self.assertEqual(S.read_setting(os.path.join(p, "tails.macspoof"), "TAILS_MACSPOOF_ENABLED"), "false")
        self.assertEqual(S.read_setting(os.path.join(p, "tails.network"), "TAILS_NETWORK"), "true")
        self.assertEqual(S.read_setting(os.path.join(p, "tails.network"), "ANTUMBRA_TOR_MODE"), "bridges")
        self.assertEqual(S.read_setting(os.path.join(p, "tails.bridges"), "ANTUMBRA_BRIDGES"), m.bridges)
        self.assertTrue(os.path.exists(os.path.join(self.root, "transient", "welcome-done")))
        self.assertFalse(os.path.exists(os.path.join(p, "tails.password")))

    def test_offline_disables_network(self):
        m = S.WelcomeSettings()
        m.network = "offline"
        m.write(self.root)
        self.assertEqual(S.read_setting(os.path.join(self.root, "persistent", "tails.network"), "TAILS_NETWORK"), "false")

    @unittest.skipUnless(shutil.which("openssl"), "openssl missing")
    def test_password_hash_is_sha512crypt(self):
        h = S.hash_password("correct horse battery staple")
        self.assertTrue(h.startswith("$6$"))
        m = S.WelcomeSettings()
        m.user_password = "correct horse battery staple"
        m.write(self.root)
        f = os.path.join(self.root, "persistent", "tails.password")
        self.assertEqual(oct(os.stat(f).st_mode & 0o777), oct(0o600))
        self.assertTrue(S.read_setting(f, "TAILS_USER_PASSWORD").startswith("$6$"))

    def test_shell_format_is_sourceable(self):
        m = S.WelcomeSettings()
        m.bridges = "it's a 'quoted' line"
        m.write(self.root)
        f = os.path.join(self.root, "persistent", "tails.bridges")
        out = subprocess.run(["sh", "-c", f". {f}; printf %s \"$ANTUMBRA_BRIDGES\""], capture_output=True, text=True, check=True).stdout
        self.assertEqual(out, m.bridges)

    def android(self, **kw):
        m = S.WelcomeSettings()
        for k, v in kw.items():
            setattr(m, k, v)
        m.write(self.root)
        f = os.path.join(self.root, "persistent", "antumbra.android")
        return (S.read_setting(f, "ANTUMBRA_ANDROID_ENABLED"), S.read_setting(f, "ANTUMBRA_ANDROID_PERSISTENT"))

    def test_android_off_by_default(self):
        self.assertEqual(self.android(), ("false", "false"))

    def test_android_on_amnesic(self):
        self.assertEqual(self.android(android=True), ("true", "false"))

    def test_android_kept_only_with_persistent_storage(self):
        # Keeping Android's data needs Android on and Persistent Storage in use.
        self.assertEqual(self.android(android=True, android_persistent=True, persistence="none"), ("true", "false"))
        self.assertEqual(self.android(android=True, android_persistent=True, persistence="unlock"), ("true", "true"))
        self.assertEqual(self.android(android=True, android_persistent=True, persistence="create",
                                      persistence_passphrase="a long passphrase"), ("true", "true"))
        self.assertEqual(self.android(android=False, android_persistent=True, persistence="unlock"), ("false", "false"))

    def test_persistence_passphrase_file_mode(self):
        m = S.WelcomeSettings()
        m.persistence = "unlock"
        m.persistence_passphrase = "secret passphrase"
        m.write(self.root)
        f = os.path.join(self.root, "transient", "antumbra.persistence-passphrase")
        self.assertEqual(oct(os.stat(f).st_mode & 0o777), oct(0o600))
        with open(f) as fh:
            self.assertEqual(fh.read(), "secret passphrase")


if __name__ == "__main__":
    unittest.main()
