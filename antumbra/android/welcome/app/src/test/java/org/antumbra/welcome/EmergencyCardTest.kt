// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * WEL10's emergency card, read from strings.xml: the state lines for every
 * SIM mix, radio, IMS reading and session, the other-phone line exactly
 * with them, no text that says an emergency call cannot be made, the key
 * statements word for word, and the CI hook, which only a test build reads.
 */
class EmergencyCardTest {
    private val t = StringsXml::of
    private val S = EmergencyState.entries

    private val sessions = listOf(
        Internet.WIFI to CellLevel.OFF,
        Internet.WIFI to CellLevel.PHONE,
        Internet.NONE to CellLevel.OFF,
        Internet.NONE to CellLevel.PHONE,
        Internet.MOBILE to CellLevel.DATA,
    )

    /** The rule of EmergencyTexts.states, written out again the plain way. */
    private fun expected(sims: List<SimState>, radio: Radio, ims: ImsState, phoneMode: Boolean): List<EmergencyState> {
        val out = ArrayList<EmergencyState>()
        val ready = SimState.READY in sims
        if (sims.isNotEmpty() && !ready) {
            if (sims.any { it == SimState.PIN || it == SimState.PUK || it == SimState.NETWORK_LOCKED }) out += EmergencyState.SIM_LOCKED
            else if (sims.any { it == SimState.ERROR || it == SimState.PERM_DISABLED || it == SimState.RESTRICTED }) out += EmergencyState.SIM_UNUSABLE
            else if (sims.all { it == SimState.ABSENT }) out += EmergencyState.NO_SIM
        }
        if (radio == Radio.OFF) out += EmergencyState.RADIO_OFF
        if (phoneMode && ready && radio != Radio.OFF && ims == ImsState.NONE) out += EmergencyState.VOLTE
        return out
    }

    private val simMixes: List<List<SimState>> = listOf(emptyList<SimState>()) + SimState.entries.map { listOf(it) } + listOf(
        listOf(SimState.ABSENT, SimState.READY), listOf(SimState.PIN, SimState.ABSENT), listOf(SimState.PUK, SimState.ERROR),
        listOf(SimState.ABSENT, SimState.ABSENT), listOf(SimState.NOT_READY, SimState.ABSENT), listOf(SimState.ERROR, SimState.ABSENT),
        listOf(SimState.READY, SimState.PIN), listOf(SimState.UNKNOWN, SimState.ABSENT),
    )

    @Test
    fun everyMixGivesItsLinesInOrder() {
        for (sims in simMixes) for (radio in Radio.entries) for (ims in ImsState.entries) for (phone in listOf(false, true)) {
            val got = EmergencyTexts.states(sims, radio, ims, phone)
            assertEquals("$sims $radio $ims $phone", expected(sims, radio, ims, phone), got)
            assertEquals(got.isNotEmpty(), EmergencyTexts.otherPhone(got))
            // In the card's order, at most one SIM line.
            assertEquals(got.sortedBy { it.ordinal }, got)
            assertTrue(got.count { it in setOf(EmergencyState.NO_SIM, EmergencyState.SIM_LOCKED, EmergencyState.SIM_UNUSABLE) } <= 1)
        }
        // A few written out.
        assertEquals(listOf(EmergencyState.NO_SIM, EmergencyState.RADIO_OFF), EmergencyTexts.states(listOf(SimState.ABSENT), Radio.OFF, ImsState.OFF, false))
        assertEquals(listOf(EmergencyState.SIM_LOCKED), EmergencyTexts.states(listOf(SimState.PIN, SimState.ABSENT), Radio.UNKNOWN, ImsState.NONE, true))
        assertEquals(listOf(EmergencyState.VOLTE), EmergencyTexts.states(listOf(SimState.READY), Radio.ON, ImsState.NONE, true))
        assertEquals(emptyList<EmergencyState>(), EmergencyTexts.states(listOf(SimState.READY), Radio.ON, ImsState.WIFI, true))
        assertEquals(emptyList<EmergencyState>(), EmergencyTexts.states(listOf(SimState.NOT_READY, SimState.ABSENT), Radio.ON, ImsState.UNKNOWN, true))
        // No telephony at all: no SIM line (there are no slots to be empty).
        assertEquals(listOf(EmergencyState.RADIO_OFF), EmergencyTexts.states(emptyList(), Radio.OFF, ImsState.UNKNOWN, false))
    }

