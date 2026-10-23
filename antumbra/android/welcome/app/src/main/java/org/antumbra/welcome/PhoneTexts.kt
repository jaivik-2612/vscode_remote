// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

/**
 * Which Internet and Phone choices can be made now (WEL8), apart from
 * Android classes so that every combination can be unit-tested.
 *
 * The module carries out no more than this phone's Phone-mode gate allows,
 * and tells Welcome the gate ([CellWord]). Welcome offers no more than
 * that: without a word from the module (no add-on, an older one) or while
 * the add-on is not running, only Wi-Fi or None, with Phone off.
 */
object PhoneChoices {
    /** The most the add-on allows now. */
    fun allowed(status: PhoneStatus, addOnPresent: Boolean?): CellLevel =
        if (addOnPresent == false) CellLevel.OFF else status.gate ?: CellLevel.OFF

    /** Why Internet [i] cannot be chosen now (a string resource), or null when it can. */
    fun internetReason(i: Internet, status: PhoneStatus, addOnPresent: Boolean?): Int? = when {
        i != Internet.MOBILE -> null
        allowed(status, addOnPresent) >= CellLevel.DATA -> null
        status.gate == null || addOnPresent == false -> R.string.cell_no_word
        else -> R.string.internet_mobile_unavailable
    }

    /** Why Phone: calls and texts cannot be chosen now, or null when it can. */
    fun callsReason(status: PhoneStatus, addOnPresent: Boolean?): Int? = when {
        allowed(status, addOnPresent) >= CellLevel.PHONE -> null
        status.gate == null || addOnPresent == false -> R.string.cell_no_word
        else -> R.string.phone_calls_unavailable
    }

    /** Why Phone: off cannot be chosen with these choices (mobile data needs the radio), or null. */
    fun offReason(c: Choices): Int? = if (c.internet == Internet.MOBILE) R.string.phone_off_mobile else null

    /** True if the add-on allows these choices now (checked again at Start). */
    fun allows(c: Choices, status: PhoneStatus, addOnPresent: Boolean?): Boolean =
        c.cell <= allowed(status, addOnPresent)

    /**
     * The choices with whatever the add-on no longer allows taken back:
     * mobile data back to Wi-Fi, calls and texts back to off. Nothing is
     * ever turned on here.
     */
    fun fit(c: Choices, status: PhoneStatus, addOnPresent: Boolean?): Choices {
        val allowed = allowed(status, addOnPresent)
        var f = c
        if (f.internet == Internet.MOBILE && allowed < CellLevel.DATA) f = f.copy(internet = Internet.WIFI)
        if (f.phone && allowed < CellLevel.PHONE) f = f.copy(phone = false)
        return f
    }
}

/**
 * The texts of the Phone parts and of what depends on the cell radio
 * (WEL8), as string or plurals resources, apart from Compose so that every
 * combination can be unit-tested (PhoneTextTest). The rules they keep: the
 * word "offline" is said only when the session has no Internet, no Phone
 * and the cellular radio is known to be off ([status]); everything else
 * treats a radio that is not known as possibly on. What the add-on carries
 * out counts over what was chosen: Phone or mobile data it did not allow
 * is not said to be on.
 */
object PhoneTexts {
    fun sim(s: SimState): Int = when (s) {
        SimState.ABSENT -> R.string.sim_absent
        SimState.PIN -> R.string.sim_pin
        SimState.PUK -> R.string.sim_puk
        SimState.NETWORK_LOCKED -> R.string.sim_network_locked
        SimState.READY -> R.string.sim_ready
        SimState.NOT_READY -> R.string.sim_not_ready
        SimState.PERM_DISABLED -> R.string.sim_perm_disabled
        SimState.ERROR -> R.string.sim_error
        SimState.RESTRICTED -> R.string.sim_restricted
        SimState.UNKNOWN -> R.string.sim_unknown
    }

    fun radio(r: Radio): Int = when (r) {
        Radio.ON -> R.string.radio_on
        Radio.OFF -> R.string.radio_off
        Radio.UNKNOWN -> R.string.radio_unknown
    }

    /** The SIM-PIN help to show: the PUK's while a SIM needs it, the PIN's while a SIM is in the phone, else none. */
    fun simHelp(sims: List<SimState>): Int? = when {
        SimState.PUK in sims -> R.string.sim_puk_help
        sims.any { it != SimState.ABSENT && it != SimState.UNKNOWN } -> R.string.sim_pin_help
        else -> null
    }

    /**
     * A SIM is unlocked while the add-on is known not to run (its firewall
     * has not reported in): nothing but Android's stored setting keeps its
     * mobile data off then, and a SIM Android has never seen starts with it
     * on. Welcome says so, and to restart the phone.
     */
    fun simUnlockedWithoutAddOn(sims: List<SimState>, addOnPresent: Boolean?): Boolean =
        addOnPresent == false && SimState.READY in sims

    /**
     * The VoLTE line: the module's IMS reading in a Phone-mode session; "Not
     * known yet" there while the module has not read it (its word says off
     * until the first reading after the switch-on). Outside Phone mode the
     * module does not read IMS, so the line says it is not checked, not that
     * it is off (Wi-Fi calling stays possible until MOD7).
     */
    fun ims(ims: ImsState, phoneMode: Boolean): Int = if (!phoneMode) R.string.ims_off else when (ims) {
        ImsState.CELL -> R.string.ims_cell
        ImsState.WIFI -> R.string.ims_wifi
        ImsState.REGISTERED -> R.string.ims_registered
        ImsState.NONE -> R.string.ims_none
        ImsState.UNKNOWN, ImsState.OFF -> R.string.ims_unknown
    }

