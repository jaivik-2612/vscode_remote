"""Tests for ci/build_guard.py (CI13): one synthetic file breaks each rule."""

import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import build_guard  # noqa: E402

CASES = [
    ("modem-diag", "module/lib/x.sh", "cat /dev/diag > /sdcard/log\n"),
    ("modem-diag", "module/lib/x.sh", "echo 'AT+EGMR=1,7,\"0\"' > /dev/smd11\n"),
    ("modem-diag", "welcome/app/src/main/java/X.kt", "val r = nvWrite(1)\nfun nv_write() {}\n"),
    ("imei", "welcome/app/src/main/java/X.kt", "val i = tm.getImei(0)\n"),
    ("imei", "module/lib/x.sh", "resetprop persist.radio.imei 123\n"),
    ("usb-diag", "module/post-fs-data.sh", "#!/system/bin/sh\nsetprop sys.usb.config diag,adb\n"),
    ("tor-relay", "module/lib/torrc.sh", "echo 'ORPort 9001' >>\"$T\"\n"),
    ("tor-relay", "module/lib/torrc.sh", "BridgeRelay 1\n"),
    ("tor-relay", "tor/torrc.default", "ServerTransportPlugin obfs4 exec /x\n"),
    ("snowflake-proxy", "module/lib/x.sh", "\"$BIN/snowflake-proxy\" -capacity 1 &\n"),
    ("volte", "module/service.sh", "#!/system/bin/sh\nresetprop -d persist.dbg.volte_avail_ovr\n"),
    ("app-list", "ci/app-lab.txt", "fdroid\tcom.example.satellite.messenger\tSat\n"),
    ("app-list", "ci/app-lab.txt", "aptoide\torg.torproject.snowflake\tSnowflake\n"),
    ("app-list", "ci/app-lab.txt", "fdroid\tcom.example.qfil\tFlasher\n"),
    ("power-menu", "module/overlay/res/values/config.xml",
     '<resources><string-array name="config_globalActionsList">\n<item>power</item>\n<item>restart</item>\n'
     '</string-array></resources>\n'),
]

CLEAN = [
    ("module/lib/x.sh", "# never write /dev/diag or touch volte_avail_ovr\n"),
    ("module/tests/x.sh", "cat /dev/diag\nORPort 9001\n"),
    ("docs/x.md", "ORPort 9001, getImei, snowflake proxy\n"),
    ("ci/leak_analyser.py", "# the ORPort of a relay\nx = 'ORPort DirPort'\n"),
    ("module/lib/torrc.sh", "echo 'ORPort 0'\necho 'SocksPort 9050'\n"),
    ("welcome/app/src/main/java/X.kt", "// getImei is never called\nif (type == \"snowflake\") refuse()\n"),
    ("ci/app-lab.txt", "# no satellite apps\nfdroid\torg.schabi.newpipe\tNewPipe\n"),
    ("module/overlay/res/values/config.xml",
     '<resources><string-array name="config_globalActionsList">\n<item>emergency</item>\n<item>power</item>\n'
     '</string-array></resources>\n'),
]


def tree(files):
    d = tempfile.mkdtemp(prefix="guard-")
    for rel, text in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    return d


class BuildGuardTest(unittest.TestCase):
    def test_each_rule_fails_ci(self):
        for rule, rel, text in CASES:
            with self.subTest(rule=rule, file=rel):
                d = tree([(rel, text)])
                found = build_guard.scan(d)
                self.assertIn(rule, [f[0] for f in found], found)
                self.assertEqual(build_guard.main(["build_guard", d]), 1)

    def test_clean_tree_passes(self):
        d = tree(CLEAN)
        self.assertEqual(build_guard.scan(d), [])
        self.assertEqual(build_guard.main(["build_guard", d]), 0)

    def test_real_tree_is_clean(self):
        root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        self.assertEqual(build_guard.scan(root), [])


if __name__ == "__main__":
    unittest.main()
