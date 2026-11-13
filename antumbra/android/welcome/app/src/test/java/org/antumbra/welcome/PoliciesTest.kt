// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The policy lists, without Android: which failures refuse a network session. */
class PoliciesTest {
    @Test
    fun debuggingIsNeverLiftedByAdministration() {
        assertFalse("no_debugging_features" in Policies.UNLESS_ADMIN)
        assertTrue("no_debugging_features" in Policies.PROTECTIVE)
    }

    @Test
    fun protectiveFailuresCoverTheBypassesAndTheWifiLock() {
        listOf(
            "no_safe_boot", "no_config_tethering", "no_wifi_direct",
            "no_change_wifi_state", "no_config_wifi", "no_add_wifi_config", "wifi_off", "forget_wifi",
        ).forEach { assertTrue(it, it in Policies.PROTECTIVE) }
        // Conveniences and privacy settings are reported, but do not refuse.
        listOf("auto_time", "time_zone", "location", "apps", "notifications", "dhcp_hostname", "disallow_config_private_dns")
            .forEach { assertFalse(it, it in Policies.PROTECTIVE) }
    }

    /**
     * WEL9: no telephony restriction, in any source: no 2G or network-type
     * restriction (on a carrier with no 2G they protect nothing and could
     * take away a fallback for an emergency call), no roaming, call or SMS
     * restriction, and no call or SMS permission set for any app.
     */
    @Test
    fun noTelephonyRestriction() {
        val forbidden = listOf(
            "DISALLOW_CELLULAR_2G", "no_cellular_2g", "setAllowedNetworkTypes", "setPreferredNetworkType", "NETWORK_TYPE_BITMASK",
            "ALLOWED_NETWORK_TYPES_REASON", "setNetworkSelectionModeManual", "DISALLOW_DATA_ROAMING", "no_data_roaming",
            "setDataRoamingEnabled", "DISALLOW_OUTGOING_CALLS", "no_outgoing_calls", "DISALLOW_SMS", "no_sms",
            "DISALLOW_CONFIG_MOBILE_NETWORKS", "no_config_mobile_networks", "DISALLOW_CONFIG_CELL_BROADCASTS",
            "DISALLOW_SIM_GLOBALLY", "setMinimumRequiredWifiSecurityLevel", "setMobileDataEnabled", "setDataEnabled",
            "CALL_PHONE", "SEND_SMS", "RECEIVE_SMS", "READ_SMS", "ANSWER_PHONE_CALLS", "READ_CALL_LOG", "PROCESS_OUTGOING_CALLS",
            "setDefaultDialer", "setDefaultSmsPackage", "ROLE_DIALER", "ROLE_SMS",
        )
        val sources = SourceScan.sources()
        assertTrue(sources.size > 20)
        for (f in sources) {
            val code = SourceScan.withoutComments(f.readText())
            for (w in forbidden) assertFalse("${f.name}: $w", code.contains(w))
        }
        // The restrictions Welcome sets are its lists, every one of them named.
        val all = Policies.ALWAYS + Policies.UNLESS_ADMIN + Policies.WIFI_LOCK + "no_debugging_features" + "no_near_field_communication_radio"
        assertTrue(all.none { it.contains("cellular") || it.contains("roaming") || it.contains("sms") || it.contains("calls") || it.contains("mobile") })
        val policies = SourceScan.code("Policies.kt")
        assertEquals(4, Regex("addUserRestriction\\(").findAll(policies).count())
        assertEquals(0, Regex("addUserRestriction\\(").findAll(SourceScan.sources().filter { it.name != "Policies.kt" }.joinToString { SourceScan.withoutComments(it.readText()) }).count())
    }

    @Test
    fun startIsRefusedOnlyWithProtectiveFailures() {
        assertFalse(StartPolicies(listOf("auto_time"), emptyList(), wifiNotOn = true).refused)
        assertTrue(StartPolicies(listOf("no_config_tethering"), listOf("no_config_tethering"), wifiNotOn = false).refused)
    }

    /**
     * WEL8: Administration no longer lifts the location restriction;
     * Location stays off in every session. WEL10: only Welcome switches it
     * on, for one fix, and the baseline's switch-off waits while a call
     * holds (Position.offWhenSafe), except at shutdown (PositionTest).
     */
    @Test
    fun locationIsLockedInEverySession() {
        assertTrue("no_config_location" in Policies.ALWAYS)
        assertFalse("no_config_location" in Policies.UNLESS_ADMIN)
        assertTrue(Policies.UNLESS_ADMIN.containsAll(listOf("no_install_unknown_sources_globally", "no_bluetooth")))
        val policies = java.io.File("src/main/java/org/antumbra/welcome/Policies.kt").readText()
        assertTrue(policies.contains("step(failures, \"location\") {"))
        assertTrue(policies.contains("Position.offWhenSafe(context)"))
        assertTrue(policies.contains("Position.offNow(context)"))
        // WEL9: every baseline (boot, device owner, Start) brings an apps pass; shutdown denies the chosen apps again, after Location off.
        assertTrue(policies.contains("step(failures, \"apps\") {"))
        assertTrue(policies.indexOf("step(failures, \"location\") {") < policies.indexOf("step(failures, \"apps\") {"))
    }

    /** WEL8: Wi-Fi is unlocked and switched on only for Internet = Wi-Fi, with the add-on. */
    @Test
    fun wifiOnlyForAWifiSession() {
        for (i in Internet.entries) {
            for (phone in listOf(false, true)) {
                val c = Choices().withInternet(i).withPhone(phone)
                assertEquals("$i $phone", i == Internet.WIFI, Policies.wifiAllowed(c, addOnPresent = true))
                assertFalse("$i $phone", Policies.wifiAllowed(c, addOnPresent = false))
            }
        }
    }

    @Test
    fun wifiLockHasAllThreeRestrictions() {
        assertTrue(Policies.WIFI_LOCK.containsAll(listOf("no_change_wifi_state", "no_config_wifi", "no_add_wifi_config")))
        assertTrue(Policies.ALWAYS.containsAll(listOf("no_safe_boot", "no_config_tethering", "no_wifi_direct", "disallow_config_private_dns")))
    }
}
