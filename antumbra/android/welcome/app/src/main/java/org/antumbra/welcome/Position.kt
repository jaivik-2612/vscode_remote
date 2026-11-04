// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.annotation.SuppressLint
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.location.LocationRequest
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.WindowManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt

/** Why "Show my position" cannot start now. Nothing is changed when it refuses. */
enum class PositionRefusal {
    /** Not the device owner: Welcome cannot switch Location on. */
    NOT_OWNER,

    /** A call, emergency callback mode, or the 5 minutes after a call ([CallWatch.locationHold]). */
    CALL,

    /** assisted_gps_enabled is not 0, or cannot be read: the receiver could ask a SUPL server. */
    ASSISTED,

    /** A network location provider exists: with Location on it would ask a server. */
    NETWORK_PROVIDER,

    /** Wi-Fi scanning for location is on, or cannot be read. */
    WIFI_SCANNING,

    /** No GPS provider. */
    NO_GPS,
}

/** How a search ended without a position, or could not begin. */
enum class PositionEnd {
    TIMEOUT,
    STOPPED,

    /** The screen left (onStop, or the screen went off). */
    LEFT,

    /** A call began: the search stopped, and Location's switch waits for the call's hold to end. */
    CALL,

    /** Start ended it. */
    START,

    /** Location went off from elsewhere. */
    WENT_OFF,
    NO_PERMISSION,
    SWITCH_FAILED,
    REQUEST_FAILED,
}

/** A fix, in memory only: never logged, stored, sent or turned into a string outside [PositionFormat]. */
data class Fix(val latitude: Double, val longitude: Double, val accuracyM: Float?, val mock: Boolean)

sealed interface PositionState {
    data object Idle : PositionState
    data class Refused(val why: PositionRefusal) : PositionState
    data class Looking(val since: Long) : PositionState
    data class Found(val fix: Fix, val at: Long) : PositionState
    data class Ended(val why: PositionEnd) : PositionState
}

/** What the card shows of "Show my position"; a copy of the machine's state at [now]. */
data class PositionUi(
    val state: PositionState = PositionState.Idle,
    /** Welcome wants Location off and looks again: it is still on, or a switch-on that failed may still land. */
    val offPending: Boolean = false,
    /** ... and it stays on because a call holds ([CallWatch.locationHold]). */
    val offWaitsForCall: Boolean = false,
    /** ... and it stays on because Welcome's process started with it on, not knowing the calls before. */
    val offWaitsForStart: Boolean = false,
    /** Location was switched on, or tried to be, for this search, so the card says whether it is off again. */
    val touched: Boolean = false,
    /** Location's switch as Welcome last read it. */
    val lastReadOn: Boolean = false,
    /** Welcome read Location on at some point since this search's switch-on. */
    val wasOn: Boolean = false,
    val now: Long = 0,
    /** WEL9: a session with apps chosen for location: Location on when safe, until shutdown. */
    val keptOn: Boolean = false,
    /** ... and why it is not on yet: a refusal (a call's hold among them). */
    val keepWhy: PositionRefusal? = null,
    /** ... or it waits until every other app the person installed has been refused location ([PositionPlatform.appsReady]). */
    val keepWaitsForApps: Boolean = false,
    /** ... and Welcome looks again (a hold, a switch that failed, a reason that may go). */
    val keepPending: Boolean = false,
)

/** What [PositionMachine] needs from Android ([AndroidPosition]); a fake in PositionTest. */
interface PositionPlatform {
    /** SystemClock.elapsedRealtime(). */
    fun now(): Long
    fun isOwner(): Boolean

    /** [CallWatch.locationHold]. */
    fun callHold(): Boolean

    /** Settings.Global assisted_gps_enabled, read only (Android's default when unset is 1); null when unreadable. */
    fun assistedGps(): Int?
    fun hasNetworkProvider(): Boolean

    /** WifiManager.isScanAlwaysAvailable; null when unreadable. */
    fun wifiScanAlways(): Boolean?
    fun hasGpsProvider(): Boolean

    /** FINE and COARSE location held, granted by the device owner to itself if needed. Never revoked. */
    fun ensurePermission(): Boolean

