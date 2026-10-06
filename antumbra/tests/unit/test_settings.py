# SPDX-License-Identifier: GPL-3.0-or-later
"""Unit tests for the Welcome settings module (runs on the build host)."""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
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


class RetryTest(unittest.TestCase):
    """Starting again after the applier failed (a wrong passphrase): the
    earlier failure report stays until the applier runs again."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.applied = os.path.join(self.root, "welcome-applied")
        self.failed = os.path.join(self.root, "welcome-failed")
        self.settings = os.path.join(self.root, "settings")

    def tearDown(self):
        shutil.rmtree(self.root)

    def report(self, text):
        with open(self.failed, "w") as f:
            f.write(text + "\n")

    def wait(self, stale, timeout):
        S.wait_for_applier(stale, timeout=timeout, applied=self.applied, failed=self.failed, poll=0.05)

    def later(self, delay, action):
        t = threading.Timer(delay, action)
        t.start()
        self.addCleanup(t.join)

    def submit(self):
        m = S.WelcomeSettings()
        m.persistence, m.persistence_passphrase = "unlock", "the right passphrase"
        return S.submit(m, self.settings, failed=self.failed)

    def test_an_earlier_report_is_not_this_attempts(self):
        self.report("wrong passphrase, or Persistent Storage is damaged")
        stale = self.submit()
        self.assertIsNotNone(stale)
        with self.assertRaisesRegex(RuntimeError, "^timed out"):
            self.wait(stale, 0.4)

    def test_success_after_an_earlier_failure(self):
        self.report("wrong passphrase, or Persistent Storage is damaged")
        stale = self.submit()
        # The applier starts: it removes the old report, then succeeds.
        self.later(0.15, lambda: os.unlink(self.failed))
        self.later(0.3, lambda: open(self.applied, "w").close())
        self.wait(stale, 5)

    def test_a_new_failure_is_reported(self):
        self.report("wrong passphrase, or Persistent Storage is damaged")
        stale = self.submit()
        self.later(0.15, lambda: os.unlink(self.failed))
        self.later(0.3, lambda: self.report("activating Persistent Storage failed"))
        with self.assertRaisesRegex(RuntimeError, "^activating Persistent Storage failed$"):
            self.wait(stale, 5)
        # Rewritten in place, without being removed first, it is new too.
        stale = S.failure_report_id(self.failed)
        self.later(0.1, lambda: self.report("unexpected error (line 1, exit status 1)"))
        with self.assertRaisesRegex(RuntimeError, r"^unexpected error"):
            self.wait(stale, 5)

    def test_no_second_write_while_the_applier_has_the_first(self):
        # After a time-out, Start again while the applier still has the
        # first attempt (welcome-done still there): nothing is written.
        self.submit()
        done = os.path.join(self.settings, "transient", "welcome-done")
        passphrase = os.path.join(self.settings, "transient", "antumbra.persistence-passphrase")
        os.unlink(passphrase)
        self.assertIsNone(self.submit())
        self.assertFalse(os.path.exists(passphrase))
        os.unlink(done)                       # the applier finished with it
        self.submit()
        self.assertTrue(os.path.exists(passphrase))

    def test_the_welcome_screen_uses_them(self):
        path = os.path.join(os.path.dirname(__file__), "..", "..", "config", "rootfs", "usr", "bin", "antumbra-welcome")
        with open(path, encoding="utf-8") as f:
            source = f.read()
        self.assertIn("S.wait_for_applier(S.submit(self.model))", source)
        self.assertNotIn("welcome-failed", source)
        self.assertNotIn("self.model.write()", source)


if __name__ == "__main__":
    unittest.main()
