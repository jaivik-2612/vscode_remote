// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.telephony.ServiceState
import android.telephony.TelephonyManager
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * WEL8 without Android: the cellular radio as Welcome says it, for every
 * mix of the module's word, Welcome's own listener and a call; and the SIM
 * states.
 */
class RadioTest {
    private val now = 3_600_000L // an hour after boot

    private fun word(radio: RadioWord, ageS: Long) = CellWord(CellLevel.PHONE, null, radio, now / 1000 - ageS)

    @Test
    fun everyMix() {
        val words = mapOf(
            "on" to word(RadioWord.ON, 10),
            "off" to word(RadioWord.OFF, 10),
            "wait" to word(RadioWord.WAIT, 10),
            "unknown" to word(RadioWord.UNKNOWN, 10),
            "missing" to null,
            "off, 11 minutes old" to word(RadioWord.OFF, 660),
            "on, 11 minutes old" to word(RadioWord.ON, 660),
            "off, from the future" to word(RadioWord.OFF, -60),
            "off, at 0" to CellWord(CellLevel.PHONE, null, RadioWord.OFF, 0),
        )
        val listeners = mapOf(
            "in service" to ServiceState.STATE_IN_SERVICE,
            "out of service" to ServiceState.STATE_OUT_OF_SERVICE,
            "emergency only" to ServiceState.STATE_EMERGENCY_ONLY,
            "power off" to ServiceState.STATE_POWER_OFF,
            "none" to null,
        )
        for ((wn, w) in words) {
            for ((ln, l) in listeners) {
                for (call in listOf(false, true)) {
                    val want = when {
                        call -> Radio.ON
                        l != null && l != ServiceState.STATE_POWER_OFF -> Radio.ON
                        wn == "on" -> Radio.ON
                        wn == "off" -> Radio.OFF
                        l == ServiceState.STATE_POWER_OFF -> Radio.OFF
                        else -> Radio.UNKNOWN
                    }
                    assertEquals("word $wn, listener $ln, call $call", want, RadioRule.radio(w, l, call, now))
                }
            }
        }
    }

    @Test
    fun offOnlyWhenSomethingSaysSoAndNothingSaysOn() {
        // A fresh "off" from the module, but the listener reads in service (IMS over Wi-Fi counts): on.
        assertEquals(Radio.ON, RadioRule.radio(word(RadioWord.OFF, 5), ServiceState.STATE_IN_SERVICE, false, now))
        // During a call, or the 5 minutes after it: on, whatever the word says.
        assertEquals(Radio.ON, RadioRule.radio(word(RadioWord.OFF, 5), ServiceState.STATE_POWER_OFF, true, now))
        // Nothing known: not known, never off.
        assertEquals(Radio.UNKNOWN, RadioRule.radio(null, null, false, now))
        assertEquals(10 * 60_000L, RadioRule.WORD_FRESH_MS)
        // A word exactly 10 minutes old still counts; one second more does not.
        assertEquals(Radio.OFF, RadioRule.radio(word(RadioWord.OFF, 600), null, false, now))
        assertEquals(Radio.UNKNOWN, RadioRule.radio(word(RadioWord.OFF, 601), null, false, now))
    }

    @Test
    fun simStatesForAllTwelveConstants() {
        val expect = mapOf(
            TelephonyManager.SIM_STATE_UNKNOWN to SimState.UNKNOWN,
            TelephonyManager.SIM_STATE_ABSENT to SimState.ABSENT,
            TelephonyManager.SIM_STATE_PIN_REQUIRED to SimState.PIN,
            TelephonyManager.SIM_STATE_PUK_REQUIRED to SimState.PUK,
            TelephonyManager.SIM_STATE_NETWORK_LOCKED to SimState.NETWORK_LOCKED,
            TelephonyManager.SIM_STATE_READY to SimState.READY,
            TelephonyManager.SIM_STATE_NOT_READY to SimState.NOT_READY,
            TelephonyManager.SIM_STATE_PERM_DISABLED to SimState.PERM_DISABLED,
            TelephonyManager.SIM_STATE_CARD_IO_ERROR to SimState.ERROR,
            TelephonyManager.SIM_STATE_CARD_RESTRICTED to SimState.RESTRICTED,
            // SIM_STATE_LOADED and SIM_STATE_PRESENT, system API constants.
            10 to SimState.READY,
            11 to SimState.NOT_READY,
        )
        assertEquals((0..11).toSet(), expect.keys)
        for ((constant, state) in expect) assertEquals("constant $constant", state, SimState.of(constant))
        assertEquals(SimState.UNKNOWN, SimState.of(99))
        assertEquals(SimState.UNKNOWN, SimState.of(-1))
    }
}