    /** Location's switch (LocationManager.isLocationEnabled); on when it cannot be read ([AndroidPosition.switchOn]). */
    fun locationOn(): Boolean

    /** DevicePolicyManager.setLocationEnabled; true once Location reads [on]. */
    fun setLocation(on: Boolean): Boolean

    /** One fix from the GPS provider alone; false when it could not be asked. */
    fun startFix(onFix: (Fix) -> Unit, onOff: () -> Unit): Boolean
    fun stopFix()

    /** WEL9: this session's pass refused location to every other app the person installed ([AppPolicies.locationReady]). */
    fun appsReady(): Boolean

    /** WEL9: a new pass over the apps ([AppPolicies.request]): one whose denial failed is tried again. */
    fun requestApps()
}

/**
 * "Show my position" (WEL10), apart from Android so that every path can be
 * unit-tested (PositionTest). One fix from the satellite receiver on
 * request; Location on only meanwhile; the fix kept in memory only, for
 * [SHOW_MS] at most.
 *
 * Location's switch is never changed while a call holds ([PositionPlatform.callHold]):
 * a press is refused then, and a search during which a call begins stops,
 * leaving Location on until the hold ends ([offWhenSafe]). Emergency calls
 * and Android's own emergency location (which does not depend on the
 * switch) are not touched. Every method is synchronized: the screens, the
 * listener, the ticks, Start and the baseline call it from their own threads.
 *
 * [processStart]: this machine is the process's ([Position]). Welcome's call
 * record starts with its process, so a call may have ended a moment before
 * it. If Welcome's first look at Location finds it on (left on by an earlier
 * process, during a call's hold), Location's switch is held as after a
 * call, until [CallWatch.CALLBACK_WINDOW_MS] after the machine was made: no
 * call can have ended after that.
 *
 * [keepOn] (WEL9): a session with apps chosen for location. Location comes
 * on under the same rules as a press: not while a call holds (it comes on
 * when the hold ends), not while assistance, a network location provider
 * or Wi-Fi scanning is on or there is no GPS provider (it stays off, and
 * the status screen says why), and only once every other app the person
 * installed has been refused location ([PositionPlatform.appsReady]; while
 * it waits, a new pass is asked for at most every [APPS_RETRY_MS], so that
 * one denial that failed does not keep Location off for the session); a
 * failed switch is tried again. Apps that came with the phone keep
 * Android's location permissions (WEL6).
 * Then Show my position leaves it on ([Off.KEPT_ON]); only shutdown
 * ([offNow]) switches it off.
 */
class PositionMachine(private val p: PositionPlatform, processStart: Boolean = false) {
    /** Location's switch now: off, left on while a call (or calls not known) hold, still on because switching failed, or kept on for the chosen apps (WEL9). */
    enum class Off { OFF, WAITS_FOR_CALL, FAILED, KEPT_ON }

    var state: PositionState = PositionState.Idle
        private set
    private var offPending = false
    private var offWaitsForCall = false
    private var offWaitsForStart = false
    private var touched = false
    private var lastReadOn = false
    private var wasOn = false
    private var lastOffTry = Long.MIN_VALUE

    /** After a switch-on that failed: Location is looked at until then, in case the switch lands late. */
    private var confirmUntil = Long.MIN_VALUE

    /** Until then Location's switch is held: the process started with it on ([processStart]). */
    private var startHoldUntil = Long.MIN_VALUE
    private val startedAt = p.now()
    private var firstLook = processStart

    /** WEL9: Location kept on for the session's chosen apps ([keepOn]), until [offNow]. */
    private var keep = false
    private var keepWhy: PositionRefusal? = null
    private var keepWaitsForApps = false
    private var keepPending = false
    private var lastKeepTry = Long.MIN_VALUE
    private var lastAppsRequest: Long? = null

    /** Location's switch, read; the process's first look decides the hold at its start. */
    private fun readOn(): Boolean {
        val on = p.locationOn()
        if (firstLook) {
            firstLook = false
            if (on) startHoldUntil = startedAt + CallWatch.CALLBACK_WINDOW_MS
        }
        lastReadOn = on
        if (on) wasOn = true
        return on
    }

