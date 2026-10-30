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
        listOf("auto_time", "time_zone", "location", "notifications", "dhcp_hostname", "disallow_config_private_dns")
            .forEach { assertFalse(it, it in Policies.PROTECTIVE) }
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
