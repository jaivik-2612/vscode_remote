// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.content.Context
import android.content.pm.ApplicationInfo
import java.io.File

/**
 * Test hooks for CI, honoured only by debuggable or testOnly builds. With
 * the first, Welcome leaves USB debugging on in every session, so that CI
 * can drive a session without Administration over adb; the second
 * ([emergencyStates], WEL10) sets the emergency card's state lines; the
 * third ([screenshots]) lets CI's screenshots show the Welcome screen while
 * it lists the apps for Location. A release build reads none of them.
 *
 * Set it with 'adb shell setprop debug.antumbra.keep_adb 1' before
 * 'dpm set-device-owner' (debug.* properties may be set by the shell user
 * and read by every app). Welcome then keeps a marker in its
 * device-protected storage, so the hook survives restarts until
 * 'setprop debug.antumbra.keep_adb 0' is seen.
 */
object TestHook {
    const val PROPERTY = "debug.antumbra.keep_adb"
    private const val MARKER = "test-keep-adb"

    fun isTestBuild(context: Context): Boolean =
        context.applicationInfo.flags and (ApplicationInfo.FLAG_DEBUGGABLE or ApplicationInfo.FLAG_TEST_ONLY) != 0

    fun keepAdb(context: Context): Boolean {
        if (!isTestBuild(context)) return false
        val marker = File(context.createDeviceProtectedStorageContext().filesDir, MARKER)
        return when (SystemProperty.read(PROPERTY)) {
            "1" -> {
                runCatching { marker.writeText("1\n") }
                true
            }
            "0" -> {
                marker.delete()
                false
            }
            else -> marker.exists()
        }
    }

    /** WEL10's hook: the emergency card's state lines, for CI's emulator, which cannot remove or lock its SIM. */
    const val EMERGENCY_STATES = "debug.antumbra.emergency_states"

    /**
     * The emergency card's lines from [EMERGENCY_STATES] ([EmergencyHook.parse]),
     * in a test build only. Any other build reads no property (no getprop is
     * started) and gets null: the card shows the real readings. Only the
     * card's state and number lines use it; it is never kept.
     */
    fun emergencyStates(context: Context): EmergencyHook? =
        EmergencyHook.effective(isTestBuild(context)) { SystemProperty.read(EMERGENCY_STATES) }

    /** CI's hook for its screenshots of the Welcome screen: set to 1, the app list for Location leaves the window capturable. */
    const val SCREENSHOTS = "debug.antumbra.screenshots"

    /**
     * [SCREENSHOTS] is 1, in a test build only ([WindowRules.screenshotHook]):
     * the Welcome screen's window is then not FLAG_SECURE for the app list
     * alone (WindowRules.showsApps), never for a position or typed bridge
     * lines. Any other build reads no property and gets false. Never kept.
     */
    fun screenshots(context: Context): Boolean =
        WindowRules.screenshotHook(isTestBuild(context)) { SystemProperty.read(SCREENSHOTS) }
}