    /** Why a press would be refused now; null when it may start. Checked in this order. */
    @Synchronized
    fun refusal(): PositionRefusal? = when {
        !p.isOwner() -> PositionRefusal.NOT_OWNER
        p.callHold() -> PositionRefusal.CALL
        p.assistedGps() != 0 -> PositionRefusal.ASSISTED
        p.hasNetworkProvider() -> PositionRefusal.NETWORK_PROVIDER
        p.wifiScanAlways() != false -> PositionRefusal.WIFI_SCANNING
        !p.hasGpsProvider() -> PositionRefusal.NO_GPS
        else -> null
    }

    /**
     * "Show my position": refused with its reason and nothing changed, or
     * the permission (granted once, never revoked), Location on, and one
     * request to the GPS provider. Ignored while a search runs.
     */
    @Synchronized
    fun press() {
        if (state is PositionState.Looking) return
        refusal()?.let {
            state = PositionState.Refused(it)
            touched = false
            return
        }
        touched = false
        wasOn = false
        if (!p.ensurePermission()) {
            state = PositionState.Ended(PositionEnd.NO_PERMISSION)
            return
        }
        // Granting waits for PermissionController: a call that began
        // meanwhile stops the press here, before anything is switched.
        if (p.callHold()) {
            state = PositionState.Refused(PositionRefusal.CALL)
            return
        }
        if (!readOn()) {
            // From the attempt on, Welcome makes sure Location ends off.
            touched = true
            if (p.setLocation(true)) {
                lastReadOn = true
                wasOn = true
            } else {
                state = PositionState.Ended(PositionEnd.SWITCH_FAILED)
                // Off again if it is on; and looked at until RETRY_MS from
                // now, in case the switch lands after the wait.
                confirmUntil = p.now() + RETRY_MS
                offWhenSafe()
                lastOffTry = p.now()
                return
            }
        }
        touched = true
        // Location is on for this search: an earlier switch-off still to
        // come (one that failed, or a look after a failed switch-on) would
        // end it, so it is dropped; the search's end switches off anyway.
        offPending = false
        offWaitsForCall = false
        offWaitsForStart = false
        confirmUntil = Long.MIN_VALUE
        // The switch takes a moment: a call that began meanwhile stops the
        // press before the request, and Location stays as it is until the
        // call's hold ends.
        if (p.callHold()) {
            state = PositionState.Refused(PositionRefusal.CALL)
            offWhenSafe()
            return
        }
        if (!p.startFix(::onFix, ::onProviderOff)) {
            p.stopFix()
            state = PositionState.Ended(PositionEnd.REQUEST_FAILED)
            offWhenSafe()
            return
        }
        state = PositionState.Looking(p.now())
    }

    /** The receiver's fix: the request removed, Location off when safe, the fix shown. */
    @Synchronized
    fun onFix(fix: Fix) {
        if (state !is PositionState.Looking) return
        p.stopFix()
        state = PositionState.Found(fix, p.now())
        offWhenSafe()
    }

    /** The GPS provider went off; only counts when Location's switch did (not the moment it takes to come on). */
    @Synchronized
    fun onProviderOff() {
        if (state !is PositionState.Looking || readOn()) return
        p.stopFix()
        state = PositionState.Ended(PositionEnd.WENT_OFF)
        offWhenSafe()
    }

    /**
     * Stop, the screen leaving, or Start: a search ends, and Location goes
     * off when safe. Start also clears a position shown: a new session
     * starts without it.
     */
    @Synchronized
    fun end(why: PositionEnd) {
        val s = state
        if (s is PositionState.Looking) {
            p.stopFix()
            state = PositionState.Ended(why)
        } else if (why == PositionEnd.START && s is PositionState.Found) {
            state = PositionState.Idle
        }
        if (touched || offPending) offWhenSafe()
    }

    /** "Hide position". */
    @Synchronized
    fun hide() {
        if (state is PositionState.Found) state = PositionState.Idle
    }