    /**
     * WEL8's five sessions on the status screen (and the Welcome screen
     * before Start): VoLTE only in a Phone-mode session; the radio line
     * whenever the radio reads off, before Start too (D12, MOD6: the radio
     * is off there).
     */
    @Test
    fun theFiveSessionsAndTheWelcomeScreen() {
        for ((internet, cell) in sessions) for (carried in listOf(null, CellLevel.OFF, cell)) {
            val phoneMode = PhoneTexts.phoneMode(cell, carried)
            for (radio in Radio.entries) {
                val got = EmergencyTexts.states(PhoneStatus(radio = radio, sims = listOf(SimState.READY), ims = ImsState.NONE), phoneMode)
                assertEquals("$internet $cell $carried $radio", phoneMode && radio != Radio.OFF, EmergencyState.VOLTE in got)
                assertEquals(radio == Radio.OFF, EmergencyState.RADIO_OFF in got)
            }
        }
        // Before Start: never VoLTE, the radio line while it reads off.
        for (ims in ImsState.entries) {
            val before = EmergencyTexts.states(PhoneStatus(radio = Radio.OFF, sims = listOf(SimState.READY), ims = ims), phoneMode = false)
            assertEquals(listOf(EmergencyState.RADIO_OFF), before)
        }
        // The Welcome screen asks with phoneMode = false, the status screen with the session's.
        val welcome = SourceScan.code("WelcomeActivity.kt")
        assertTrue(welcome.contains("EmergencyWatch.read(this@WelcomeActivity, phone, phoneMode = false)"))
        val status = SourceScan.code("StatusActivity.kt")
        assertTrue(status.contains("val phoneMode = s.started && PhoneTexts.phoneMode(s.cell, p.carried)"))
        assertTrue(status.contains("EmergencyWatch.read(this@StatusActivity, p, phoneMode)"))
    }

    /** The card's own texts: every one, by its resource name. */
    private val cardTexts: Map<String, String> = StringsXml.texts.filterKeys {
        it.startsWith("emergency_state_") || it.startsWith("emergency_number_") || it.startsWith("emergency_numbers_") || it.startsWith("emergency_other_") ||
            it.startsWith("position_") || it == "card_emergency"
    }.mapValues { it.value.joinToString(" ") }

    @Test
    fun noTextSaysAnEmergencyCallCannotBeMade() {
        assertTrue(cardTexts.size > 40)
        val discouraging = Regex(
            "(cannot|can't|can not|unable to|not possible to|impossible to) (make|place|call)|no emergency call|do not call|don't call|" +
                "will not work|won't work|does not work|doesn't work",
            RegexOption.IGNORE_CASE,
        )
        for ((name, text) in cardTexts) assertFalse("$name: $text", discouraging.containsMatchIn(text))
        // Nor any text of the whole app that names emergency calls.
        for ((name, v) in StringsXml.texts) {
            v.filter { it.contains("emergency", ignoreCase = true) }.forEach { assertFalse("$name: $it", discouraging.containsMatchIn(it)) }
        }
        // Each state line says this phone can still try, or that the call goes on without what is missing.
        for (s in S) {
            val line = StringsXml.text(EmergencyTexts.text(s))
            assertTrue(line, line.contains("can still try an emergency call") || line.contains("for an emergency call") || line.contains("An emergency call does not wait"))
        }
    }

