# SPDX-License-Identifier: GPL-3.0-or-later
"""Static checks of the Android apps layer (runs on the build host).

The Tor-only network for the Android container is spelled out in several
files that must agree: the bridge's address (antumbra-create-netns), Tor's
listeners for it (the torrc fragment), the firewall (nftables.conf), the
DHCP server (antumbra-waydroid-dhcp.service), the container's MAC address
(the build hook's check of Waydroid's template), the start-host hook and
the self-check. The pinned inputs must be complete for every image variant
a device profile selects.
"""
import os
import re
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
OVERLAY = os.path.join(ROOT, "config", "rootfs")
ANDROID = os.path.join(ROOT, "config", "rootfs-android")


def read(*parts):
    with open(os.path.join(ROOT, *parts), encoding="utf-8") as f:
        return f.read()


def nft_define(text, name):
    m = re.search(rf"^define {name} = (.+)$", text, re.M)
    return m.group(1).strip().strip('"') if m else None


class NetworkAgreementTest(unittest.TestCase):
    def setUp(self):
        self.nft = read("config", "rootfs", "etc", "nftables.conf")
        self.torrc = read("config", "rootfs-android", "usr", "share", "antumbra", "android", "torrc")
        self.netns = read("config", "rootfs", "usr", "local", "lib", "antumbra-create-netns")
        self.dhcp = read("config", "rootfs-android", "usr", "lib", "systemd", "system", "antumbra-waydroid-dhcp.service")
        self.hook56 = read("config", "hooks", "56-session-android.sh")
        self.start_host = read("config", "rootfs-android", "usr", "local", "lib", "antumbra-waydroid-start-host")
        self.selfcheck = read("config", "rootfs", "usr", "local", "sbin", "antumbra-selfcheck")

    def test_bridge_name_and_address(self):
        self.assertEqual(nft_define(self.nft, "android_if"), "waydroid-tor")
        self.assertEqual(nft_define(self.nft, "android_host"), "10.200.2.1")
        self.assertEqual(nft_define(self.nft, "android_net"), "10.200.2.0/30")
        self.assertIn("ANDROID_BRIDGE=waydroid-tor", self.netns)
        self.assertIn('ip addr add 10.200.2.1/30 dev "${ANDROID_BRIDGE}"', self.netns)
        self.assertIn("BRIDGE=waydroid-tor", self.start_host)
        self.assertIn("10\\.200\\.2\\.1/30", self.start_host)
        self.assertIn("--interface=waydroid-tor", self.dhcp)
        self.assertIn("--listen-address=10.200.2.1", self.dhcp)
        self.assertIn("lxc.net.0.link = waydroid-tor", self.hook56)

    def test_tor_listeners_match_the_firewall(self):
        transport = nft_define(self.nft, "android_transport")
        dnsport = nft_define(self.nft, "android_dnsport")
        self.assertRegex(self.torrc, rf"(?m)^TransPort 10\.200\.2\.1:{transport} ")
        self.assertRegex(self.torrc, rf"(?m)^DNSPort 10\.200\.2\.1:{dnsport}$")
        # The host's own listeners are never reused for Android.
        self.assertNotIn(transport, ("9040",))
        self.assertNotIn(dnsport, ("5353",))
        for text in (self.start_host, self.selfcheck):
            self.assertIn(f"redirect to :{transport}", text)
            self.assertIn(f"redirect to :{dnsport}", text)

    def test_firewall_never_forwards_or_masquerades_android(self):
        forward = re.search(r"chain forward \{(.*?)\n    \}", self.nft, re.S).group(1)
        self.assertIn("policy drop", forward)
        self.assertIn("iifname $android_if jump android_reject", forward)
        self.assertIn("oifname $android_if jump android_reject", forward)
        android = re.search(r"chain android \{(.*?)\n    \}", self.nft, re.S).group(1)
        self.assertNotRegex(android, r"\b(dnat|snat|masquerade)\b")
        self.assertNotIn("127.0.0.1", android)
        self.assertIn("route_localnet=0", self.netns)
        self.assertIn("forwarding=0", self.netns)

    def test_container_mac_is_the_dhcp_reservation(self):
        mac = re.search(r"--dhcp-host=([0-9a-f:]{17}),10\.200\.2\.2", self.dhcp).group(1)
        self.assertIn(f"lxc.net.0.hwaddr = {mac}", self.hook56)
        self.assertIn("--port=0", self.dhcp)   # DHCP only, never DNS
        self.assertIn("dnsmasq.waydroid0.leases", self.dhcp)   # where "waydroid status" looks

    def test_dhcp_reply_rule_and_no_lxc_bridge(self):
        self.assertIn("oifname $android_if ip saddr $android_host udp sport 67 udp dport 68 accept", self.nft)
        self.assertIn("systemctl mask lxc-net.service lxc.service lxc-monitord.service", self.hook56)


