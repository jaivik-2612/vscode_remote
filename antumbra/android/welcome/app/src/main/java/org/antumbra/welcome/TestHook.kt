// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.content.Context
import android.content.pm.ApplicationInfo
import java.io.File

/**
 * Test hooks for CI, honoured only by debuggable or testOnly builds. With
 * the first, Welcome leaves USB debugging on in every session, so that CI
 * can drive a session without Administration over adb; the second
 * ([emergencyStates], WEL10) sets the emergency card's state lines. A
 * release build reads neither.
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
}
