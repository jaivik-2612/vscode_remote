// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.net.wifi.WifiManager
import android.os.UserManager
import android.util.Log

/**
 * The device-owner policies (README, "Device-owner policies"). Every call
 * is idempotent and safe to repeat; each failure is logged and returned by
 * name rather than stopping the rest.
 *
 * Restrictions set by a device owner persist across reboots, so each one
 * that Start may loosen is set again, or cleared, at every Start.
 */
class Policies(private val context: Context) {
    private val dpm = context.getSystemService(DevicePolicyManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private val admin = AdminReceiver.component(context)

    val isDeviceOwner: Boolean get() = dpm.isDeviceOwnerApp(context.packageName)

    /**
     * Applied at boot, when Welcome becomes the device owner, and again at
     * Start, whatever the choices:
     * - no safe-mode boot (Android's safe mode; Magisk's own safe mode is
     *   separate and not affected);
     * - no tethering and no Wi-Fi Direct: tethered and Wi-Fi Direct traffic
     *   is forwarded or offloaded below the firewall;
     * - no automatic time or time zone, and the time zone set to UTC.
     */
    fun applyBaseline(): List<String> {
        val failures = ArrayList<String>()
        for (key in ALWAYS) step(failures, key) { dpm.addUserRestriction(admin, key) }
        // Automatic time would ask an NTP server (UDP 123) and the carrier
        // (NITZ) for the time outside Tor; the firewall rejects the NTP
        // query, so it only fails. The module sets the clock from Tor once
        // tor connects, as Tails does. Automatic time zone would follow the
        // network or location; UTC tells apps nothing about where you are.
        step(failures, "auto_time") { dpm.setAutoTimeEnabled(admin, false) }
        step(failures, "auto_time_zone") { dpm.setAutoTimeZoneEnabled(admin, false) }
        step(failures, "time_zone") {
            check(dpm.setTimeZone(admin, "UTC")) { "setTimeZone refused" }
        }
        return failures
    }

    /**
     * At Start, after [applyBaseline]. Administration loosens the
     * restrictions in [UNLESS_ADMIN] for this session only. Wi-Fi is turned
     * on only for a session that uses the network and only when the add-on
     * is present; otherwise it is turned off and locked off.
     */
    fun applyAtStart(choices: Choices, addOnPresent: Boolean): List<String> {
        val failures = ArrayList(applyBaseline())
        for (key in UNLESS_ADMIN) {
            step(failures, key) {
                if (choices.admin) dpm.clearUserRestriction(admin, key) else dpm.addUserRestriction(admin, key)
            }
        }
        // Location stays off in every session; with Administration the
        // user may turn it on in Settings.
        step(failures, "location") { dpm.setLocationEnabled(admin, false) }
        // The session notification (Emergency off, progress).
        step(failures, "notifications") {
            check(
                dpm.setPermissionGrantState(
                    admin, context.packageName, Manifest.permission.POST_NOTIFICATIONS,
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
                ),
            ) { "permission grant refused" }
        }
        if (choices.torMode == TorMode.OFFLINE || !addOnPresent) {
            failures += lockWifiOff()
        } else {
            failures += unlockWifi()
        }
        return failures
    }

    /**
     * Wi-Fi off, then DISALLOW_CHANGE_WIFI_STATE so that the user cannot
     * turn it back on (a device owner still can). Used before Start, at
     * shutdown, in offline sessions, and when the add-on is missing.
     */
    fun lockWifiOff(): List<String> {
        val failures = ArrayList<String>()
        @Suppress("DEPRECATION") // Still allowed to a device owner.
        step(failures, "wifi_off") { check(wifi.setWifiEnabled(false)) { "setWifiEnabled(false) refused" } }
        step(failures, UserManager.DISALLOW_CHANGE_WIFI_STATE) {
            dpm.addUserRestriction(admin, UserManager.DISALLOW_CHANGE_WIFI_STATE)
        }
        return failures
    }

    private fun unlockWifi(): List<String> {
        val failures = ArrayList<String>()
        step(failures, UserManager.DISALLOW_CHANGE_WIFI_STATE) {
            dpm.clearUserRestriction(admin, UserManager.DISALLOW_CHANGE_WIFI_STATE)
        }
        @Suppress("DEPRECATION") // Still allowed to a device owner.
        step(failures, "wifi_on") { check(wifi.setWifiEnabled(true)) { "setWifiEnabled(true) refused" } }
        return failures
    }

    /**
     * Removes every saved Wi-Fi network this app did not add (all of them
     * in v0). With the module, the network store is on tmpfs anyway; this
     * covers a boot without the module.
     */
    fun forgetWifiNetworks(): List<String> {
        val failures = ArrayList<String>()
        step(failures, "forget_wifi") { wifi.removeNonCallerConfiguredNetworks() }
        return failures
    }

    private inline fun step(failures: MutableList<String>, name: String, block: () -> Unit) {
        try {
            block()
        } catch (e: Exception) {
            Log.w(TAG, "policy $name failed", e)
            failures += name
        }
    }

    companion object {
        private const val TAG = "AntumbraPolicies"

        val ALWAYS = listOf(
            UserManager.DISALLOW_SAFE_BOOT,
            UserManager.DISALLOW_CONFIG_TETHERING,
            UserManager.DISALLOW_WIFI_DIRECT,
        )

        /** Set in every session unless Administration is on. */
        val UNLESS_ADMIN = listOf(
            // USB debugging and developer options (and with them adb).
            UserManager.DISALLOW_DEBUGGING_FEATURES,
            // Apps from anywhere but the preinstalled store.
            UserManager.DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY,
            // Bluetooth tethering and nearby-device scans; off by default.
            UserManager.DISALLOW_BLUETOOTH,
            // Turning Location on.
            UserManager.DISALLOW_CONFIG_LOCATION,
        )
    }
}
