// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.content.Context
import android.os.SystemClock
import android.telephony.ServiceState
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import android.util.Log

/** The cell radio as the module last read it (the registry's mRadioPowerState). */
enum class RadioWord(val wire: String) {
    ON("on"),
    OFF("off"),

    /** Unavailable: the modem is starting or stopping. */
    WAIT("wait"),
    UNKNOWN("unknown"),
    ;

    companion object {
        fun of(wire: String): RadioWord? = entries.firstOrNull { it.wire == wire }
    }
}

/** The cell radio, as Welcome tells the person ([RadioRule]). */
enum class Radio { ON, OFF, UNKNOWN }

/**
 * The module's word on the cell radio (WEL8, method "module_cell"): this
 * phone's Phone-mode [gate] (the most the module will carry out), what it
 * carries out ([cell], null before it read a Start) and the [radio] as its
 * last look read it, at [atS] seconds since boot (the module's
 * /proc/uptime, Welcome's elapsedRealtime: both CLOCK_BOOTTIME; 0 before
 * its first look). It repeats it every 5 minutes, so a word older than
 * [RadioRule.WORD_FRESH_MS] means the module stopped telling.
 *
 * Only root may give it (StateProvider.call; [ModuleCalls]). Welcome keeps
 * it in memory ([CellWatch]) and never hands it out or logs it. It can
 * only make Welcome offer less than the module allows: the module refuses
 * anything above its gate whatever Welcome's row says.
 */
data class CellWord(
    val gate: CellLevel,
    val cell: CellLevel?,
    val radio: RadioWord,
    val atS: Long,
) {
    companion object {
        /** The provider's method (StateProvider.call). */
        const val METHOD = "module_cell"
        const val VERSION = 1

        /** The extras of a word, every one of them, and nothing else. */
        val KEYS = setOf("v", "gate", "cell", "radio", "at")

        /**
         * The word in [values] (the call's extras), or null unless they are
         * exactly [KEYS] with these types and values: v the Int 1; gate off,
         * phone or data; cell none, off, phone or data; radio on, off, wait
         * or unknown; at a Long of 0 or more.
         */
        fun parse(values: Map<String, Any?>): CellWord? {
            if (values.keys != KEYS) return null
            if (values["v"] != VERSION) return null
            val gate = (values["gate"] as? String)?.let(CellLevel::of) ?: return null
            val cellWire = values["cell"] as? String ?: return null
            val cell = if (cellWire == "none") null else CellLevel.of(cellWire) ?: return null
            val radio = (values["radio"] as? String)?.let(RadioWord::of) ?: return null
            val at = values["at"] as? Long ?: return null
            if (at < 0) return null
            return CellWord(gate, cell, radio, at)
        }

        /**
         * The provider's whole call for this method, apart from Android
         * classes, like [ModuleWord.receive]: any caller but root is
         * refused before anything is looked at; from root the word, or null
         * for a malformed one (which clears the word held: Welcome then
         * offers no Phone mode and says the radio is not known), goes to
         * [take].
         */
        fun receive(uid: Int, method: String, arg: String?, values: () -> Map<String, Any?>, take: (CellWord?) -> Unit) {
            if (!ModuleWord.isAllowedWriter(uid)) throw SecurityException("uid $uid may not call $method")
            require(method == METHOD) { "Unknown method: $method" }
            require(arg == null) { "No argument expected" }
            val word = parse(values())
            take(word)
            requireNotNull(word) { "Malformed word" }
        }
    }
}

/**
 * The provider's call: the uid first (root only, before the method or the
 * extras are looked at), then the method: "module_word" (MOD11) or
 * "module_cell" (WEL8). Any other method is refused and changes neither
 * word.
 */
object ModuleCalls {
    fun receive(
        uid: Int,
        method: String,
        arg: String?,
        values: () -> Map<String, Any?>,
        word: (ModuleWord?) -> Unit,
        cell: (CellWord?) -> Unit,
    ) {
        if (!ModuleWord.isAllowedWriter(uid)) throw SecurityException("uid $uid may not call $method")
        when (method) {
            ModuleWord.METHOD -> ModuleWord.receive(uid, method, arg, values, word)
            CellWord.METHOD -> CellWord.receive(uid, method, arg, values, cell)
            else -> throw IllegalArgumentException("Unknown method: $method")
        }
    }
}

/**
 * The cell radio as Welcome says it. Welcome may not ask for the radio's
 * power itself (radio power events and isRadioOn are for privileged apps),
 * so it combines what it may see:
 * - ON while a call is in progress or Quick power off's wait after a call
 *   lasts (the radio stays on then), while its own service-state listener
 *   reads anything but POWER_OFF (that state counts IMS over Wi-Fi as in
 *   service: the carrier can reach the phone then), or while the module's
 *   fresh word says on;
 * - OFF when the module's fresh word says off, or the listener reads
 *   POWER_OFF, and nothing says on;
 * - UNKNOWN otherwise (no word, an old one, the radio starting or
 *   stopping). The texts treat UNKNOWN as possibly on: "offline" is said
 *   only for OFF.
 */
object RadioRule {
    /** A word counts for 10 minutes; the module repeats it every 5. */
    const val WORD_FRESH_MS = 10 * 60_000L

    /**
     * [word] the module's last word (null: none); [listener] the last
     * ServiceState.getState() of Welcome's own listener (null: none);
     * [call] a call is in progress or Quick power off still waits after
     * one; [now] elapsedRealtime.
     */
    fun radio(word: CellWord?, listener: Int?, call: Boolean, now: Long): Radio {
        val fresh = word?.takeIf { it.atS > 0 && now - it.atS * 1000 in 0..WORD_FRESH_MS }
        return when {
            call -> Radio.ON
            listener != null && listener != ServiceState.STATE_POWER_OFF -> Radio.ON
            fresh?.radio == RadioWord.ON -> Radio.ON
            fresh?.radio == RadioWord.OFF -> Radio.OFF
            listener == ServiceState.STATE_POWER_OFF -> Radio.OFF
            else -> Radio.UNKNOWN
        }
    }
}

