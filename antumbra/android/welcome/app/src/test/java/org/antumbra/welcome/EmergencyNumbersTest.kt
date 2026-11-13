// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.telephony.emergency.EmergencyNumber
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL10: the general emergency number, read from Android's list at run
 * time, never written in Welcome. Stand-in numbers (1234, 4321, 5678: none
 * is an emergency number in Android's database or 3GPP's defaults), except
 * where Android's own fallback list is written out as Android makes it
 * (EmergencyNumberTracker); nothing here dials anything.
 */
class EmergencyNumbersTest {
    private val unspecified = EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_UNSPECIFIED
    private val police = EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_POLICE
    private val ambulance = EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_AMBULANCE
    private val fire = EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_FIRE_BRIGADE
    private val marine = EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_MARINE_GUARD
    private val unknown = EmergencyNumber.EMERGENCY_CALL_ROUTING_UNKNOWN
    private val emergency = EmergencyNumber.EMERGENCY_CALL_ROUTING_EMERGENCY
    private val normal = EmergencyNumber.EMERGENCY_CALL_ROUTING_NORMAL
    private val network = EmergencyNumber.EMERGENCY_NUMBER_SOURCE_NETWORK_SIGNALING
    private val sim = EmergencyNumber.EMERGENCY_NUMBER_SOURCE_SIM
    private val database = EmergencyNumber.EMERGENCY_NUMBER_SOURCE_DATABASE
    private val default = EmergencyNumber.EMERGENCY_NUMBER_SOURCE_DEFAULT
    private val modem = EmergencyNumber.EMERGENCY_NUMBER_SOURCE_MODEM_CONFIG

    /** An entry; from Android's database unless [sources] says otherwise (0: Android's fallback, from no source). */
    private fun e(digits: String, vararg categories: Int, routing: Int = unknown, sources: Int = database) =
        EmergencyEntry(digits, categories.toSet(), routing, sources)

    /**
     * Android 16's fallback when the modem has reported no list (the radio
     * never on since power-on): EmergencyNumberTracker
     * getEmergencyNumberListFromEccList, "112,911" with a SIM and
     * "112,911,000,08,110,118,119,999" without; each, when the last known
     * country's database does not list it, labelled "unspecified", routing
     * unknown, source bitmask 0 (getLabeledEmergencyNumberForEcclist). In
     * Android's order: equal rank, so by the digits as text
     * (EmergencyNumber.compareTo).
     */
    private fun fallback(numbers: String) = numbers.split(",").sorted().map { e(it, unspecified, sources = 0) }

    @Test
    fun generalMeansUnspecifiedOrPoliceAmbulanceAndFire() {
        assertTrue(EmergencyNumbers.isGeneral(setOf(unspecified)))
        assertTrue(EmergencyNumbers.isGeneral(setOf(police, ambulance, fire)))
        assertTrue(EmergencyNumbers.isGeneral(setOf(police, ambulance, fire, marine)))
        for (c in listOf(setOf(police), setOf(ambulance), setOf(fire), setOf(police, ambulance), setOf(ambulance, fire), setOf(marine), emptySet())) {
            assertFalse(c.toString(), EmergencyNumbers.isGeneral(c))
        }
    }

    /** The reviewer's case: no SIM, no country database, the radio never on. */
    @Test
    fun androidsTiedFallbackListShowsEveryNumber() {
        val noSim = fallback("112,911,000,08,110,118,119,999")
        assertEquals(listOf("000", "08", "110", "112", "118", "119", "911", "999"), noSim.map { it.digits })
        // Not "000", the first by its text: every number, in Android's order.
        assertEquals(NumberReading.Several(listOf("000", "08", "110", "112", "118", "119", "911", "999")), EmergencyNumbers.pick(noSim))
        // With a SIM: the two.
        assertEquals(NumberReading.Several(listOf("112", "911")), EmergencyNumbers.pick(fallback("112,911")))
        // Two subscriptions' lists, merged: each number once.
        assertEquals(NumberReading.Several(listOf("112", "911")), EmergencyNumbers.pick(fallback("112,911,112,911")))
        // Its line says that any of them is placed as an emergency call.
        assertEquals(R.string.emergency_number_several, EmergencyTexts.numberText(NumberReading.Several(listOf("1234", "4321"))))
        val line = StringsXml.of("emergency_number_several")
        assertTrue(line, line.contains("A call to any of them is placed as an emergency call from this phone."))
        assertEquals(listOf("1234", "4321"), EmergencyNumbers.shown(NumberReading.Several(listOf("1234", "4321"))))
        assertEquals(listOf("1234"), EmergencyNumbers.shown(NumberReading.Found("1234")))
        for (r in listOf(NumberReading.NotYet, NumberReading.NoneListed, NumberReading.Unreadable)) assertEquals(emptyList<String>(), EmergencyNumbers.shown(r))
    }