class PersistenceFeatureTest(unittest.TestCase):
    def test_feature_lines(self):
        lines = [l for l in read("config", "rootfs", "etc", "antumbra", "persistence-features.conf").splitlines()
                 if l and not l.startswith("#")]
        hook = re.search(r"printf '(android\|[^\\]+)\\n' >> /etc/antumbra/persistence-features.conf",
                         read("config", "hooks", "56-session-android.sh")).group(1)
        for line in lines + [hook]:
            fields = line.split("|")
            self.assertIn(len(fields), (5, 6), line)
            self.assertRegex(fields[4], r"^0[0-7]{3}$", line)
            if len(fields) == 6:
                self.assertEqual(fields[5], "off", line)
        self.assertEqual(hook, "android|waydroid|/home/amnesia/.local/share/waydroid|amnesia:amnesia|0700|off")


class PinsTest(unittest.TestCase):
    def setUp(self):
        self.lock = dict(l.split("=", 1) for l in read("device", "oneplus-hotdog", "sources.lock").splitlines()
                         if "=" in l and not l.startswith("#"))

    def test_every_profile_variant_is_pinned(self):
        variants = set()
        for profile in os.listdir(os.path.join(ROOT, "device")):
            conf = os.path.join(ROOT, "device", profile, "device.conf")
            if os.path.exists(conf):
                m = re.search(r"^WAYDROID_IMAGE_VARIANT=(\S+)$", read("device", profile, "device.conf"), re.M)
                variants.add(m.group(1) if m else "arm64")
        self.assertEqual(variants, {"arm64", "arm64_only"})
        for variant in variants:
            key = "WAYDROID_" + variant.upper()
            for kind in ("SYSTEM", "VENDOR"):
                k = f"{key}_{kind}"
                self.assertTrue(self.lock[f"{k}_URL"].startswith("https://sourceforge.net/projects/waydroid/files/images/"))
                self.assertIn(f"waydroid_{variant}-{kind.lower()}.zip", self.lock[f"{k}_URL"])
                self.assertIn("VANILLA" if kind == "SYSTEM" else "MAINLINE", self.lock[f"{k}_URL"])
                self.assertRegex(self.lock[f"{k}_SHA256"], r"^[0-9a-f]{64}$")
                self.assertRegex(self.lock[f"{k}_SIZE"], r"^[1-9][0-9]+$")
                self.assertRegex(self.lock[f"{k}_IMG_SIZE"], r"^[1-9][0-9]+$")
                self.assertRegex(self.lock[f"{k}_IMG_CRC32"], r"^[0-9a-f]{8}$")

    def test_no_google_apps(self):
        for key, value in self.lock.items():
            if key.startswith("WAYDROID_"):
                self.assertNotIn("GAPPS", value)

    def test_fdroid_pins(self):
        self.assertRegex(self.lock["FDROID_APK_URL"], r"^https://f-droid\.org/repo/org\.fdroid\.fdroid_\d+\.apk$")
        self.assertEqual(self.lock["FDROID_SIG_URL"], self.lock["FDROID_APK_URL"] + ".asc")
        self.assertRegex(self.lock["FDROID_APK_SHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(self.lock["FDROID_APK_CERT_SHA256"], r"^[0-9a-f]{64}$")
        self.assertRegex(self.lock["FDROID_SIGNING_KEY_FPR"], r"^[0-9A-F]{40}$")
        self.assertTrue(os.path.exists(os.path.join(ROOT, "device", "oneplus-hotdog", "keys", "f-droid.asc")))


class OverlayTest(unittest.TestCase):
    def test_android_files_only_in_the_android_overlay(self):
        # Images built without ANTUMBRA_ANDROID=1 carry none of these.
        for rel in ("usr/lib/systemd/system/antumbra-waydroid.service",
                    "usr/lib/systemd/system/antumbra-waydroid-dhcp.service",
                    "usr/local/lib/antumbra-waydroid-start-host",
                    "usr/share/applications/antumbra-android.desktop",
                    "usr/share/antumbra/android/torrc"):
            self.assertTrue(os.path.exists(os.path.join(ANDROID, rel)), rel)
            self.assertFalse(os.path.exists(os.path.join(OVERLAY, rel)), rel)
        self.assertFalse(os.path.exists(os.path.join(OVERLAY, "usr", "share", "antumbra", "android")))
        self.assertNotIn("10.200.2.1", read("config", "rootfs", "etc", "tor", "torrc"))

    def test_launchers_fit_the_phone(self):
        for rel in ("usr/share/applications/antumbra-android.desktop",):
            text = read("config", "rootfs-android", *rel.split("/"))
            self.assertIn("X-Purism-FormFactor=Workstation;Mobile;", text)
        hidden = read("config", "rootfs-android", "usr", "local", "share", "applications", "Waydroid.desktop")
        self.assertIn("NoDisplay=true", hidden)


if __name__ == "__main__":
    unittest.main()