    /** Every second while [busy]: the search's limit, a call beginning, the position's time on screen, a pending switch-off. */
    @Synchronized
    fun tick() {
        val now = p.now()
        when (val s = state) {
            is PositionState.Looking -> when {
                p.callHold() -> {
                    p.stopFix()
                    state = PositionState.Ended(PositionEnd.CALL)
                    offWhenSafe()
                }
                now - s.since >= SEARCH_MS -> {
                    p.stopFix()
                    state = PositionState.Ended(PositionEnd.TIMEOUT)
                    offWhenSafe()
                }
            }
            is PositionState.Found -> if (now - s.at >= SHOW_MS) state = PositionState.Idle
            else -> {}
        }
        // A pending switch-off is looked at again every 5 s: during a call,
        // Welcome asks no more often than that whether the call goes on.
        if (offPending && now - lastOffTry >= RETRY_MS) offWhenSafe()
        if (keep && keepPending && now - lastKeepTry >= RETRY_MS) onWhenSafe()
    }

    @Synchronized
    fun busy(): Boolean = state is PositionState.Looking || state is PositionState.Found || offPending || (keep && keepPending)

    /** WEL9: the session chose apps for location; Location on when safe ([onWhenSafe]), and on until shutdown. */
    @Synchronized
    fun keepOn() {
        keep = true
        onWhenSafe()
    }

    /**
     * Location on for the chosen apps, under Show my position's rules
     * ([refusal]): during a call's hold, while a reason holds, until every
     * other app has lost its location, or after a switch that failed, it
     * stays as it is and is looked at again every [RETRY_MS]. The call's
     * hold is looked at again just before the switch. True once it is on.
     */
    @Synchronized
    fun onWhenSafe(): Boolean {
        if (!keep) return false
        lastKeepTry = p.now()
        refusal()?.let {
            keepWhy = it
            keepWaitsForApps = false
            // Only the device owner can switch it: then there is nothing to retry.
            keepPending = it != PositionRefusal.NOT_OWNER
            return false
        }
        keepWhy = null
        keepWaitsForApps = !p.appsReady()
        if (keepWaitsForApps) {
            keepPending = true
            // A denial that failed is tried again by a new pass, not more often than APPS_RETRY_MS.
            if (AppRules.due(lastAppsRequest, p.now(), APPS_RETRY_MS)) {
                lastAppsRequest = p.now()
                p.requestApps()
            }
            return false
        }
        if (readOn()) {
            keepPending = false
            return true
        }
        if (p.callHold()) {
            keepWhy = PositionRefusal.CALL
            keepPending = true
            return false
        }
        if (p.setLocation(true)) {
            lastReadOn = true
            keepPending = false
            return true
        }
        keepPending = true
        return false
    }

    /**
     * Location off, unless a call holds, or the process started with it on
     * and the calls before are not known ([processStart]): then it stays as
     * it is until the hold ends (the ticks look again). Writes nothing when
     * Location is already off, hold or not. Used by every switch-off in
     * Welcome but shutdown's ([offNow]): the end of a search, the baseline at
     * boot, on becoming the device owner and at Start, and the process's
     * start. In a session that keeps Location on for its chosen apps, once
     * every other app has lost its location, it writes nothing and leaves
     * Location as the session wants it ([Off.KEPT_ON]); before that, a
     * search ends with Location off as before WEL9.
     */
    @Synchronized
    fun offWhenSafe(): Off {
        if (keep && p.appsReady()) {
            offPending = false
            offWaitsForCall = false
            offWaitsForStart = false
            confirmUntil = Long.MIN_VALUE
            return Off.KEPT_ON
        }
        if (!readOn()) {
            // Off. After a switch-on that failed, looked at again until confirmUntil.
            offPending = p.now() < confirmUntil
            offWaitsForCall = false
            offWaitsForStart = false
            return Off.OFF
        }
        lastOffTry = p.now()
        val call = p.callHold()
        if (call || p.now() < startHoldUntil) {
            offPending = true
            offWaitsForCall = call
            offWaitsForStart = !call
            return Off.WAITS_FOR_CALL
        }
        offWaitsForCall = false
        offWaitsForStart = false
        // Only the device owner can switch it; otherwise there is nothing to retry.
        if (!p.isOwner()) {
            offPending = false
            return Off.FAILED
        }
        if (p.setLocation(false)) {
            // setLocation returns true once Location reads off.
            lastReadOn = false
            offPending = false
            return Off.OFF
        }
        offPending = true
        return Off.FAILED
    }

