// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.admin.DeviceAdminReceiver
import android.app.admin.DevicePolicyManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log
import android.widget.Toast
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

/** The session notification's "Quick power off" action. */
class QuickPowerOffReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val problem = QuickPowerOff.trigger(context)
        if (problem.isNotEmpty()) {
            Log.w("AntumbraPowerOff", problem)
            // Why it did not switch off (a call, for example), where the person looks.
            Toast.makeText(context, problem, Toast.LENGTH_LONG).show()
        }
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
        if (why == DevicePolicyManager.ACTION_DEVICE_OWNER_CHANGED) QuickPowerOff.clearRequest(context)
        val failures = policies.applyBaseline() +
            policies.lockWifiOff(waitMs = Policies.WIFI_WAIT_MS) +
            policies.forgetWifiNetworks()
        try {
            Home.claim(context)
            // Not over a call's screen (BOOT_COMPLETED comes after the first
            // unlock, which may be during an emergency call made from the
            // keyguard): the call screen stays in front, and Welcome, still
            // home, comes back when the call screen closes.
            if (CallWatch.inCall(context)) Log.i(TAG, "$why: a call is in progress; Welcome stays behind it")
            else Home.showWelcome(context)
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
        if (!QuickPowerOff.requested) QuickPowerOff.clearRequest(context)
        try {
            Home.claim(context)
        } catch (e: Exception) {
            Log.w(TAG, "shutdown: could not restore home", e)
        }
        val failures = policies.applyBaseline() + policies.lockWifiOff() + policies.forgetWifiNetworks()
        if (failures.isNotEmpty()) Log.w(TAG, "shutdown: failed: ${failures.joinToString()}")
    }
}
