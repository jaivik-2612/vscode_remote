// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import kotlin.math.max
import kotlin.math.min

/** What the module says the calls of the last 5 minutes were (MOD11). */
enum class CallKind(val wire: String) {
    /** One of them was an emergency call, or emergency callback mode is or was on. */
    EMERGENCY("emergency"),

    /** Every one of them was an ordinary call, by Telecom's own record, and nothing else happened. */
    ORDINARY("ordinary"),

    /** The module cannot tell. */
    UNKNOWN("unknown"),

    /** No call, no emergency sign and no doubt in the last 5 minutes. */
    NONE("none"),
    ;

    companion object {
        fun of(wire: String): CallKind? = entries.firstOrNull { it.wire == wire }
    }
}

/** The IMS (VoLTE) registration the module read, for WEL8's status line. */
enum class ImsState(val wire: String) {
    /** Registered over the cell network. */
    CELL("cell"),

    /** Registered over Wi-Fi (Wi-Fi calling). */
    WIFI("wifi"),

    /** Registered, the bearer not known. */
    REGISTERED("registered"),

    /** Not registered. */
    NONE("none"),

    /** The module could not read it, or its reading is too old. */
    UNKNOWN("unknown"),

    /** Not a Phone-mode session: not read. */
    OFF("off"),
    ;

    companion object {
        fun of(wire: String): ImsState? = entries.firstOrNull { it.wire == wire }
    }
}

/**
 * The module's word (MOD11): what the calls of the last 5 minutes were, as
 * root reads them from Telecom, and the IMS registration. Times are whole
 * seconds of the time since boot: the module reads /proc/uptime and
 * Welcome SystemClock.elapsedRealtime(), both CLOCK_BOOTTIME. The module
 * truncates and takes the time before its look, so a word only ever looks
 * older than it is.
 *
 * Only the module, as root, may give it (StateProvider.call; [receive]).
 * Welcome keeps it in memory ([ModuleWords]) and never hands it out, logs
 * it or shows it; no other app can read it or forge it.
 */