    /** At shutdown: the search ended, the session's Location (WEL9) ended, and Location off at once (the phone is going down, a call with it). */
    @Synchronized
    fun offNow(): Boolean {
        keep = false
        keepPending = false
        keepWhy = null
        keepWaitsForApps = false
        if (state is PositionState.Looking) {
            p.stopFix()
            state = PositionState.Ended(PositionEnd.STOPPED)
        }
        if (!readOn()) return true
        val off = p.setLocation(false)
        if (off) lastReadOn = false
        offPending = !off
        offWaitsForCall = false
        offWaitsForStart = false
        return off
    }

    @Synchronized
    fun snapshot(): PositionUi =
        PositionUi(
            state, offPending, offWaitsForCall, offWaitsForStart, touched, lastReadOn, wasOn, p.now(),
            keptOn = keep, keepWhy = keepWhy, keepWaitsForApps = keepWaitsForApps, keepPending = keepPending,
        )

    companion object {
        /** How long one search may look (Welcome's own limit, and the request's duration). */
        const val SEARCH_MS = 3 * 60_000L

        /** How long a position stays on screen. */
        const val SHOW_MS = 15 * 60_000L

        /** A pending switch-off (a call holding it, or a failed switch) is looked at again after this. */
        const val RETRY_MS = 5_000L

        /** WEL9: while Location waits for the apps, a new pass is asked for at most this often. */
        const val APPS_RETRY_MS = 30_000L
    }
}

/** The texts of "Show my position" (string resources), apart from Compose so that they can be unit-tested. */
object PositionTexts {
    /**
     * Whether Location is off again after a search, or why not yet. "Off"
     * only when Welcome last read it off; "Nothing was changed" only when it
     * never read it on since a switch-on that failed.
     */
    fun offLine(p: PositionUi): Int? = when {
        // WEL9: a session that keeps Location on for its chosen apps.
        p.keptOn && p.touched && p.lastReadOn && !p.offPending -> R.string.position_kept_on
        p.offPending && p.offWaitsForCall -> R.string.position_off_call
        p.offPending && p.offWaitsForStart -> R.string.position_off_start
        p.offPending && p.lastReadOn -> R.string.position_off_retry
        // A switch-on that failed may still land: nothing to say until it is looked at again.
        p.offPending -> null
        !p.touched || p.lastReadOn -> null
        p.state == PositionState.Ended(PositionEnd.SWITCH_FAILED) && !p.wasOn -> R.string.position_unchanged
        p.state is PositionState.Found || p.state is PositionState.Ended || p.state is PositionState.Refused -> R.string.position_off_again
        else -> null
    }

    /** WEL9: the status screen's Location value, for a session with [chosen] apps. */
    fun sessionValue(p: PositionUi, chosen: Int): Int = when {
        chosen == 0 -> R.string.value_off
        p.keptOn && p.lastReadOn -> R.string.location_value_on
        else -> R.string.location_value_not_yet
    }

    /** ... and why Location is not on yet; null when there is nothing to say. */
    fun sessionReason(p: PositionUi, chosen: Int): Int? = when {
        chosen == 0 || (p.keptOn && p.lastReadOn) -> null
        p.keepWhy == PositionRefusal.CALL -> R.string.location_wait_call
        p.keepWhy != null -> refusal(p.keepWhy)
        p.keepWaitsForApps -> R.string.location_wait_apps
        p.keepPending -> R.string.location_wait_retry
        else -> null
    }

    fun refusal(r: PositionRefusal): Int = when (r) {
        PositionRefusal.NOT_OWNER -> R.string.position_refused_owner
        PositionRefusal.CALL -> R.string.position_refused_call
        PositionRefusal.ASSISTED -> R.string.position_refused_assisted
        PositionRefusal.NETWORK_PROVIDER -> R.string.position_refused_network
        PositionRefusal.WIFI_SCANNING -> R.string.position_refused_scanning
        PositionRefusal.NO_GPS -> R.string.position_no_gps
    }

