// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.annotation.SuppressLint
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
import kotlin.math.max

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

/** Why Quick power off waits. */
enum class PowerOffHold { CALL, CALLBACK_MODE, AFTER_CALL }

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

    /**
     * Milliseconds Quick power off still waits after a call: the
     * [CallWatch.CALLBACK_WINDOW_MS] after the last call this process saw
     * end, unless the module's [words] cover that call and say it was an
     * ordinary call (MOD11), and at least as long as an emergency word from
     * the module asks. Without words (null), exactly as before MOD11.
     */
    @Synchronized
    fun waitLeftMs(now: Long, words: ModuleWords? = null): Long {
        val own = lastEnd?.let { end ->
            if (words?.relaxes(end, now) == true) {
                0L
            } else {
                // elapsedRealtime only grows within a boot; anything else counts as just ended.
                (CallWatch.CALLBACK_WINDOW_MS - (now - end)).coerceIn(0L, CallWatch.CALLBACK_WINDOW_MS)
            }
        } ?: 0L
        return max(own, words?.emergencyLeftMs(now) ?: 0L)
    }

    /** Minutes Quick power off still waits after a call ([waitLeftMs]), rounded up; 0 when it does not. */
    @Synchronized
    fun minutesLeft(now: Long, words: ModuleWords? = null): Int = ceil(waitLeftMs(now, words) / 60_000.0).toInt()

    /**
     * What holds Quick power off now: a call in progress (seen now,
     * [callNow], or by the listener), emergency callback mode, or the wait
     * after a call ([waitLeftMs]). Null when nothing does. The module's
     * [words] change only the last: during any call and in callback mode
     * Quick power off waits whatever they say.
     */
    @Synchronized
    fun hold(callNow: Boolean, callbackMode: Boolean, now: Long, words: ModuleWords? = null): PowerOffHold? = when {
        callNow || inCall -> PowerOffHold.CALL
        callbackMode -> PowerOffHold.CALLBACK_MODE
        waitLeftMs(now, words) > 0 -> PowerOffHold.AFTER_CALL
        else -> null
    }

    companion object {
        fun isCallMode(mode: Int): Boolean =
            mode == AudioManager.MODE_IN_CALL || mode == AudioManager.MODE_CALL_REDIRECT
    }
}

/**
 * Keeps Quick power off from cutting an emergency call short, or from
 * switching the phone off while the emergency service may call back.
 *
 * Welcome cannot tell an emergency call from any other by itself.
 * TelecomManager.isInEmergencyCall needs MODIFY_PHONE_STATE and
 * TelephonyManager.getEmergencyCallbackMode needs
 * READ_PRIVILEGED_PHONE_STATE: system APIs behind permissions that only the
 * platform and privileged apps hold, not a device owner. So Quick power off
 * waits during any call, while Android reports emergency callback mode (on
 * networks that use it), and for [CALLBACK_WINDOW_MS] after any call ends.
 *
 * The module, as root, can read Telecom's own record of each call on
 * Android 16 and tells Welcome after each of its looks (MOD11,
 * [ModuleWord]). Only one thing changes with it: the wait after a call is
 * skipped when a fresh word says every call of the last 5 minutes, that
 * one included, was an ordinary call. An emergency word makes Quick power
 * off wait at least until its end, even for a call this process did not
 * see. An unknown, missing, stale, refused or malformed word, or none at
 * all (the module not running, Android 17, which no longer keeps that
 * record), changes nothing. The record and the words are in memory only,
 * like the session, and start with the process.
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
    private val words = ModuleWords()

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

    /** The module's word (StateProvider.call, from root only); null for a malformed one. */
    fun take(word: ModuleWord?) = words.take(word, SystemClock.elapsedRealtime())

    /** The IMS registration the module last read, for WEL8's VoLTE line; UNKNOWN when missing or old. */
    fun ims(): ImsState = words.ims(SystemClock.elapsedRealtime())

    /**
     * A call is in progress, or one ended less than 5 minutes ago (the
     * module keeps the radio as it is then): WEL8's radio line says On.
     */
    fun callOrAfter(context: Context): Boolean =
        inCall(context) || record.waitLeftMs(SystemClock.elapsedRealtime()) > 0

    /**
     * WEL10: Location's switch is never changed while this holds ([PositionMachine]):
     * Quick power off's hold (a call, emergency callback mode, the wait
     * after a call, with the module's words), or Telecom saying a call is in
     * progress, which also sees a call still connecting (the radio being
     * switched on for an emergency call). Without READ_PHONE_STATE Telecom
     * answers false without saying so, so that counts as a hold, as does a
     * Telecom that cannot be asked.
     */
    @SuppressLint("MissingPermission") // Checked just before; a refusal counts as a hold.
    fun locationHold(context: Context): Boolean {
        val now = SystemClock.elapsedRealtime()
        val mode = context.getSystemService(AudioManager::class.java)?.mode ?: AudioManager.MODE_NORMAL
        if (record.hold(CallRecord.isCallMode(mode), inCallbackMode(context), now, words) != null) return true
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return true
        val telecom = context.getSystemService(TelecomManager::class.java) ?: return true
        return try {
            telecom.isInCall
        } catch (e: Exception) {
            true
        }
    }

    /** Why Quick power off must wait now, for the person; null when it may go ahead. */
    fun holdMessage(context: Context): String? {
        val now = SystemClock.elapsedRealtime()
        val mode = context.getSystemService(AudioManager::class.java)?.mode ?: AudioManager.MODE_NORMAL
        return when (record.hold(CallRecord.isCallMode(mode), inCallbackMode(context), now, words)) {
            null -> null
            PowerOffHold.CALL -> context.getString(R.string.power_off_wait_call)
            PowerOffHold.CALLBACK_MODE -> context.getString(R.string.power_off_wait_callback_mode)
            PowerOffHold.AFTER_CALL -> record.minutesLeft(now, words).let {
                context.resources.getQuantityString(R.plurals.power_off_wait_after_call, it, it)
            }
        }
    }
}
