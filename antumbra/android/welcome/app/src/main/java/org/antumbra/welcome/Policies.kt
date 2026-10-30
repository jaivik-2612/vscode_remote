// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.annotation.SuppressLint
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.os.SystemClock
import android.os.UserManager
import android.provider.Settings
import android.util.Log

/** What [Policies.applyAtStart] did. */
data class StartPolicies(
    /** Every policy that failed, by name; shown on the status screen. */
    val failed: List<String>,
    /**
     * The failed policies that keep traffic from going around the firewall
     * or out of a locked Wi-Fi. A session that uses the network is refused
     * when this is not empty; nothing was loosened then.
     */
    val protective: List<String>,
    /** Wi-Fi should be on but is not (airplane mode refuses a device owner); the user can switch it on. */
    val wifiNotOn: Boolean,
) {
    val refused: Boolean get() = protective.isNotEmpty()
}

/**
 * The device-owner policies (README, "Device-owner policies"). Every call
 * is idempotent and safe to repeat; each failure is logged and returned by
 * name rather than stopping the rest.
 *
 * Restrictions set by a device owner persist across reboots. So the state
 * before Start ([applyBaseline]) is the strict one, and it is applied again
 * at boot, on becoming the device owner, at shutdown and at every Start;
 * only Start loosens anything, and only for the choices made.
 */
class Policies(private val context: Context) {
    private val dpm = context.getSystemService(DevicePolicyManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private val admin = AdminReceiver.component(context)

    val isDeviceOwner: Boolean get() = dpm.isDeviceOwnerApp(context.packageName)

    /**
     * The state before Start, and the base of every session:
     * - the restrictions in [ALWAYS] (no safe-mode boot, no tethering, no
     *   Wi-Fi Direct, no private-DNS change, Location off and locked, no
     *   NFC on Android 15 and later);
     * - the restrictions in [UNLESS_ADMIN], which only an Administration
     *   Start lifts, until the next shutdown or boot;
     * - USB debugging off: DISALLOW_DEBUGGING_FEATURES and the adb settings
     *   reset, in every session (the debug-build test hook aside, [TestHook]);
     * - no automatic time or time zone, and the time zone set to UTC;
     * - no device name in DHCP requests (Android 15 and later).
     *
     * Location goes off through [Position.offWhenSafe] (WEL10): nothing is
     * written when it is already off, and while a call, emergency callback
     * mode or the 5 minutes after a call hold, it stays as it is until the
     * hold ends. Only [atShutdown] switches it off at once.
     */
    fun applyBaseline(atShutdown: Boolean = false): List<String> {
        val failures = ArrayList<String>()
        for (key in always()) step(failures, key) { dpm.addUserRestriction(admin, key) }
        for (key in UNLESS_ADMIN) step(failures, key) { dpm.addUserRestriction(admin, key) }
        step(failures, "location") {
            if (atShutdown) {
                check(Position.offNow(context)) { "Location is still on" }
            } else {
                check(Position.offWhenSafe(context) != PositionMachine.Off.FAILED) { "Location is still on" }
            }
        }
        failures += debugging()
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
        // Android 15 and later send Settings.Global.DEVICE_NAME (the model
        // name by default) as the DHCP host name on every Wi-Fi network,
        // from a packet socket below the firewall. A device owner may forbid
        // it for open and secure networks alike (WifiServiceImpl).
        step(failures, "dhcp_hostname") { noDhcpHostname() }
        return failures
    }

    // The SDK lists NETWORK_SETTINGS or NETWORK_SETUP_WIZARD; the service
    // also accepts the device owner (WifiServiceImpl.setSendDhcpHostnameRestriction).
    @SuppressLint("MissingPermission")
    private fun noDhcpHostname() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        wifi.setSendDhcpHostnameRestriction(
            WifiManager.FLAG_SEND_DHCP_HOSTNAME_RESTRICTION_OPEN or
                WifiManager.FLAG_SEND_DHCP_HOSTNAME_RESTRICTION_SECURE,
        )
    }

    /**
     * USB debugging off, in every session, Administration included
     * ("Administration gets no debugging", pivot checks): the restriction,
     * then the adb settings set to 0 (a device owner may write them;
     * DevicePolicyManagerService GLOBAL_SETTINGS_ALLOWLIST). The only
     * exception is the test hook of debuggable or testOnly builds, with
     * which CI keeps adb ([TestHook]).
     */
    private fun debugging(): List<String> {
        val failures = ArrayList<String>()
        val key = UserManager.DISALLOW_DEBUGGING_FEATURES
        if (TestHook.keepAdb(context)) {
            Log.w(TAG, "test build with ${TestHook.PROPERTY}: USB debugging is left on")
            step(failures, key) { dpm.clearUserRestriction(admin, key) }
            return failures
        }
        step(failures, key) { dpm.addUserRestriction(admin, key) }
        step(failures, "adb_enabled") { dpm.setGlobalSetting(admin, Settings.Global.ADB_ENABLED, "0") }
        step(failures, "adb_wifi_enabled") { dpm.setGlobalSetting(admin, ADB_WIFI_ENABLED, "0") }
        return failures
    }

