// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.util.Log
import java.io.File

/**
 * Emergency off, from the Quick Settings tile, the session notification and
 * the status screen.
 *
 * A device owner cannot power the phone off: the only power action Android
 * gives it is DevicePolicyManager.reboot(). A real power-off needs the
 * signature|privileged permission android.permission.SHUTDOWN, which this
 * app holds only if the Antumbra module installs it as a privileged app with
 * a privapp-permissions allowlist entry. So:
 *
 * 1. With SHUTDOWN: ask the system's ShutdownActivity to power off, without
 *    a confirmation dialog.
 * 2. Without it: write [POWEROFF_MARKER] in device-protected storage, then
 *    reboot. The module is asked to power the phone off early in the next
 *    boot when it finds the marker (README, "Emergency off"). A restart
 *    alone ends the session, but memory keeps traces for a short while.
 *
 * The marker is not deleted at boot, where Welcome would race the module.
 * Welcome deletes a leftover marker at Start and on becoming the device
 * owner (the module had its chance by then), and at a shutdown that this
 * process did not ask for, so a request the module did not act on never
 * powers off a later boot.
 */
object Emergency {
    private const val TAG = "AntumbraEmergency"

    /** In /data/user_de/0/org.antumbra.welcome/files/. */
    const val POWEROFF_MARKER = "poweroff-requested"

    // Hidden framework constants (frameworks/base Intent.java); the
    // activity behind them requires android.permission.SHUTDOWN.
    private const val ACTION_REQUEST_SHUTDOWN = "com.android.internal.intent.action.REQUEST_SHUTDOWN"
    private const val EXTRA_KEY_CONFIRM = "android.intent.extra.KEY_CONFIRM"
    private const val EXTRA_USER_REQUESTED_SHUTDOWN = "android.intent.extra.USER_REQUESTED_SHUTDOWN"
    private const val SHUTDOWN_PERMISSION = "android.permission.SHUTDOWN"

    /** Set when this process wrote the marker and asked for the restart. */
    @Volatile
    var requested: Boolean = false
        private set

    fun canPowerOff(context: Context): Boolean =
        context.checkSelfPermission(SHUTDOWN_PERMISSION) == PackageManager.PERMISSION_GRANTED

    fun canRestart(context: Context): Boolean =
        context.getSystemService(DevicePolicyManager::class.java).isDeviceOwnerApp(context.packageName)

    fun shutdownIntent(): Intent = Intent(ACTION_REQUEST_SHUTDOWN)
        .putExtra(EXTRA_KEY_CONFIRM, false)
        .putExtra(EXTRA_USER_REQUESTED_SHUTDOWN, true)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /**
     * Powers off, or restarts. Returns only if neither was possible, with
     * the reason. [startShutdown] starts the shutdown intent; the tile
     * passes its own starter (startActivityAndCollapse).
     */
    fun trigger(context: Context, startShutdown: (Intent) -> Unit = { context.startActivity(it) }): String {
        val inSession = Session.current().started
        if (canPowerOff(context)) {
            // The next boot must show Welcome even if the shutdown
            // broadcast is not delivered in time.
            claimForNextBoot(context)
            try {
                startShutdown(shutdownIntent())
                return ""
            } catch (e: Exception) {
                Log.w(TAG, "shutdown intent failed; restarting instead", e)
            }
        }
        if (!canRestart(context)) {
            if (inSession) runCatching { Home.unclaim(context) }
            return context.getString(R.string.power_off_unavailable)
        }
        val marker = marker(context)
        requested = true
        try {
            marker.writeText("1\n")
        } catch (e: Exception) {
            Log.w(TAG, "could not write the power-off request", e)
        }
        claimForNextBoot(context)
        return try {
            context.getSystemService(DevicePolicyManager::class.java)
                .reboot(AdminReceiver.component(context))
            ""
        } catch (e: Exception) {
            // IllegalStateException during a phone call: the session goes
            // on, so put things back as they were.
            Log.w(TAG, "reboot refused", e)
            requested = false
            marker.delete()
            if (inSession) runCatching { Home.unclaim(context) }
            context.getString(R.string.power_off_failed, e.message ?: e.javaClass.simpleName)
        }
    }

    private fun marker(context: Context) = File(context.createDeviceProtectedStorageContext().filesDir, POWEROFF_MARKER)

    /** Deletes a power-off request left from an earlier boot. */
    fun clearRequest(context: Context) {
        if (marker(context).delete()) Log.i(TAG, "removed a power-off request the module did not act on")
    }

    private fun claimForNextBoot(context: Context) {
        try {
            Home.claim(context)
        } catch (e: Exception) {
            Log.w(TAG, "could not restore the boot state", e)
        }
    }
}