    fun end(e: PositionEnd): Int = when (e) {
        PositionEnd.TIMEOUT -> R.string.position_timeout
        PositionEnd.STOPPED, PositionEnd.LEFT, PositionEnd.START, PositionEnd.CALL -> R.string.position_stopped
        PositionEnd.WENT_OFF -> R.string.position_went_off
        PositionEnd.NO_PERMISSION -> R.string.position_no_permission
        PositionEnd.SWITCH_FAILED -> R.string.position_failed
        PositionEnd.REQUEST_FAILED -> R.string.position_request_failed
    }
}

/**
 * The position as the card shows it, from Android's decimal degrees: 5
 * decimals (about a metre), digits written the same in every language (a
 * decimal comma would confuse a reader), the hemisphere from the rounded
 * value (so -0.000004 is 0.00000° N).
 */
object PositionFormat {
    /** Hundred-thousandths of a degree. */
    fun units(degrees: Double): Long = Math.round(degrees * 100_000.0)

    /** "10.12345" for 1012345 or -1012345. */
    fun digits(units: Long): String {
        val a = abs(units)
        return "${a / 100_000}." + "${a % 100_000}".padStart(5, '0')
    }

    /** The hemisphere's text (a string resource taking [digits]) and the digits. */
    fun latitude(degrees: Double): Pair<Int, String> = units(degrees).let {
        (if (it < 0) R.string.position_south else R.string.position_north) to digits(it)
    }

    fun longitude(degrees: Double): Pair<Int, String> = units(degrees).let {
        (if (it < 0) R.string.position_west else R.string.position_east) to digits(it)
    }

    /** "10.12345, -140.54321": what a map app takes. */
    fun map(latitude: Double, longitude: Double): String =
        listOf(latitude, longitude).joinToString(", ") { d -> units(d).let { (if (it < 0) "-" else "") + digits(it) } }

    /** Whole metres, at least 1; null without an accuracy. */
    fun accuracy(m: Float?): Int? = m?.takeIf { it.isFinite() && it >= 0f }?.let { maxOf(1, it.roundToInt()) }

    /** Whole minutes since the fix. */
    fun ageMinutes(at: Long, now: Long): Int = ((now - at).coerceAtLeast(0) / 60_000).toInt()
}

/**
 * The window rules of both screens, apart from Android so that they can be
 * unit-tested (PositionTest): no screenshot and no recents thumbnail
 * (FLAG_SECURE) while a position is on screen, bridge lines the person
 * typed on the Welcome screen, or the list of installed apps it shows for
 * Location (WEL9); the screen kept on (FLAG_KEEP_SCREEN_ON)
 * while a position is looked for. Each activity sets exactly [MASK]'s
 * flags to [flags] whenever they change.
 */
object WindowRules {
    const val MASK = WindowManager.LayoutParams.FLAG_SECURE or WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON

    fun secure(position: PositionState, choices: Choices? = null): Boolean =
        position is PositionState.Found || (choices != null && (typedBridges(choices) || showsApps(choices)))

    /** WEL9: "On for apps you choose" shows the installed apps on the Welcome screen. */
    fun showsApps(c: Choices): Boolean = c.location

    fun keepOn(position: PositionState): Boolean = position is PositionState.Looking

    /** Bridge lines typed by the person, on the Welcome screen. */
    fun typedBridges(c: Choices): Boolean =
        c.wireTorMode == TorMode.BRIDGES && c.bridgeSource == BridgeSource.CUSTOM && c.bridgeText.isNotBlank()

    /** The window's flags under [MASK]: the status screen passes no [choices]. */
    fun flags(position: PositionState, choices: Choices? = null): Int =
        (if (secure(position, choices)) WindowManager.LayoutParams.FLAG_SECURE else 0) or
            (if (keepOn(position)) WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON else 0)
}

/**
 * The process's "Show my position": one [PositionMachine] over Android
 * ([AndroidPosition]), its steps on one worker thread (never the main
 * thread: granting a permission waits for PermissionController), and
 * [ui], the card's copy of its state, written on the main thread.
 */
object Position {
    var ui by mutableStateOf(PositionUi())
        private set