    @Test
    fun theKeyStatementsAreSaid() {
        for (name in listOf("emergency_state_no_sim", "emergency_state_sim_locked", "emergency_state_sim_unusable")) {
            assertTrue(name, t(name).contains("can still try an emergency call") && t(name).endsWith("on any network it finds."))
        }
        assertTrue(t("emergency_state_radio_off").contains("Android switches it on for an emergency call"))
        assertTrue(t("emergency_state_volte").contains("An emergency call does not wait for that"))
        assertEquals("Your other phone can make emergency calls too.", t("emergency_other_phone"))
        for (name in listOf("emergency_number_none", "emergency_number_unreadable")) {
            assertTrue(name, t(name).contains("Emergency call still opens the emergency dial pad"))
        }
        assertTrue(t("emergency_number_detail").contains("Android lists"))
        assertTrue(t("emergency_number_detail").contains("press Emergency call and type it"))
        // Show my position: once, satellites only, sent nowhere, up to 3 minutes.
        assertTrue(t("position_detail").contains("never Wi-Fi or cell towers"))
        assertTrue(t("position_detail").contains("it does not save or send it"))
        assertTrue(t("position_detail").contains("up to 3 minutes"))
        assertTrue(t("position_detail_apps").contains("apps you allowed to use your location could get it too"))
        // Assisted GPS on: refused with a plain reason, and Welcome does not change it.
        assertTrue(t("position_refused_assisted").startsWith("Not available: location assistance is on"))
        assertTrue(t("position_refused_assisted").contains("Welcome does not change that setting"))
        assertTrue(t("position_refused_call").startsWith("Not during a call or in the 5 minutes after one"))
    }

    /** WEL8's own words, and the rules every text keeps. */
    @Test
    fun wel8WordsAndNoPlace() {
        assertTrue(t("emergency_state_radio_off").contains("cellular radio"))
        for (name in listOf("emergency_state_no_sim", "emergency_state_sim_locked", "emergency_state_sim_unusable")) {
            assertTrue(name, t(name).contains("SIM card"))
        }
        assertTrue(t("emergency_state_volte").contains("Calls over 4G (VoLTE)"))
        assertTrue(t("ims_none").contains("calls over 4G"))
        for (name in listOf("position_refused_assisted", "position_refused_scanning")) assertTrue(name, t(name).contains("Antumbra add-on switches it off"))
        // WEL8's SIM-PIN help agrees with "can still try".
        assertTrue(t("sim_pin_help").contains("Emergency calls may work without the PIN"))
        for ((name, text) in cardTexts) {
            assertFalse(name, text.contains("offline", ignoreCase = true))
            assertFalse(name, Regex("\\d{2,}").containsMatchIn(text.replace("%1\$s", "").replace("%1\$d", "")))
        }
        // Every state has its own text, and each text exists.
        assertEquals(S.size, S.map { EmergencyTexts.text(it) }.toSet().size)
        for (r in listOf(NumberReading.NotYet, NumberReading.NoneListed, NumberReading.Unreadable, NumberReading.Found("1234"), NumberReading.Several(listOf("1234", "4321")))) {
            assertTrue(StringsXml.text(EmergencyTexts.numberText(r)).isNotBlank())
        }
        assertEquals(R.string.emergency_number_detail, EmergencyTexts.numberText(NumberReading.Found("1234")))
        assertEquals(R.string.emergency_number_several, EmergencyTexts.numberText(NumberReading.Several(listOf("1234", "4321"))))
        assertEquals(R.string.emergency_number_none, EmergencyTexts.numberText(NumberReading.NoneListed))
        assertEquals(R.string.emergency_number_unreadable, EmergencyTexts.numberText(NumberReading.Unreadable))
    }

