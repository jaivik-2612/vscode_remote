// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import kotlin.concurrent.thread

/** The device-admin receiver named in 'dpm set-device-owner org.antumbra.welcome/.AdminReceiver'. */
class AdminReceiver : DeviceAdminReceiver() {
    override fun onEnabled(context: Context, intent: Intent) {
        // Called when the admin is activated, which for 'dpm
        // set-device-owner' is a moment before it becomes the device owner;
        // BootReceiver finishes the set-up on DEVICE_OWNER_CHANGED.
        BootState.prepareAsync(this, context, "admin enabled")
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
            -> BootState.prepareAsync(this, context, intent.action.orEmpty())
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

    /**
     * Held while policies change, here and at Start, so that a late boot
     * broadcast cannot lock Wi-Fi again after a Start has opened it.
     */
    val lock = Any()

    /** [prepare] off the main thread: it waits for Wi-Fi to be off. */
    fun prepareAsync(receiver: BroadcastReceiver, context: Context, why: String) {
        val pending = receiver.goAsync()
        val app = context.applicationContext
        thread(name = "antumbra-boot") {
            try {
                prepare(app, why)
            } finally {
                pending.finish()
            }
        }
    }

    fun prepare(context: Context, why: String) = synchronized(lock) {
        // Never undo a running session (BOOT_COMPLETED can arrive after
        // Start when user 0 has a lock-screen credential).
        if (Session.current().started) return@synchronized
        val policies = Policies(context)
        if (!policies.isDeviceOwner) {
            Log.i(TAG, "$why: not the device owner; nothing to do")
            return@synchronized
        }
        // A fresh device owner: no power-off request can be meant for it.
        // At boot the marker stays, for the module to find.
        if (why == DevicePolicyManager.ACTION_DEVICE_OWNER_CHANGED) Emergency.clearRequest(context)
        val failures = policies.applyBaseline() +
            policies.lockWifiOff(waitMs = Policies.WIFI_WAIT_MS) +
            policies.forgetWifiNetworks()
        try {
            Home.claim(context)
            Home.showWelcome(context)
        } catch (e: Exception) {
            Log.w(TAG, "$why: could not show Welcome", e)
        }
        if (failures.isNotEmpty()) Log.w(TAG, "$why: failed: ${failures.joinToString()}")
    }

    /**
     * At shutdown: the next boot starts in Welcome, with the strict
     * policies, debugging off, Wi-Fi off and locked, and no saved networks.
     * Runs on the main thread within the shutdown broadcast's time, so it
     * does not wait for Wi-Fi.
     */
    fun atShutdown(context: Context) {
        val policies = Policies(context)
        if (!policies.isDeviceOwner) return
        // A shutdown this process did not ask for: a power-off request left
        // from an earlier boot must not power off the next one.
        if (!Emergency.requested) Emergency.clearRequest(context)
        try {
            Home.claim(context)
        } catch (e: Exception) {
            Log.w(TAG, "shutdown: could not restore home", e)
        }
        val failures = policies.applyBaseline() + policies.lockWifiOff() + policies.forgetWifiNetworks()
        if (failures.isNotEmpty()) Log.w(TAG, "shutdown: failed: ${failures.joinToString()}")
    }
}