data class ModuleWord(
    val calls: CallKind,
    val atS: Long,
    val untilS: Long,
    val ims: ImsState,
    val imsAtS: Long,
) {
    /**
     * True if this word lets Quick power off skip its wait after the call
     * that ended at [lastEnd]: it says "ordinary", its look came after that
     * end (so it covers the call), and it is at most [FRESH_MS] old at
     * [now]. Anything else relaxes nothing.
     */
    fun relaxes(lastEnd: Long, now: Long): Boolean {
        if (calls != CallKind.ORDINARY) return false
        val at = atS * 1000
        return at >= lastEnd && now >= at && now - at <= FRESH_MS
    }

    /**
     * The elapsedRealtime at which the wait this word asks for ends: for an
     * emergency word its end, at most 5 minutes after its look (the whole
     * window from [now] if its look seems to be in the future: the clocks
     * disagree, so wait); 0 for any other word.
     */
    fun emergencyEndMs(now: Long): Long {
        if (calls != CallKind.EMERGENCY) return 0
        val at = atS * 1000
        if (at > now) return now + CallWatch.CALLBACK_WINDOW_MS
        return min(untilS, atS + WINDOW_S) * 1000
    }

    companion object {
        /** The provider's method (StateProvider.call). */
        const val METHOD = "module_word"
        const val VERSION = 1

        /** How long an "ordinary" word counts: the module looks every 10 s while it matters. */
        const val FRESH_MS = 30_000L

        /** How long an IMS reading counts (the module reads it every 5 minutes). */
        const val IMS_FRESH_MS = 15 * 60_000L

        /** The module's window, in seconds: the 5 minutes of Android's default callback mode. */
        const val WINDOW_S = 300L

        /** The extras of a word, every one of them, and nothing else. */
        val KEYS = setOf("v", "calls", "at", "until", "ims", "ims_at")

        private const val ROOT_UID = 0

        /** Only root, the module, may give Welcome its word; not even the shell (uid 2000). */
        fun isAllowedWriter(uid: Int): Boolean = uid == ROOT_UID

        /**
         * The word in [values] (the call's extras), or null unless they are
         * exactly [KEYS] with these types and values: v the Int 1; calls and
         * ims their words; at, until and ims_at Longs of 0 or more; until
         * between at and at + 300 for "emergency", 0 otherwise; ims_at 0 with
         * "off".
         */
        fun parse(values: Map<String, Any?>): ModuleWord? {
            if (values.keys != KEYS) return null
            if (values["v"] != VERSION) return null
            val calls = (values["calls"] as? String)?.let(CallKind::of) ?: return null
            val ims = (values["ims"] as? String)?.let(ImsState::of) ?: return null
            val at = values["at"] as? Long ?: return null
            val until = values["until"] as? Long ?: return null
            val imsAt = values["ims_at"] as? Long ?: return null
            if (at < 0 || until < 0 || imsAt < 0) return null
            if (calls == CallKind.EMERGENCY) {
                if (until < at || until > at + WINDOW_S) return null
            } else if (until != 0L) {
                return null
            }
            if (ims == ImsState.OFF && imsAt != 0L) return null
            return ModuleWord(calls, at, until, ims, imsAt)
        }

        /**
         * The provider's whole call (StateProvider.call passes the binder's
         * uid straight in), apart from Android classes: any caller but root
         * ([uid], which the kernel fills in) is refused before anything is
         * looked at: [values] (the call's extras) are not even read, and
         * the word Welcome holds stays as it was. From root: the word, or
         * null for a malformed one (which clears the word held), goes to
         * [take]. Throws SecurityException or IllegalArgumentException,
         * which the 'content' tool prints instead of "Result: ...", so the
         * module sees it was not taken.
         */
        fun receive(uid: Int, method: String, arg: String?, values: () -> Map<String, Any?>, take: (ModuleWord?) -> Unit) {
            if (!isAllowedWriter(uid)) throw SecurityException("uid $uid may not call $method")
            require(method == METHOD) { "Unknown method: $method" }
            require(arg == null) { "No argument expected" }
            val word = parse(values())
            take(word)
            requireNotNull(word) { "Malformed word" }
        }
    }
}

/**
 * What Welcome keeps of the module's words, in memory only: the last word,
 * and the end of the longest emergency wait any word asked for. A later
 * word replaces the last one but never shortens an emergency wait: an
 * emergency word can only make Quick power off wait longer.
 */
class ModuleWords {
    private var last: ModuleWord? = null
    private var emergencyEnd = 0L

    /** A word from the module, at [now] (elapsedRealtime); null for a malformed one. */
    @Synchronized
    fun take(word: ModuleWord?, now: Long) {
        last = word
        if (word != null) emergencyEnd = max(emergencyEnd, word.emergencyEndMs(now))
    }

    /** True if the last word lets Quick power off skip its wait after the call that ended at [lastEnd]. */
    @Synchronized
    fun relaxes(lastEnd: Long, now: Long): Boolean = last?.relaxes(lastEnd, now) == true

    /** Milliseconds the module's emergency words still ask Quick power off to wait (at most 5 minutes). */
    @Synchronized
    fun emergencyLeftMs(now: Long): Long = (emergencyEnd - now).coerceIn(0L, CallWatch.CALLBACK_WINDOW_MS)

    /** The IMS registration from the last word, UNKNOWN when there is none or it is too old (for WEL8). */
    @Synchronized
    fun ims(now: Long): ImsState {
        val word = last ?: return ImsState.UNKNOWN
        val readAt = if (word.ims == ImsState.OFF) word.atS else word.imsAtS
        val age = now - readAt * 1000
        return if (age in 0..ModuleWord.IMS_FRESH_MS) word.ims else ImsState.UNKNOWN
    }
}