    private val main = Handler(Looper.getMainLooper())
    private val worker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "antumbra-position").apply { isDaemon = true }
    }

    @Volatile
    private var machine: PositionMachine? = null
    private var ticks: ScheduledFuture<*>? = null

    private fun machine(context: Context): PositionMachine = machine ?: synchronized(this) {
        machine ?: PositionMachine(AndroidPosition(context.applicationContext, worker) { changed() }, processStart = true).also { machine = it }
    }

    /** Why a press would be refused now (the screens' poll, off the main thread). */
    fun refusal(context: Context): PositionRefusal? = machine(context).refusal()

    fun press(context: Context) = later(context) { it.press() }
    fun stop(context: Context) = later(context) { it.end(PositionEnd.STOPPED) }

    /** The screen left: onStop (not for a configuration change), or the screen went off. */
    fun leave(context: Context) = later(context) { it.end(PositionEnd.LEFT) }
    fun hide(context: Context) = later(context) { it.hide() }

    /**
     * Welcome's process starts (WelcomeApp): a Location left on (a search
     * ended during a call, then the process died) goes off when safe, and
     * not before [CallWatch.CALLBACK_WINDOW_MS] from now: the call record
     * starts empty with the process ([PositionMachine]'s processStart).
     */
    fun atProcessStart(context: Context) = later(context) { it.offWhenSafe() }

    /** Start's first step, before its baseline; off the main thread. */
    fun endForStart(context: Context) {
        machine(context).end(PositionEnd.START)
        changed()
    }

    /** The baseline's Location off ([PositionMachine.offWhenSafe]); off the main thread. */
    fun offWhenSafe(context: Context): PositionMachine.Off = machine(context).offWhenSafe().also { changed() }

    /** At shutdown ([PositionMachine.offNow]). */
    fun offNow(context: Context): Boolean = machine(context).offNow()

    /** WEL9: after Start, for a session with apps chosen for location ([PositionMachine.keepOn]). */
    fun keepOn(context: Context) = later(context) { it.keepOn() }

    private fun later(context: Context, step: (PositionMachine) -> Unit) {
        val m = machine(context)
        worker.execute {
            step(m)
            changed()
        }
    }

    /** After every step: the card's copy, and the ticks while the machine is busy. */
    private fun changed() {
        val m = machine ?: return
        val copy = m.snapshot()
        main.post { ui = copy }
        synchronized(this) {
            if (m.busy() && ticks == null) {
                ticks = worker.scheduleWithFixedDelay({
                    m.tick()
                    val now = m.snapshot()
                    main.post { ui = now }
                    if (!m.busy()) synchronized(this) {
                        ticks?.cancel(false)
                        ticks = null
                    }
                }, 1, 1, TimeUnit.SECONDS)
            }
        }
    }
}

/**
 * [PositionPlatform] on Android. Location's switch through the device
 * owner's DevicePolicyManager.setLocationEnabled (the only setting it
 * writes: never assisted_gps_enabled, a SUPL, XTRA or GNSS setting, or a
 * provider's own); the fix from LocationManager.GPS_PROVIDER alone, never
 * the fused, network or passive provider and never a remembered fix. The
 * location permissions are granted by the device owner to itself at the
 * first press and never revoked: revoking a runtime permission kills the
 * app's process, and with it the session kept in memory.
 */