    /** With the last known country's database: its general number, alone (the fallback's other numbers rank below it). */
    @Test
    fun aDatabaseNumberIsShownAlone() {
        val withDatabase = listOf(e("112", police, ambulance, fire, routing = emergency, sources = database)) +
            fallback("911,000,08,110,118,119,999")
        assertEquals(NumberReading.Found("112"), EmergencyNumbers.pick(withDatabase))
        // Two of the database's general numbers alike: the first in Android's order, alone.
        assertEquals(NumberReading.Found("1234"), EmergencyNumbers.pick(listOf(e("1234", police, ambulance, fire), e("4321", unspecified))))
    }

    /** A number from the network (or the SIM) is shown alone, whatever else is listed. */
    @Test
    fun aNetworkNumberIsShownAlone() {
        assertEquals(NumberReading.Found("5678"), EmergencyNumbers.pick(listOf(e("5678", unspecified, sources = network)) + fallback("112,911")))
        assertEquals(NumberReading.Found("5678"), EmergencyNumbers.pick(listOf(e("5678", unspecified, sources = network or modem), e("4321", unspecified, sources = network))))
        assertEquals(NumberReading.Found("4321"), EmergencyNumbers.pick(listOf(e("4321", unspecified, sources = sim)) + fallback("112,911")))
        // Ranked alike with another from the network (or the SIM): still the first alone, as Android orders them.
        assertEquals(NumberReading.Found("4321"), EmergencyNumbers.pick(listOf(e("4321", unspecified, sources = network), e("5678", unspecified, sources = network))))
        assertEquals(NumberReading.Found("1234"), EmergencyNumbers.pick(listOf(e("1234", police, ambulance, fire, sources = sim), e("4321", unspecified, sources = sim))))
    }

    /** From the modem's own lists: one number when it outranks the others, else every one ranked alike. */
    @Test
    fun aNumberThatOutranksTheOthersIsShownAlone() {
        assertEquals(NumberReading.Found("4321"), EmergencyNumbers.pick(listOf(e("4321", unspecified, sources = default), e("1234", unspecified, sources = modem))))
        assertEquals(NumberReading.Found("4321"), EmergencyNumbers.pick(listOf(e("4321", unspecified, sources = default)) + fallback("112,911")))
        assertEquals(
            NumberReading.Several(listOf("1234", "4321")),
            EmergencyNumbers.pick(listOf(e("1234", unspecified, sources = default), e("4321", unspecified, sources = default), e("5678", unspecified, sources = modem))),
        )
        // Only general numbers count: a police number ranked alike changes nothing.
        assertEquals(NumberReading.Found("4321"), EmergencyNumbers.pick(listOf(e("1234", police, sources = default), e("4321", unspecified, sources = default))))
        // Android's ranks: network > SIM > database > default > modem config > none.
        assertEquals(listOf(network, sim, database, default, modem, 0), listOf(0, modem, default, database, sim, network).sortedByDescending { EmergencyNumbers.rank(it) })
        assertEquals(EmergencyNumbers.rank(network) + EmergencyNumbers.rank(database), EmergencyNumbers.rank(network or database))
        assertTrue(EmergencyNumbers.rank(network) > EmergencyNumbers.rank(sim or database or default or modem))
    }

    @Test
    fun theFirstGeneralNumberInAndroidsOrderWins() {
        assertEquals(
            NumberReading.Found("4321"),
            EmergencyNumbers.pick(listOf(e("1234", police), e("4321", police, ambulance, fire), e("5678", unspecified))),
        )
        assertEquals(NumberReading.Found("5678"), EmergencyNumbers.pick(listOf(e("5678", unspecified), e("4321", unspecified))))
        // Routing "emergency" or "unknown" alike.
        assertEquals(NumberReading.Found("1234"), EmergencyNumbers.pick(listOf(e("1234", unspecified, routing = emergency), e("4321", unspecified))))
    }

    @Test
    fun aNumberPlacedAsAnOrdinaryCallOnlyWhenNoOtherGeneralOneExists() {
        assertEquals(
            NumberReading.Found("4321"),
            EmergencyNumbers.pick(listOf(e("1234", unspecified, routing = normal), e("4321", police, ambulance, fire))),
        )
        assertEquals(NumberReading.Found("1234"), EmergencyNumbers.pick(listOf(e("1234", unspecified, routing = normal), e("5678", police))))
    }

