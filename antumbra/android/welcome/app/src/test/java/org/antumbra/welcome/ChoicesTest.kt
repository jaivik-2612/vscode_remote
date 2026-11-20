// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL8 without Android: the two choices at Start (Internet and Phone), the
 * six attempts and the five sessions they give, and what the add-on's
 * gate lets the person choose.
 */
class ChoicesTest {
    /** The add-on's word with this gate (null: no word at all). */
    private fun status(gate: CellLevel?) = PhoneStatus(gate = gate)

    /** The row the provider reports for these choices: tor_mode and cell. */
    private fun row(c: Choices) = c.wireTorMode.wire + " " + c.cell.wire

    /** An attempt as the person makes it: Internet first, then Phone. */
    private fun attempt(i: Internet, phone: Boolean) = Choices().withInternet(i).withPhone(phone)

    @Test
    fun theSixAttemptsGiveTheFiveSessions() {
        assertEquals("direct off", row(attempt(Internet.WIFI, false)))
        assertEquals("direct phone", row(attempt(Internet.WIFI, true)))
        assertEquals("offline off", row(attempt(Internet.NONE, false)))
        assertEquals("offline phone", row(attempt(Internet.NONE, true)))
        assertEquals("direct data", row(attempt(Internet.MOBILE, true)))
        // Mobile data with Phone off is not offered: Off is refused, calls and texts stay.
        assertEquals("direct data", row(attempt(Internet.MOBILE, false)))
        assertNotNull(PhoneChoices.offReason(attempt(Internet.MOBILE, false)))
        assertEquals(R.string.phone_off_mobile, PhoneChoices.offReason(attempt(Internet.MOBILE, true)))
        for (i in listOf(Internet.WIFI, Internet.NONE)) assertNull(PhoneChoices.offReason(attempt(i, true)))
        // The defaults: Wi-Fi, Tor directly, Phone off.
        assertEquals("direct off", row(Choices()))
    }

    @Test
    fun mobileDataBringsCallsAndKeepsThePersonsOwnChoice() {
        val off = Choices().withInternet(Internet.MOBILE)
        assertEquals(CellLevel.DATA, off.cell)
        assertFalse(off.phone)
        // Back to Wi-Fi: Phone is what the person chose, off.
        assertEquals(CellLevel.OFF, off.withInternet(Internet.WIFI).cell)
        val on = Choices().withPhone(true).withInternet(Internet.MOBILE).withInternet(Internet.NONE)
        assertEquals(CellLevel.PHONE, on.cell)
    }

    @Test
    fun torModeOnlyWithInternet() {
        val bridges = Choices(torMode = TorMode.BRIDGES)
        assertEquals(TorMode.BRIDGES, bridges.wireTorMode)
        assertEquals(TorMode.BRIDGES, bridges.withInternet(Internet.MOBILE).wireTorMode)
        assertEquals(TorMode.OFFLINE, bridges.withInternet(Internet.NONE).wireTorMode)
        // "offline" is never a way to connect: only the absence of Internet.
        assertEquals(TorMode.DIRECT, Choices(torMode = TorMode.OFFLINE).wireTorMode)
        assertEquals(CellLevel.entries.map { it.wire }, listOf("off", "phone", "data"))
        assertTrue(CellLevel.OFF < CellLevel.PHONE && CellLevel.PHONE < CellLevel.DATA)
    }

    @Test
    fun whatEachGateOffers() {
        // gate -> (mobile data offered, calls and texts offered)
        val expect = mapOf(
            null to (false to false),
            CellLevel.OFF to (false to false),
            CellLevel.PHONE to (false to true),
            CellLevel.DATA to (true to true),
        )
        for ((gate, offered) in expect) {
            val s = status(gate)
            assertEquals("mobile, gate $gate", offered.first, PhoneChoices.internetReason(Internet.MOBILE, s, true) == null)
            assertEquals("calls, gate $gate", offered.second, PhoneChoices.callsReason(s, true) == null)
            // Wi-Fi and None are always offered.
            assertNull(PhoneChoices.internetReason(Internet.WIFI, s, true))
            assertNull(PhoneChoices.internetReason(Internet.NONE, s, true))
            // Without the add-on running, nothing that needs it.
            assertNotNull(PhoneChoices.internetReason(Internet.MOBILE, s, false))
            assertNotNull(PhoneChoices.callsReason(s, false))
        }
        // The reasons, in plain words: not available yet (the gate), or the add-on has not said.
        assertEquals(R.string.cell_no_word, PhoneChoices.callsReason(status(null), null))
        assertEquals(R.string.phone_calls_unavailable, PhoneChoices.callsReason(status(CellLevel.OFF), true))
        assertEquals(R.string.internet_mobile_unavailable, PhoneChoices.internetReason(Internet.MOBILE, status(CellLevel.PHONE), true))
        assertEquals(R.string.cell_no_word, PhoneChoices.internetReason(Internet.MOBILE, status(CellLevel.DATA), false))
    }

    @Test
    fun startChecksTheGateAgainAndOnlyTakesBack() {
        for (gate in listOf(null, CellLevel.OFF, CellLevel.PHONE, CellLevel.DATA)) {
            val s = status(gate)
            for (i in Internet.entries) {
                for (phone in listOf(false, true)) {
                    val c = attempt(i, phone)
                    val allowed = c.cell <= (gate ?: CellLevel.OFF)
                    assertEquals("$gate $i $phone", allowed, PhoneChoices.allows(c, s, true))
                    assertFalse("$gate $i $phone, add-on gone", c.cell != CellLevel.OFF && PhoneChoices.allows(c, s, false))
                    val fit = PhoneChoices.fit(c, s, true)
                    assertTrue(PhoneChoices.allows(fit, s, true))
                    // Taken back, never turned on.
                    assertTrue(fit.cell <= c.cell)
                    if (allowed) assertEquals(c, fit)
                    if (!c.phone) assertFalse(fit.phone)
                }
            }
        }
        val fit = PhoneChoices.fit(attempt(Internet.MOBILE, true), status(CellLevel.PHONE), true)
        assertEquals(Internet.WIFI, fit.internet)
        assertEquals(CellLevel.PHONE, fit.cell)
    }
}
