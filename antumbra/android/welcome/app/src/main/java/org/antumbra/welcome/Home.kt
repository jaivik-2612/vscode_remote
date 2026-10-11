// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.util.Log

/**
 * Welcome as the home screen and a locked task until Start.
 *
 * Before Start: WelcomeActivity is enabled, it is the persistent preferred
 * home activity (so no "choose a home app" dialog), and it runs as a locked
 * task: no notification shade, recents or other apps. The power menu stays
 * (LOCK_TASK_FEATURE_GLOBAL_ACTIONS), so the phone can always be switched
 * off.
 *
 * At Start: the lock task ends, the preference is cleared and
 * WelcomeActivity is disabled, so the normal launcher is the only home.
 *
 * At shutdown and at boot, [claim] restores the "before Start" state.
 */
object Home {
    private const val TAG = "AntumbraHome"

    private fun welcome(context: Context) = ComponentName(context, WelcomeActivity::class.java)

    private val homeFilter: IntentFilter
        get() = IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            addCategory(Intent.CATEGORY_DEFAULT)
        }

    /** Makes Welcome the home screen and allows it to lock its task. Device owner only. */
    fun claim(context: Context) {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        if (!dpm.isDeviceOwnerApp(context.packageName)) return
        val admin = AdminReceiver.component(context)
        context.packageManager.setComponentEnabledSetting(
            welcome(context),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        dpm.setLockTaskPackages(admin, arrayOf(context.packageName))
        dpm.setLockTaskFeatures(admin, DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS)
        dpm.clearPackagePersistentPreferredActivities(admin, context.packageName)
        dpm.addPersistentPreferredActivity(admin, homeFilter, welcome(context))
    }

    /** Enters the locked task if Welcome may; called from WelcomeActivity.onResume. */
    fun lock(activity: Activity) {
        val dpm = activity.getSystemService(DevicePolicyManager::class.java)
        if (dpm.isLockTaskPermitted(activity.packageName) &&
            dpm.isDeviceOwnerApp(activity.packageName) &&
            !Session.current().started
        ) {
            try {
                activity.startLockTask()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "startLockTask failed", e)
            }
        }
    }

    /** Ends the "before Start" state; the caller then opens StatusActivity. */
    fun release(activity: Activity) {
        try {
            activity.stopLockTask()
        } catch (e: Exception) {
            Log.w(TAG, "stopLockTask failed", e)
        }
        val dpm = activity.getSystemService(DevicePolicyManager::class.java)
        if (!dpm.isDeviceOwnerApp(activity.packageName)) return
        val admin = AdminReceiver.component(activity)
        dpm.clearPackagePersistentPreferredActivities(admin, activity.packageName)
        dpm.setLockTaskPackages(admin, emptyArray())
    }

    /**
     * Undoes [claim] during a session (when Emergency off could not
     * restart the phone), without touching the current task.
     */
    fun unclaim(context: Context) {
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        if (!dpm.isDeviceOwnerApp(context.packageName)) return
        val admin = AdminReceiver.component(context)
        dpm.clearPackagePersistentPreferredActivities(admin, context.packageName)
        dpm.setLockTaskPackages(admin, emptyArray())
        disableWelcome(context)
    }

    /**
     * Disables WelcomeActivity so that the launcher becomes home. Called
     * after StatusActivity has started, because disabling the component
     * also finishes WelcomeActivity.
     */
    fun disableWelcome(context: Context) {
        if (!context.getSystemService(DevicePolicyManager::class.java).isDeviceOwnerApp(context.packageName)) return
        context.packageManager.setComponentEnabledSetting(
            welcome(context),
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP,
        )
    }

    /** Brings the Welcome screen to the front (from a receiver: device owners may start activities from the background). */
    fun showWelcome(context: Context) {
        context.startActivity(
            Intent(context, WelcomeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