    @Test
    fun noneListedOrUnreadable() {
        assertEquals(NumberReading.NoneListed, EmergencyNumbers.pick(listOf(e("1234", police), e("4321", ambulance), e("5678", fire))))
        assertEquals(NumberReading.NoneListed, EmergencyNumbers.pick(emptyList()))
        // Lists read, none general.
        assertEquals(NumberReading.NoneListed, EmergencyNumbers.read { emptyList() })
        // Android's "empty map if this information is not available", and whatever the call throws.
        assertEquals(NumberReading.Unreadable, EmergencyNumbers.read { null })
        for (t in listOf(SecurityException("no"), UnsupportedOperationException("no telephony"), IllegalStateException("no phone"), RuntimeException("x"))) {
            assertEquals(t.javaClass.simpleName, NumberReading.Unreadable, EmergencyNumbers.read { throw t })
        }
        assertEquals(NumberReading.Found("1234"), EmergencyNumbers.read { listOf(e("1234", unspecified)) })
    }

    @Test
    fun oneNumberAcrossSimsAndOnlyShortDigits() {
        // Two SIMs' lists, merged and in Android's order: the same number once.
        val two = listOf(e("1234", unspecified), e("1234", unspecified), e("4321", unspecified))
        assertEquals(NumberReading.Found("1234"), EmergencyNumbers.pick(two))
        // Characters other than digits, too many digits, or none: skipped.
        for (odd in listOf("12*4", "+1234", "12#", "123456789", "", "12 34", "١٢٣")) {
            assertEquals(odd, NumberReading.NoneListed, EmergencyNumbers.pick(listOf(e(odd, unspecified))))
            assertEquals(odd, NumberReading.Found("5678"), EmergencyNumbers.pick(listOf(e(odd, unspecified), e("5678", unspecified))))
        }
        assertEquals(NumberReading.Found("12345678"), EmergencyNumbers.pick(listOf(e("12345678", unspecified))))
        assertEquals(8, EmergencyNumbers.MAX_DIGITS)
    }

    @Test
    fun theScreenReaderReadsDigitByDigit() {
        assertEquals("1 2 3 4", EmergencyNumbers.spoken("1234"))
        assertEquals(R.string.emergency_number_spoken, R.string.emergency_number_spoken)
        assertTrue(StringsXml.of("emergency_number_spoken").contains("%1\$s"))
    }

    /**
     * Never hard-coded: no digit-only string literal (2 to 8 of 0-9, *, #,
     * +) in Welcome's code, comments taken out; none of 3GPP's default
     * emergency numbers as a token in the code at all; and no text names a
     * number.
     */
    @Test
    fun noNumberIsWrittenInTheCode() {
        val sources = SourceScan.sources()
        assertTrue(sources.size > 10)
        val defaults = Regex("(?<![\\w.])(112|911|999|000|08|110|118|119)(?![\\w.])")
        for (f in sources) {
            val code = SourceScan.withoutComments(f.readText())
            SourceScan.literals(code).forEach { assertFalse("${f.name}: \"$it\"", Regex("[0-9*#+]{2,8}").matches(it)) }
            assertFalse(f.name, defaults.containsMatchIn(code))
        }
        // The scan sees literals (it is not empty by accident).
        assertTrue(SourceScan.literals(SourceScan.code("TestHook.kt")).contains("debug.antumbra.emergency_states"))
        // Texts: the number only as a placeholder; no emergency text holds two digits in a row.
        for ((name, v) in StringsXml.texts) {
            if (!name.startsWith("emergency_") && !name.startsWith("position_") && name != "card_emergency") continue
            v.forEach { assertFalse(name, Regex("\\d{2,}").containsMatchIn(it.replace("%1\$s", "").replace("%1\$d", "").replace("%2\$s", ""))) }
        }
        assertTrue(StringsXml.of("emergency_number_spoken").endsWith("%1\$s"))
    }

    /** The Android part reads the list behind READ_PHONE_STATE, sorted by Android's own order, three members of each entry. */
    @Test
    fun theAndroidPartReadsOnlyWhatItNeeds() {
        val code = SourceScan.code("EmergencyNumbers.kt")
        assertTrue(code.contains("checkSelfPermission(Manifest.permission.READ_PHONE_STATE)"))
        assertTrue(code.contains("lists.values.flatten().sorted().map { n: EmergencyNumber ->"))
        assertTrue(code.contains("EmergencyEntry(n.number, n.emergencyServiceCategories.toSet(), n.emergencyCallRouting, n.emergencyNumberSources.fold(0, Int::or))"))
        // Nothing of it is logged.
        assertFalse(code.contains("Log."))
        // Not asked during a call: the last reading stays.
        assertTrue(code.contains("if (!CallWatch.inCall(context)) lastNumber = EmergencyNumbers.read(context)"))
    }
}