    /**
     * At Start, in this order:
     * 1. [applyBaseline] again, and Wi-Fi locked off (and checked to be off)
     *    unless the session's Internet is Wi-Fi and the add-on is present
     *    (a mobile-data session has Wi-Fi off too: its Internet is the
     *    SIM's, which the module switches on);
     * 2. if the session has Internet (Wi-Fi or mobile data) and a
     *    protective policy failed, stop here: nothing is loosened and the
     *    caller refuses the session;
     * 3. Administration lifts [UNLESS_ADMIN];
     * 4. Wi-Fi is unlocked and switched on for a Wi-Fi session with the
     *    add-on.
     */
    fun applyAtStart(choices: Choices, addOnPresent: Boolean): StartPolicies {
        val failures = ArrayList(applyBaseline())
        val network = choices.internet != Internet.NONE
        val wifiAllowed = wifiAllowed(choices, addOnPresent)
        if (!wifiAllowed) {
            failures += lockWifiOff(waitMs = WIFI_WAIT_MS)
            failures += forgetWifiNetworks()
        }
        val protective = failures.filter { it in PROTECTIVE }
        if (network && protective.isNotEmpty()) {
            return StartPolicies(failures, protective, wifiNotOn = false)
        }
        if (choices.admin) {
            for (key in UNLESS_ADMIN) step(failures, key) { dpm.clearUserRestriction(admin, key) }
        }
        // The session notification (Quick power off, progress).
        step(failures, "notifications") {
            check(
                dpm.setPermissionGrantState(
                    admin, context.packageName, Manifest.permission.POST_NOTIFICATIONS,
                    DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
                ),
            ) { "permission grant refused" }
        }
        var wifiNotOn = false
        if (wifiAllowed) {
            val unlock = unlockWifi()
            wifiNotOn = WIFI_NOT_ON in unlock
            failures += unlock.filter { it != WIFI_NOT_ON }
        }
        return StartPolicies(failures, emptyList(), wifiNotOn)
    }

    /**
     * Wi-Fi off and locked: DISALLOW_CHANGE_WIFI_STATE (the user cannot
     * switch it on; a device owner still can), DISALLOW_CONFIG_WIFI and
     * DISALLOW_ADD_WIFI_CONFIG (no network can be added or changed). Used
     * before Start, at shutdown, in sessions whose Internet is not Wi-Fi,
     * and when the add-on is missing.
     *
     * In airplane mode Android lets only Settings switch Wi-Fi
     * (WifiServiceImpl.setWifiEnabled), so a Wi-Fi switched on by hand in
     * airplane mode stays on. The configuration restrictions and the
     * removed networks then still leave it nothing to join. With [waitMs]
     * > 0 the Wi-Fi state is checked until then, and "wifi_off" is a
     * failure if Wi-Fi is not off.
     */
    fun lockWifiOff(waitMs: Long = 0): List<String> {
        val failures = ArrayList<String>()
        for (key in WIFI_LOCK) step(failures, key) { dpm.addUserRestriction(admin, key) }
        step(failures, "wifi_off") {
            if (wifi.wifiState != WifiManager.WIFI_STATE_DISABLED) {
                @Suppress("DEPRECATION") // Still allowed to a device owner.
                val accepted = wifi.setWifiEnabled(false)
                if (waitMs > 0) {
                    check(waitForWifi(WifiManager.WIFI_STATE_DISABLED, waitMs)) {
                        "Wi-Fi is still on (setWifiEnabled(false) ${if (accepted) "accepted" else "refused"}" +
                            "${if (airplaneMode()) ", airplane mode" else ""})"
                    }
                } else {
                    check(accepted) { "setWifiEnabled(false) refused" }
                }
            }
        }
        return failures
    }

