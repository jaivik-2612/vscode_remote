// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

/** A state line of the emergency card (WEL10), with its word for the CI hook. */
enum class EmergencyState(val word: String) {
    NO_SIM("no_sim"),
    SIM_LOCKED("sim_locked"),
    SIM_UNUSABLE("sim_unusable"),
    RADIO_OFF("radio_off"),
    VOLTE("volte"),
}

/** What the emergency card shows besides the position (WEL10); made by the screens' poll. */
data class EmergencyUi(
    val reading: NumberReading = NumberReading.NotYet,
    val states: List<EmergencyState> = emptyList(),
    /** Why "Show my position" cannot be used now (Position.refusal), or null. */
    val refusal: PositionRefusal? = null,
)

/**
 * The emergency card's texts, apart from Android classes so that every
 * combination can be unit-tested (EmergencyCardTest). They come only from
 * WEL8's readings ([PhoneStatus]: the SIM per slot, the radio rule, the
 * module's IMS word), and keep these rules:
 * - no line says that an emergency call cannot be made: Android switches
 *   the radio on for one and tries any network it finds, with or without
 *   a usable SIM (TelephonyConnectionService, EmergencyCallDomainSelector);
 * - each line says this phone can still try, and the card then points to
 *   the other phone as well, never instead;
 * - no number is named: the number is the one Android lists ([EmergencyNumbers]).
 */
object EmergencyTexts {
    private val LOCKED = setOf(SimState.PIN, SimState.PUK, SimState.NETWORK_LOCKED)
    private val UNUSABLE = setOf(SimState.ERROR, SimState.PERM_DISABLED, SimState.RESTRICTED)

    /**
     * The state lines, in this order: the SIM (at most one line: none
     * without telephony or with any SIM unlocked; locked if any is; else
     * unusable if any is; else no SIM when every slot is empty; nothing for
     * a SIM still starting), the cellular radio when it is known to be off,
     * and VoLTE in a Phone-mode session ([phoneMode]) with a SIM unlocked,
     * the radio not off and the module saying IMS is not registered. Wi-Fi
     * calling and a reading not known give no VoLTE line (WEL8's own line
     * says them; since MOD7 the module switches Wi-Fi calling off, so a
     * reading over Wi-Fi means that did not hold).
     */
    fun states(sims: List<SimState>, radio: Radio, ims: ImsState, phoneMode: Boolean): List<EmergencyState> {
        val out = ArrayList<EmergencyState>()
        when {
            sims.isEmpty() || SimState.READY in sims -> {}
            sims.any { it in LOCKED } -> out += EmergencyState.SIM_LOCKED
            sims.any { it in UNUSABLE } -> out += EmergencyState.SIM_UNUSABLE
            sims.all { it == SimState.ABSENT } -> out += EmergencyState.NO_SIM
        }
        if (radio == Radio.OFF) out += EmergencyState.RADIO_OFF
        if (phoneMode && SimState.READY in sims && radio != Radio.OFF && ims == ImsState.NONE) out += EmergencyState.VOLTE
        return out
    }

    /** The states for [phone] on a screen; [phoneMode] false before Start. */
    fun states(phone: PhoneStatus, phoneMode: Boolean): List<EmergencyState> =
        states(phone.sims, phone.radio, phone.ims, phoneMode)

    fun text(s: EmergencyState): Int = when (s) {
        EmergencyState.NO_SIM -> R.string.emergency_state_no_sim
        EmergencyState.SIM_LOCKED -> R.string.emergency_state_sim_locked
        EmergencyState.SIM_UNUSABLE -> R.string.emergency_state_sim_unusable
        EmergencyState.RADIO_OFF -> R.string.emergency_state_radio_off
        EmergencyState.VOLTE -> R.string.emergency_state_volte
    }

    /** "Your other phone can make emergency calls too": exactly when a state line shows. */
    fun otherPhone(states: List<EmergencyState>): Boolean = states.isNotEmpty()

    /** The line under the number (or instead of it). */
    fun numberText(r: NumberReading): Int = when (r) {
        is NumberReading.Found -> R.string.emergency_number_detail
        is NumberReading.Several -> R.string.emergency_number_several
        NumberReading.NotYet -> R.string.emergency_number_reading
        NumberReading.NoneListed -> R.string.emergency_number_none
        NumberReading.Unreadable -> R.string.emergency_number_unreadable
    }
}

/**
 * The CI hook's lines (debug.antumbra.emergency_states, [TestHook.emergencyStates]):
 * the card's state lines in place of the real ones, and with a number_*
 * word its number line. Nothing else changes: not the Phone card, not
 * Start, not what the module is told.
 */
data class EmergencyHook(val states: List<EmergencyState>, val reading: NumberReading?) {
    companion object {
        const val NUMBER_NONE = "number_none"
        const val NUMBER_UNREADABLE = "number_unreadable"

        /**
         * The property's value: a comma list of the states' words,
         * [NUMBER_NONE], [NUMBER_UNREADABLE] or "none" (no state line).
         * Unknown words are ignored; null (the real readings) when it is
         * unset, empty or has no known word.
         */
        fun parse(raw: String?): EmergencyHook? {
            val words = raw.orEmpty().split(',').map { it.trim() }.filter { it.isNotEmpty() }.toSet()
            val states = EmergencyState.entries.filter { it.word in words }
            val reading = when {
                NUMBER_UNREADABLE in words -> NumberReading.Unreadable
                NUMBER_NONE in words -> NumberReading.NoneListed
                else -> null
            }
            if (states.isEmpty() && reading == null && "none" !in words) return null
            return EmergencyHook(states, reading)
        }

        /**
         * The hook as a build honours it: a test build ([testBuild]: debuggable
         * or testOnly) reads the property with [read]; any other build never
         * calls [read] and always gets null, the real readings.
         */
        fun effective(testBuild: Boolean, read: () -> String?): EmergencyHook? = if (testBuild) parse(read()) else null
    }
}