    @Test
    fun theHookParses() {
        assertNull(EmergencyHook.parse(null))
        assertNull(EmergencyHook.parse(""))
        assertNull(EmergencyHook.parse(" , "))
        assertNull(EmergencyHook.parse("nonsense,radio"))
        assertEquals(EmergencyHook(emptyList(), null), EmergencyHook.parse("none"))
        for (s in S) assertEquals(EmergencyHook(listOf(s), null), EmergencyHook.parse(s.word))
        // All five, in the card's order whatever the property's, once each.
        assertEquals(EmergencyHook(S, null), EmergencyHook.parse("volte,radio_off,sim_unusable,sim_locked,no_sim,volte"))
        assertEquals(EmergencyHook(listOf(EmergencyState.RADIO_OFF), null), EmergencyHook.parse(" radio_off , bogus "))
        assertEquals(EmergencyHook(emptyList(), NumberReading.NoneListed), EmergencyHook.parse(EmergencyHook.NUMBER_NONE))
        assertEquals(EmergencyHook(emptyList(), NumberReading.Unreadable), EmergencyHook.parse(EmergencyHook.NUMBER_UNREADABLE))
        assertEquals(
            EmergencyHook(listOf(EmergencyState.NO_SIM), NumberReading.Unreadable),
            EmergencyHook.parse("number_none,number_unreadable,no_sim"),
        )
        assertEquals(listOf("no_sim", "sim_locked", "sim_unusable", "radio_off", "volte"), S.map { it.word })
    }

    /**
     * A release build ignores the hook: only a test build (debuggable or
     * testOnly) reads the property, and any other build never even calls
     * the reader, so no getprop is started; the card then shows the real
     * readings whatever the property says.
     */
    @Test
    fun aReleaseBuildIgnoresTheHook() {
        for (raw in listOf("no_sim", "sim_locked,radio_off,volte", "number_none", "number_unreadable", "none", "", null)) {
            assertNull(raw.toString(), EmergencyHook.effective(testBuild = false) { fail("a release build read the property"); raw })
            var asked = 0
            assertEquals(EmergencyHook.parse(raw), EmergencyHook.effective(testBuild = true) { asked++; raw })
            assertEquals(1, asked)
        }
        // The Android part asks isTestBuild (FLAG_DEBUGGABLE or FLAG_TEST_ONLY), and reads the property only inside the reader.
        val hook = SourceScan.code("TestHook.kt")
        assertTrue(hook.contains("EmergencyHook.effective(isTestBuild(context)) { SystemProperty.read(EMERGENCY_STATES) }"))
        assertEquals(1, Regex("SystemProperty\\.read\\(EMERGENCY_STATES\\)").findAll(hook).count())
        assertTrue(hook.contains("const val EMERGENCY_STATES = \"debug.antumbra.emergency_states\""))
        assertTrue(hook.contains("(ApplicationInfo.FLAG_DEBUGGABLE or ApplicationInfo.FLAG_TEST_ONLY)"))
        // A release build is neither: debuggable and testOnly only in the debug manifest.
        assertFalse(File("src/main/AndroidManifest.xml").readText().contains("testOnly"))
        assertFalse(File("src/main/AndroidManifest.xml").readText().contains("debuggable"))
        assertTrue(File("src/debug/AndroidManifest.xml").readText().contains("android:testOnly=\"true\""))
        // The property is named nowhere else, and the hook is used only for the card's lines.
        for (f in SourceScan.sources()) {
            val code = SourceScan.withoutComments(f.readText())
            if (f.name != "TestHook.kt") assertFalse(f.name, code.contains("debug.antumbra.emergency_states") || code.contains("EMERGENCY_STATES"))
            if (f.name != "EmergencyNumbers.kt" && f.name != "TestHook.kt") assertFalse(f.name, code.contains("emergencyStates("))
        }
        val watch = SourceScan.function(SourceScan.code("EmergencyNumbers.kt"), "read(context: Context, phone")
        assertTrue(watch.contains("val hook = TestHook.emergencyStates(context)"))
        assertTrue(watch.contains("reading = hook?.reading ?: lastNumber,"))
        assertTrue(watch.contains("states = hook?.states ?: EmergencyTexts.states(phone, phoneMode),"))
        // The real reading is kept apart from the hook's.
        assertTrue(watch.contains("lastNumber = EmergencyNumbers.read(context)"))
        assertEquals(2, Regex("\\bhook\\b").findAll(watch.substringAfter("val hook")).count())
    }
}