/** A SIM slot's state, as the person reads it. */
enum class SimState {
    ABSENT,
    PIN,
    PUK,
    NETWORK_LOCKED,
    READY,
    NOT_READY,
    PERM_DISABLED,
    ERROR,
    RESTRICTED,
    UNKNOWN,
    ;

    companion object {
        /** SIM_STATE_LOADED and SIM_STATE_PRESENT are system API constants (10 and 11). */
        private const val SIM_STATE_LOADED = 10
        private const val SIM_STATE_PRESENT = 11

        /** TelephonyManager.getSimState(slot)'s answer. */
        fun of(state: Int): SimState = when (state) {
            TelephonyManager.SIM_STATE_ABSENT -> ABSENT
            TelephonyManager.SIM_STATE_PIN_REQUIRED -> PIN
            TelephonyManager.SIM_STATE_PUK_REQUIRED -> PUK
            TelephonyManager.SIM_STATE_NETWORK_LOCKED -> NETWORK_LOCKED
            TelephonyManager.SIM_STATE_READY, SIM_STATE_LOADED -> READY
            TelephonyManager.SIM_STATE_NOT_READY, SIM_STATE_PRESENT -> NOT_READY
            TelephonyManager.SIM_STATE_PERM_DISABLED -> PERM_DISABLED
            TelephonyManager.SIM_STATE_CARD_IO_ERROR -> ERROR
            TelephonyManager.SIM_STATE_CARD_RESTRICTED -> RESTRICTED
            else -> UNKNOWN
        }
    }
}

/** What the Phone parts of both screens show; made by [CellWatch.status]. */
data class PhoneStatus(
    /** The most the module allows now; null without a word from it (Phone mode not offered). */
    val gate: CellLevel? = null,
    /** What the module carries out (null before it read a Start, or without a word). */
    val carried: CellLevel? = null,
    val radio: Radio = Radio.UNKNOWN,
    /** One per SIM slot; empty when the phone reports none (no telephony). */
    val sims: List<SimState> = emptyList(),
    /** The IMS (VoLTE) registration from the module's word on the calls (MOD11). */
    val ims: ImsState = ImsState.UNKNOWN,
)

/**
 * What Welcome knows about the cell radio and the SIM, in memory only, for
 * the life of the process (started by [WelcomeApp]):
 * - the module's last word on the cell radio ([CellWord]);
 * - its own service-state listener (TelephonyCallback, registered with
 *   INCLUDE_LOCATION_DATA_NONE: no cell identity, operator name or
 *   location ever reaches it; no permission needed);
 * - each SIM slot's state (getSimState(slot); no permission needed).
 * Nothing that identifies the SIM, the phone or its number is asked for:
 * no IMEI, IMSI, ICCID or phone number (NoIdentifiersTest checks the
 * source). Nothing of it is written to a file, the log or a property, or
 * handed to another app.
 */
object CellWatch {
    private const val TAG = "AntumbraCellWatch"

    @Volatile
    private var word: CellWord? = null

    @Volatile
    private var listenerState: Int? = null

    private var registered: TelephonyManager? = null
    private var lastSims: List<SimState>? = null

    private val callback = object : TelephonyCallback(), TelephonyCallback.ServiceStateListener {
        override fun onServiceStateChanged(serviceState: ServiceState) {
            listenerState = serviceState.state
        }
    }

    /** The module's word (StateProvider.call, from root only); null for a malformed one, which clears it. */
    fun take(cellWord: CellWord?) {
        word = cellWord
    }

    /** The module's last word, for Start's check (null: none). */
    fun word(): CellWord? = word

    /** Starts the listener (WelcomeApp); again when a SIM's state changes ([status]). */
    @Synchronized
    fun start(context: Context) {
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return
        try {
            registered?.unregisterTelephonyCallback(callback)
            listenerState = null
            tm.registerTelephonyCallback(TelephonyManager.INCLUDE_LOCATION_DATA_NONE, context.mainExecutor, callback)
            registered = tm
        } catch (e: RuntimeException) {
            // No telephony feature (UnsupportedOperationException), or a
            // platform that refuses it: the module's word still counts.
            Log.w(TAG, "no service-state listener", e)
            registered = null
        }
    }

    /** Each SIM slot's state; empty without telephony. */
    private fun sims(context: Context): List<SimState> {
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return emptyList()
        return try {
            (0 until tm.activeModemCount).map { SimState.of(tm.getSimState(it)) }
        } catch (e: RuntimeException) {
            Log.w(TAG, "no SIM state", e)
            emptyList()
        }
    }

    /**
     * What the Phone parts show now. Polled by the screens while they are
     * visible; a SIM's change registers the listener again (it follows the
     * default subscription at the time it was registered).
     */
    fun status(context: Context): PhoneStatus {
        val sims = sims(context)
        synchronized(this) {
            if (lastSims != null && lastSims != sims) start(context.applicationContext)
            lastSims = sims
        }
        val now = SystemClock.elapsedRealtime()
        val w = word
        return PhoneStatus(
            gate = w?.gate,
            carried = w?.cell,
            radio = RadioRule.radio(w, listenerState, CallWatch.callOrAfter(context), now),
            sims = sims,
            ims = CallWatch.ims(),
        )
    }
}
