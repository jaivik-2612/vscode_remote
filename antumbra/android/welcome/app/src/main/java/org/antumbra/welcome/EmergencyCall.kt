// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.SystemClock
import android.telecom.TelecomManager
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlin.math.ceil

/**
 * The "Emergency call" button on the Welcome and status screens.
 *
 * It opens the system's emergency dial pad, which calls emergency numbers
 * only and knows them for the country, the network and the SIM: Welcome
 * never names a number. Before Start the dial pad joins Welcome's locked
 * task, which an activity started from inside it may always do. The call
 * screen that Telecom shows next is the system dialer's, in a task of its
 * own; the lock task lets it through because Home sets
 * LOCK_TASK_FEATURE_KEYGUARD (see [Home]).
 *
 * Before Start nothing else leads back to a call whose screen has left the
 * front (Back on the call screen does that): the locked task keeps the
 * notification shade, the ongoing-call chip, recents and Home off. So
 * during a call the Welcome screen shows "Return to call" ([returnToCall]).
 */
object EmergencyCall {
    private const val TAG = "AntumbraEmergencyCall"

    /**
     * Intent.ACTION_DIAL_EMERGENCY, a system API constant: the emergency
     * dial pad (com.android.phone/.EmergencyDialer in AOSP, exported
     * without a permission). The manifest's queries entry makes its
     * handlers visible to this app.
     */
    const val ACTION_DIAL_EMERGENCY = "android.intent.action.DIAL_EMERGENCY"

    /**
     * The emergency dial pad of a system app, as an explicit intent, or
     * null if the phone has none. Only system apps are asked, so an app
     * installed later can neither stand in for it nor add a chooser.
     */
    fun dialerIntent(context: Context): Intent? {
        val query = Intent(ACTION_DIAL_EMERGENCY)
        val flags = PackageManager.MATCH_DEFAULT_ONLY or PackageManager.MATCH_SYSTEM_ONLY
        val handler = context.packageManager
            .queryIntentActivities(query, PackageManager.ResolveInfoFlags.of(flags.toLong()))
            .firstOrNull()?.activityInfo ?: return null
        return query.setClassName(handler.packageName, handler.name)
    }

    /**
     * Opens the emergency dial pad on top of [activity], in its task (no
     * FLAG_ACTIVITY_NEW_TASK). Returns false if there is none or it would
     * not start; the caller says so.
     */
    fun open(activity: Activity): Boolean {
        val intent = dialerIntent(activity)
        if (intent == null) {
            Log.w(TAG, "no system app handles $ACTION_DIAL_EMERGENCY")
            return false
        }
        return try {
            activity.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.w(TAG, "the emergency dial pad did not start", e)
            false
        }
    }

    /**
     * READ_PHONE_STATE, which [returnToCall] needs; a device owner may grant
     * it to itself (it is not one of the sensor permissions Android keeps
     * from admins). Granted before Start by [Home.claim]. Blocks for the
     * grant; true when Welcome holds the permission.
     */
    fun grantPhoneState(context: Context): Boolean {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
            return true
        }
        val dpm = context.getSystemService(DevicePolicyManager::class.java)
        if (!dpm.isDeviceOwnerApp(context.packageName)) return false
        return try {
            dpm.setPermissionGrantState(
                AdminReceiver.component(context), context.packageName, Manifest.permission.READ_PHONE_STATE,
                DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED,
            )
        } catch (e: Exception) {
            Log.w(TAG, "could not grant READ_PHONE_STATE", e)
            false
        }
    }

    /**
     * Brings the call screen of the call in progress back to the front:
     * TelecomManager.showInCallScreen, with READ_PHONE_STATE. Telecom asks
     * the system dialer's in-call service to start its call screen, in a
     * task of its own, which LOCK_TASK_FEATURE_KEYGUARD lets through the
     * lock task. Telecom does nothing when there is no call. Returns false
     * if Welcome could not ask; the caller says so.
     */
    fun returnToCall(context: Context): Boolean {
        grantPhoneState(context)
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "no READ_PHONE_STATE: cannot bring the call screen back")
            return false
        }
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return false
        return try {
            telecom.showInCallScreen(false)
            true
        } catch (e: SecurityException) {
            Log.w(TAG, "showInCallScreen refused", e)
            false
        }
    }
}

/** Why Panic off waits. */
enum class PanicHold { CALL, CALLBACK_MODE, AFTER_CALL }

/**
 * The end of the last phone call, from the audio mode. Only the phone
 * service may set MODE_IN_CALL and MODE_CALL_REDIRECT (AudioService
 * requires MODIFY_PHONE_STATE), so no app can fake a call; Telecom sets
 * MODE_IN_CALL while a SIM call (an emergency call among them) is dialling,
 * active or held. A call that is still connecting (the radio being switched
 * on for an emergency call, a few seconds) is not seen yet.
 */
class CallRecord {
    @Volatile
    var inCall: Boolean = false
        private set

    /** SystemClock.elapsedRealtime() when the last call ended; null if none in this process. */
    var lastEnd: Long? = null
        private set

