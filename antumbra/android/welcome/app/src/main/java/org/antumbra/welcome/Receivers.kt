// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import java.io.File

/** The device-admin receiver named in 'dpm set-device-owner org.antumbra.welcome/.AdminReceiver'. */
class AdminReceiver : DeviceAdminReceiver() {
    override fun onEnabled(context: Context, intent: Intent) {
        // Called when the admin is activated, which for 'dpm
        // set-device-owner' is a moment before it becomes the device owner;
        // BootReceiver finishes the set-up on DEVICE_OWNER_CHANGED.
        BootState.prepare(context, "admin enabled")
    }

    companion object {
        fun component(context: Context) = ComponentName(context, AdminReceiver::class.java)
    }
}

/** Boot (locked and unlocked) and the moment Welcome becomes the device owner. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_BOOT_COMPLETED,
            DevicePolicyManager.ACTION_DEVICE_OWNER_CHANGED,
            -> BootState.prepare(context, intent.action.orEmpty())
        }
    }
}

/** The session notification's "Emergency off" action. */
class EmergencyReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val problem = Emergency.trigger(context)
        if (problem.isNotEmpty()) Log.w("AntumbraEmergency", problem)
    }
}

/**
 * The state before Start, set at boot, on becoming the device owner, and
 * (through WelcomeApp's shutdown receiver) at shutdown.
 */
object BootState {
    private const val TAG = "AntumbraBoot"

    fun prepare(context: Context, why: String) {
        // Never undo a running session (BOOT_COMPLETED can arrive after
        // Start when user 0 has a lock-screen credential).
        if (Session.current().started) return
        val policies = Policies(context)
        if (!policies.isDeviceOwner) {
            Log.i(TAG, "$why: not the device owner; nothing to do")
            return
        }
        // A power-off request the module did not act on must not power off
        // a later boot.
        File(context.createDeviceProtectedStorageContext().filesDir, Emergency.POWEROFF_MARKER).delete()
        val failures = policies.applyBaseline() + policies.lockWifiOff() + policies.forgetWifiNetworks()
        try {
            Home.claim(context)
            Home.showWelcome(context)
        } catch (e: Exception) {
            Log.w(TAG, "$why: could not show Welcome", e)
        }
        if (failures.isNotEmpty()) Log.w(TAG, "$why: failed: ${failures.joinToString()}")
    }

    /** At shutdown: the next boot starts in Welcome, with Wi-Fi off and no saved networks. */
    fun atShutdown(context: Context) {
        val policies = Policies(context)
        if (!policies.isDeviceOwner) return
        try {
            Home.claim(context)
        } catch (e: Exception) {
            Log.w(TAG, "shutdown: could not restore home", e)
        }
        policies.lockWifiOff()
        policies.forgetWifiNetworks()
    }
}