    /**
     * Lifts the Wi-Fi lock and switches Wi-Fi on. Returns [WIFI_NOT_ON] among
     * the failures when Wi-Fi stays off (airplane mode); the user can then
     * switch it on, since the lock is gone.
     */
    private fun unlockWifi(): List<String> {
        val failures = ArrayList<String>()
        for (key in WIFI_LOCK) step(failures, key) { dpm.clearUserRestriction(admin, key) }
        if (wifi.wifiState == WifiManager.WIFI_STATE_ENABLED || wifi.wifiState == WifiManager.WIFI_STATE_ENABLING) {
            return failures
        }
        val accepted = try {
            @Suppress("DEPRECATION") // Still allowed to a device owner.
            wifi.setWifiEnabled(true)
        } catch (e: Exception) {
            Log.w(TAG, "setWifiEnabled(true) failed", e)
            false
        }
        if (!accepted) {
            Log.w(TAG, "Wi-Fi not switched on${if (airplaneMode()) " (airplane mode)" else ""}")
            failures += WIFI_NOT_ON
        }
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

    private fun waitForWifi(state: Int, timeoutMs: Long): Boolean {
        val end = SystemClock.elapsedRealtime() + timeoutMs
        while (true) {
            if (wifi.wifiState == state) return true
            if (SystemClock.elapsedRealtime() >= end) return false
            SystemClock.sleep(200)
        }
    }

    private fun airplaneMode(): Boolean =
        Settings.Global.getInt(context.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1

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

        /** How long Start waits for Wi-Fi to be off. */
        const val WIFI_WAIT_MS = 5_000L

        /** Settings.Global.ADB_WIFI_ENABLED (hidden in the SDK; in DPMS's allowlist). */
        private const val ADB_WIFI_ENABLED = "adb_wifi_enabled"

        /** Marks "Wi-Fi should be on but is not" among unlockWifi's results. */
        private const val WIFI_NOT_ON = "wifi_on"

        /** NFC radio off (UserManager.DISALLOW_NEAR_FIELD_COMMUNICATION_RADIO, API 35). */
        private const val DISALLOW_NFC_RADIO = "no_near_field_communication_radio"

        /** Wi-Fi is unlocked and switched on only for a Wi-Fi session with the add-on. */
        fun wifiAllowed(choices: Choices, addOnPresent: Boolean): Boolean =
            choices.internet == Internet.WIFI && addOnPresent

        val ALWAYS = listOf(
            // Android's safe mode starts without third-party code, and
            // Magisk loads no module in it.
            UserManager.DISALLOW_SAFE_BOOT,
            // Tethered traffic is forwarded or offloaded below the firewall.
            UserManager.DISALLOW_CONFIG_TETHERING,
            // Wi-Fi Direct groups and discovery bypass the firewall and show
            // the device name.
            UserManager.DISALLOW_WIFI_DIRECT,
            // The module sets private DNS off; a DNS-over-TLS host set by
            // the user would go around the tracker filter.
            UserManager.DISALLOW_CONFIG_PRIVATE_DNS,
            // Location stays off in every session (WEL8): Administration
            // no longer lifts it, and until WEL9 ("off, or on for chosen
            // apps") nothing switches it on but Welcome itself, for one
            // satellite fix the person asks for (WEL10, Position.kt; the
            // device owner's switch is system_server's write, which the
            // restriction lets through). Sessions without Administration
            // already had it so; emergency calls are as before (the
            // restriction blocks no call).
            UserManager.DISALLOW_CONFIG_LOCATION,
        )

        /** [ALWAYS], plus the NFC radio off where Android has that restriction (15 and later). */
        fun always(): List<String> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM) ALWAYS + DISALLOW_NFC_RADIO else ALWAYS

        /** Set before Start and in every session; lifted by Administration until the next shutdown. */
        val UNLESS_ADMIN = listOf(
            // Apps from anywhere but the preinstalled store.
            UserManager.DISALLOW_INSTALL_UNKNOWN_SOURCES_GLOBALLY,
            // Bluetooth tethering and nearby-device scans; off by default.
            UserManager.DISALLOW_BLUETOOTH,
        )

        /** Wi-Fi off and nothing to join: set before Start, lifted only by a network Start with the add-on. */
        val WIFI_LOCK = listOf(
            UserManager.DISALLOW_CHANGE_WIFI_STATE,
            UserManager.DISALLOW_CONFIG_WIFI,
            UserManager.DISALLOW_ADD_WIFI_CONFIG,
        )

        /**
         * Failures that refuse a network session: without them, traffic
         * can go below the firewall (tethering, Wi-Fi Direct, safe mode),
         * adb stays reachable, or a Wi-Fi that must stay off is not locked.
         */
        val PROTECTIVE = setOf(
            UserManager.DISALLOW_SAFE_BOOT,
            UserManager.DISALLOW_CONFIG_TETHERING,
            UserManager.DISALLOW_WIFI_DIRECT,
            UserManager.DISALLOW_DEBUGGING_FEATURES,
            "wifi_off",
            "forget_wifi",
        ) + WIFI_LOCK
    }
}