    /** What the carrier sees while the cellular radio is on: four lines and the calls note. */
    val SEES = listOf(
        R.string.carrier_sees_sim,
        R.string.carrier_sees_imei,
        R.string.carrier_sees_cells,
        R.string.carrier_sees_calls,
        R.string.carrier_no_tor_calls,
    )

    /** The line on mobile data and Wi-Fi hotspots, by the session's Internet. */
    private fun dataLines(internet: Internet, torMode: TorMode): List<Int> = when (internet) {
        Internet.MOBILE -> listOf(if (torMode == TorMode.BRIDGES) R.string.carrier_data_bridges else R.string.carrier_data_tor)
        Internet.WIFI -> listOf(R.string.carrier_data_off, R.string.carrier_hotspot)
        Internet.NONE -> listOf(R.string.carrier_data_off)
    }

    /** The Welcome screen's "What your carrier sees" card, for the choices made. */
    fun carrierChoice(c: Choices): List<Int> = if (c.cell == CellLevel.OFF) {
        listOf(R.string.carrier_choice_off) + if (c.internet == Internet.WIFI) listOf(R.string.carrier_hotspot) else emptyList()
    } else {
        listOf(R.string.carrier_choice_on) + SEES + dataLines(c.internet, c.wireTorMode)
    }

    /**
     * A mobile-data session whose mobile data the add-on does not carry out
     * ([carried] below DATA: the gate was lowered, or Start raced a change):
     * mobile data is off, and Wi-Fi is locked off in such a session, so it
     * has no Internet. Null [carried] (not known yet) counts as carried out.
     */
    fun mobileRefused(internet: Internet, carried: CellLevel?): Boolean =
        internet == Internet.MOBILE && carried != null && carried < CellLevel.DATA

    /** The status screen's "What your carrier sees" card, for the radio now and what the add-on carries out. */
    fun carrierNow(radio: Radio, internet: Internet, torMode: TorMode, carried: CellLevel?): List<Int> {
        val data = if (mobileRefused(internet, carried)) listOf(R.string.carrier_data_off) else dataLines(internet, torMode)
        return when (radio) {
            Radio.OFF -> listOf(R.string.carrier_now_off) + if (internet == Internet.WIFI) listOf(R.string.carrier_hotspot) else emptyList()
            Radio.ON -> listOf(R.string.carrier_now_on) + SEES + data
            Radio.UNKNOWN -> listOf(R.string.carrier_now_unknown) + SEES + data
        }
    }

    /**
     * The status screen's first line: a string resource, or a plurals
     * resource (taking the number of bridges) for bridges ([statusIsPlural]).
     * "Offline" only without Internet, with Phone off ([chosen], or what the
     * add-on carries out, [carried]) and the radio known to be off: in a
     * Phone session the radio comes back on without a restart.
     */
    fun status(internet: Internet, torMode: TorMode, radio: Radio, chosen: CellLevel, carried: CellLevel?): Int = when {
        internet == Internet.NONE -> when (radio) {
            Radio.OFF -> if (phoneMode(chosen, carried)) R.string.status_mode_none_radio_off_phone else R.string.status_mode_none_radio_off
            Radio.ON -> R.string.status_mode_none_radio_on
            Radio.UNKNOWN -> R.string.status_mode_none_radio_unknown
        }
        mobileRefused(internet, carried) -> R.string.status_mode_mobile_refused
        torMode == TorMode.BRIDGES ->
            if (internet == Internet.MOBILE) R.plurals.status_mode_bridges_mobile else R.plurals.status_mode_bridges_wifi
        else -> if (internet == Internet.MOBILE) R.string.status_mode_direct_mobile else R.string.status_mode_direct_wifi
    }

    fun statusIsPlural(internet: Internet, torMode: TorMode, carried: CellLevel?): Boolean =
        internet != Internet.NONE && !mobileRefused(internet, carried) && torMode == TorMode.BRIDGES

    /** The session card's Internet line; [carried] what the module carries out (null: not known yet). */
    fun internetValue(internet: Internet, carried: CellLevel?): Int = when {
        internet == Internet.WIFI -> R.string.value_wifi
        internet == Internet.NONE -> R.string.value_none
        mobileRefused(internet, carried) -> R.string.value_cell_refused
        else -> R.string.value_mobile
    }

    fun torValue(internet: Internet, torMode: TorMode): Int = when {
        internet == Internet.NONE -> R.string.value_tor_unused
        torMode == TorMode.BRIDGES -> R.string.value_bridges
        else -> R.string.value_direct
    }

    /** The session card's Phone line: the choice, or that the add-on did not allow it. */
    fun phoneValue(chosen: CellLevel, carried: CellLevel?): Int = when {
        chosen == CellLevel.OFF -> R.string.value_off
        carried != null && carried == CellLevel.OFF -> R.string.value_cell_refused
        else -> R.string.value_calls
    }

    /** Phone mode is carried out (or chosen, while the module has not said yet): the VoLTE line is read. */
    fun phoneMode(chosen: CellLevel, carried: CellLevel?): Boolean = (carried ?: chosen) >= CellLevel.PHONE
}
