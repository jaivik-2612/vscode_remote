// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

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

    @Test
    fun wifiLockHasAllThreeRestrictions() {
        assertTrue(Policies.WIFI_LOCK.containsAll(listOf("no_change_wifi_state", "no_config_wifi", "no_add_wifi_config")))
        assertTrue(Policies.ALWAYS.containsAll(listOf("no_safe_boot", "no_config_tethering", "no_wifi_direct", "disallow_config_private_dns")))
    }
}