    @Synchronized
    fun onMode(mode: Int, now: Long) {
        val call = isCallMode(mode)
        if (inCall && !call) lastEnd = now
        inCall = call
    }

    /** Minutes Panic off still waits after the last call, rounded up; 0 when it does not. */
    @Synchronized
    fun minutesLeft(now: Long): Int {
        val end = lastEnd ?: return 0
        // elapsedRealtime only grows within a boot; anything else counts as just ended.
        val left = (CallWatch.CALLBACK_WINDOW_MS - (now - end)).coerceIn(0L, CallWatch.CALLBACK_WINDOW_MS)
        return ceil(left / 60_000.0).toInt()
    }

    /**
     * What holds Panic off now: a call in progress (seen now, [callNow], or
     * by the listener), emergency callback mode, or a call that ended less
     * than [CallWatch.CALLBACK_WINDOW_MS] ago. Null when nothing does.
     */
    @Synchronized
    fun hold(callNow: Boolean, callbackMode: Boolean, now: Long): PanicHold? = when {
        callNow || inCall -> PanicHold.CALL
        callbackMode -> PanicHold.CALLBACK_MODE
        minutesLeft(now) > 0 -> PanicHold.AFTER_CALL
        else -> null
    }

    companion object {
        fun isCallMode(mode: Int): Boolean =
            mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_CALL_REDIRECT
    }
}

/**
 * Keeps Panic off from cutting an emergency call short, or from switching
 * the phone off while the emergency service may call back.
 *
 * Welcome cannot tell an emergency call from any other.
 * TelecomManager.isInEmergencyCall needs MODIFY_PHONE_STATE and
 * TelephonyManager.getEmergencyCallbackMode needs
 * READ_PRIVILEGED_PHONE_STATE: system APIs behind permissions that only the
 * platform and privileged apps hold, not a device owner. So every call
 * counts. Panic off waits during a call, while Android reports emergency
 * callback mode (on networks that use it), and for [CALLBACK_WINDOW_MS]
 * after any call ends. The record is in memory only, like the session, and
 * starts with the process.
 */
object CallWatch {
    private const val TAG = "AntumbraCallWatch"

    /** Android's own emergency callback mode lasts 5 minutes by default (EmergencyStateTracker). */
    const val CALLBACK_WINDOW_MS = 5 * 60 * 1000L

    // System API constants (TelephonyManager); a sticky, protected
    // broadcast that the phone process sends without a permission.
    private const val ACTION_EMERGENCY_CALLBACK_MODE_CHANGED = "android.intent.action.EMERGENCY_CALLBACK_MODE_CHANGED"
    private const val EXTRA_PHONE_IN_ECM_STATE = "android.telephony.extra.PHONE_IN_ECM_STATE"

    private val record = CallRecord()

    /**
     * A SIM call is in progress, as the listener last saw it; the Welcome
     * screen shows "Return to call" while it is. Set on the main thread.
     */
    var callInProgress by mutableStateOf(false)
        private set

    /** Follows the audio mode for the life of the process (WelcomeApp). */
    fun start(context: Context) {
        val audio = context.getSystemService(AudioManager::class.java) ?: return
        onMode(audio.mode)
        audio.addOnModeChangedListener(context.mainExecutor) { mode -> onMode(mode) }
    }

    private fun onMode(mode: Int) {
        record.onMode(mode, SystemClock.elapsedRealtime())
        callInProgress = CallRecord.isCallMode(mode)
    }

    /** Whether a SIM call is in progress now: the audio mode, or the listener's record. */
    fun inCall(context: Context): Boolean {
        val mode = context.getSystemService(AudioManager::class.java)?.mode ?: AudioManager.MODE_NORMAL
        return CallRecord.isCallMode(mode) || record.inCall
    }

    /** Whether the phone is in emergency callback mode, from the last sticky broadcast. */
    private fun inCallbackMode(context: Context): Boolean = try {
        // A null receiver registers nothing; it only returns the sticky intent.
        context.registerReceiver(null, IntentFilter(ACTION_EMERGENCY_CALLBACK_MODE_CHANGED), Context.RECEIVER_NOT_EXPORTED)
            ?.getBooleanExtra(EXTRA_PHONE_IN_ECM_STATE, false) == true
    } catch (e: Exception) {
        Log.w(TAG, "could not read the emergency callback mode", e)
        false
    }

    /** Why Panic off must wait now, for the person; null when it may go ahead. */
    fun holdMessage(context: Context): String? {
        val now = SystemClock.elapsedRealtime()
        val mode = context.getSystemService(AudioManager::class.java)?.mode ?: AudioManager.MODE_NORMAL
        return when (record.hold(CallRecord.isCallMode(mode), inCallbackMode(context), now)) {
            null -> null
            PanicHold.CALL -> context.getString(R.string.panic_wait_call)
            PanicHold.CALLBACK_MODE -> context.getString(R.string.panic_wait_callback_mode)
            PanicHold.AFTER_CALL -> record.minutesLeft(now).let {
                context.resources.getQuantityString(R.plurals.panic_wait_after_call, it, it)
            }
        }
    }
}
