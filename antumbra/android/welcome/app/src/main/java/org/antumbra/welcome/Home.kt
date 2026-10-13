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
 * off, and emergency calls go through ([LOCK_TASK_FEATURES]).
 *
 * At Start: the lock task ends, the preference is cleared and
 * WelcomeActivity is disabled, so the normal launcher is the only home.
 *
 * At shutdown and at boot, [claim] restores the "before Start" state.
 */
object Home {
    private const val TAG = "AntumbraHome"

    /**
     * The locked task's features: the power menu, and the keyguard.
     *
     * The keyguard feature is what lets emergency calls through (WEL7).
     * LockTaskController (android16-release) lets these start outside the
     * locked task only while LOCK_TASK_FEATURE_KEYGUARD is set: the
     * emergency dial pad (com.android.phone/.EmergencyDialer, which the
     * power menu's and the keyguard's Emergency buttons open in a task of
     * their own), the emergency call intent, and any activity of the
     * system dialer, whose call screen Telecom shows during an emergency
     * call. Without it the power menu's Emergency button and that call
     * screen are refused. Welcome's own button needs no exemption (see
     * [EmergencyCall]).
     *
     * Its other effects, before Start:
     * - The keyguard is no longer held off during the locked task. With no
     *   screen lock nothing changes; with a swipe lock the swipe screen
     *   comes back after the screen goes off, and with a PIN the PIN is
     *   asked, as outside the locked task.
     * - The call screen of any call shows, an incoming call's too (the
     *   emergency service calling back is one). Its "Add call" button,
     *   which Telecom offers while no emergency call is in progress, opens
     *   the full dialer in a task of its own, and the exemption lets that
     *   in as well: ordinary calls, the call log and the dialer's settings
     *   are then reachable, and whatever they start without a new task
     *   joins that task (the lock task checks only a task's root). No
     *   setting avoids this: the call screen needs the dialer package
     *   either way, and LOCK_TASK_FEATURE_BLOCK_ACTIVITY_START_IN_TASK
     *   would block the call screen too. With the cellular radio off
     *   before Start (MOD6) no call comes in.
     *
     * Putting the dialer packages on the lock-task allowlist instead would
     * keep the keyguard away, but would let every activity of
     * com.android.phone and of the dialer start in the locked task (and
     * lock tasks of their own), and needs their names at run time. The
     * notification shade, Home and recents stay off either way.
     */
    const val LOCK_TASK_FEATURES =
        DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS or DevicePolicyManager.LOCK_TASK_FEATURE_KEYGUARD

    private fun welcome(context: Context) = ComponentName(context, WelcomeActivity::class.java)

    private val homeFilter: IntentFilter
        get() = IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            addCategory(Intent.CATEGORY_DEFAULT)
        }

    /**
     * Makes Welcome the home screen and allows it to lock its task, and
     * grants Welcome READ_PHONE_STATE for "Return to call" (see
     * [EmergencyCall.returnToCall]). Device owner only.
     */
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
        dpm.setLockTaskFeatures(admin, LOCK_TASK_FEATURES)
        dpm.clearPackagePersistentPreferredActivities(admin, context.packageName)
        dpm.addPersistentPreferredActivity(admin, homeFilter, welcome(context))
        EmergencyCall.grantPhoneState(context)
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
     * Undoes [claim] during a session (when Quick power off could not
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

    /**
     * Brings the Welcome screen to the front (from a receiver: device
     * owners may start activities from the background). [BootState] skips
     * it during a call, whose screen it would cover ([CallWatch.inCall]).
     */
    fun showWelcome(context: Context) {
        context.startActivity(
            Intent(context, WelcomeActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }
}