class AndroidPosition(
    private val context: Context,
    private val executor: Executor,
    private val afterEvent: () -> Unit,
) : PositionPlatform {
    private val dpm = context.getSystemService(DevicePolicyManager::class.java)
    private val lm = context.getSystemService(LocationManager::class.java)
    private val wifi = context.getSystemService(WifiManager::class.java)
    private val admin = AdminReceiver.component(context)

    @Volatile
    private var listener: LocationListener? = null

    override fun now(): Long = SystemClock.elapsedRealtime()

    override fun isOwner(): Boolean = dpm.isDeviceOwnerApp(context.packageName)

    override fun callHold(): Boolean = CallWatch.locationHold(context)

    // Read only: @Readable in Settings.Global; the module sets it to 0 at every boot.
    override fun assistedGps(): Int? = try {
        Settings.Global.getInt(context.contentResolver, ASSISTED_GPS_ENABLED, 1)
    } catch (e: Exception) {
        null
    }

    override fun hasNetworkProvider(): Boolean = lm.hasProvider(LocationManager.NETWORK_PROVIDER)

    override fun wifiScanAlways(): Boolean? = try {
        @Suppress("DEPRECATION") // Deprecated, but still what Wi-Fi scanning for location reads.
        wifi.isScanAlwaysAvailable
    } catch (e: Exception) {
        null
    }

    override fun hasGpsProvider(): Boolean = lm.hasProvider(LocationManager.GPS_PROVIDER)

    private fun granted(): Boolean = PERMISSIONS.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

    override fun ensurePermission(): Boolean {
        if (granted()) return true
        if (!isOwner()) return false
        for (permission in PERMISSIONS) {
            try {
                dpm.setPermissionGrantState(admin, context.packageName, permission, DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED)
            } catch (e: Exception) {
                Log.w(TAG, "a location permission could not be granted", e)
            }
        }
        return granted()
    }

    override fun locationOn(): Boolean = switchOn { lm.isLocationEnabled }

    override fun setLocation(on: Boolean): Boolean {
        try {
            dpm.setLocationEnabled(admin, on)
        } catch (e: Exception) {
            Log.w(TAG, if (on) "Location could not be switched on" else "Location could not be switched off", e)
            return false
        }
        val end = now() + SWITCH_WAIT_MS
        while (locationOn() != on) {
            if (now() >= end) return false
            SystemClock.sleep(100)
        }
        return true
    }

    private fun gpsOn(): Boolean = try {
        lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
    } catch (e: Exception) {
        false
    }

    // The permission is granted by ensurePermission and checked just before.
    @SuppressLint("MissingPermission")
    override fun startFix(onFix: (Fix) -> Unit, onOff: () -> Unit): Boolean {
        if (!granted()) return false
        // Location's switch reaches the provider a moment later, and a
        // request made while the provider is off is told "off" at once.
        val end = now() + SWITCH_WAIT_MS
        while (!gpsOn()) {
            if (now() >= end) return false
            SystemClock.sleep(100)
        }
        val l = object : LocationListener {
            override fun onLocationChanged(location: Location) {
                if (listener !== this) return
                onFix(Fix(location.latitude, location.longitude, if (location.hasAccuracy()) location.accuracy else null, location.isMock))
                afterEvent()
            }

            override fun onProviderDisabled(provider: String) {
                if (listener !== this) return
                onOff()
                afterEvent()
            }

            override fun onProviderEnabled(provider: String) {}
        }
        listener = l
        val request = LocationRequest.Builder(1000L)
            .setQuality(LocationRequest.QUALITY_HIGH_ACCURACY)
            .setMaxUpdates(1)
            .setDurationMillis(PositionMachine.SEARCH_MS)
            .build()
        return try {
            lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, request, executor, l)
            true
        } catch (e: Exception) {
            Log.w(TAG, "the satellite receiver could not be asked", e)
            listener = null
            false
        }
    }

    override fun stopFix() {
        val l = listener ?: return
        listener = null
        try {
            lm.removeUpdates(l)
        } catch (e: Exception) {
            Log.w(TAG, "the request could not be removed", e)
        }
    }

    override fun appsReady(): Boolean = AppPolicies.locationReady

    override fun requestApps() = AppPolicies.request(context, "location waits")

    companion object {
        private const val TAG = "AntumbraPosition"

        /**
         * Location's switch as [read] gives it; on when it cannot be read,
         * so that Welcome tries to switch it off, and never says it is off.
         */
        fun switchOn(read: () -> Boolean): Boolean = try {
            read()
        } catch (e: Exception) {
            true
        }

        /** Settings.Global.ASSISTED_GPS_ENABLED (hidden in the SDK, @Readable). */
        const val ASSISTED_GPS_ENABLED = "assisted_gps_enabled"

        /** How long Location's switch and the GPS provider may take to follow. */
        private const val SWITCH_WAIT_MS = 5_000L

        /** Both, as lint requires for FINE; Welcome asks for FINE (GPS). Never ACCESS_BACKGROUND_LOCATION. */
        val PERMISSIONS = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
    }
}
