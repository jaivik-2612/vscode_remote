// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL8's texts, read from strings.xml: for each of the five sessions, each
 * state of the cellular radio, each way Tor connects and what the add-on
 * carries out, what the screens say. "Offline" is said only when the
 * session has no Internet and no Phone and the radio is known to be off;
 * the carrier card is honest and complete; the key statements are pinned
 * word for word; the corrected texts say what WEL8 corrected.
 */
class PhoneTextTest {
    private val xml = File("src/main/res/values/strings.xml").readText()

    /** string and plurals texts by resource name (comments are not texts). */
    private val texts: Map<String, List<String>> = run {
        val m = HashMap<String, List<String>>()
        Regex("""<string name="([a-z0-9_]+)">([^<]*)</string>""").findAll(xml).forEach {
            m[it.groupValues[1]] = listOf(it.groupValues[2])
        }
        Regex("""<plurals name="([a-z0-9_]+)">(.*?)</plurals>""", RegexOption.DOT_MATCHES_ALL).findAll(xml).forEach { p ->
            m[p.groupValues[1]] = Regex("""<item quantity="[a-z]+">([^<]*)</item>""").findAll(p.groupValues[2])
                .map { it.groupValues[1] }.toList()
        }
        m
    }

    /** R ids back to their names, through R's own fields. */
    private val names: Map<Int, String> = (R.string::class.java.fields + R.plurals::class.java.fields)
        .associate { it.getInt(null) to it.name }

    private fun text(id: Int): List<String> {
        val name = names[id] ?: error("no resource $id")
        return texts[name] ?: error("no text for $name")
    }

    private fun all(ids: List<Int>): List<String> = ids.flatMap { text(it) }

    private val sessions = listOf(
        Internet.WIFI to CellLevel.OFF,
        Internet.WIFI to CellLevel.PHONE,
        Internet.NONE to CellLevel.OFF,
        Internet.NONE to CellLevel.PHONE,
        Internet.MOBILE to CellLevel.DATA,
    )

    /** Everything the status screen can say about this session and radio (but the numbers). */
    private fun statusTexts(internet: Internet, cell: CellLevel, tor: TorMode, radio: Radio, carried: CellLevel?): List<String> {
        val ids = ArrayList<Int>()
        ids += PhoneTexts.status(internet, tor, radio, cell, carried)
        ids += PhoneTexts.carrierNow(radio, internet, tor, carried)
        ids += PhoneTexts.internetValue(internet, carried)
        ids += PhoneTexts.torValue(internet, tor)
        ids += PhoneTexts.phoneValue(cell, carried)
        ids += PhoneTexts.radio(radio)
        for (ims in ImsState.entries) ids += PhoneTexts.ims(ims, PhoneTexts.phoneMode(cell, carried))
        if (internet == Internet.NONE) ids += R.string.tor_no_internet
        return all(ids)
    }

    @Test
    fun offlineOnlyWithoutInternetAndPhoneAndTheRadioKnownOff() {
        for ((internet, cell) in sessions) {
            for (tor in listOf(TorMode.DIRECT, TorMode.BRIDGES)) {
                val wireTor = if (internet == Internet.NONE) TorMode.OFFLINE else tor
                for (radio in Radio.entries) {
                    for (carried in listOf(null, CellLevel.OFF, CellLevel.PHONE, cell)) {
                        val said = statusTexts(internet, cell, wireTor, radio, carried)
                        val offline = said.any { it.contains("offline", ignoreCase = true) }
                        // Phone off: chosen off, or not carried out (a gate lowered holds until the next start).
                        val phoneOff = (carried ?: cell) == CellLevel.OFF
                        assertEquals(
                            "$internet $cell $tor $radio $carried",
                            internet == Internet.NONE && radio == Radio.OFF && phoneOff,
                            offline,
                        )
                    }
                }
            }
        }
        // Exactly one text says it, and it is the one chosen above.
        val withOffline = texts.filterValues { v -> v.any { it.contains("offline", ignoreCase = true) } }.keys
        assertEquals(setOf("status_mode_none_radio_off"), withOffline)
        assertEquals(
            R.string.status_mode_none_radio_off,
            PhoneTexts.status(Internet.NONE, TorMode.OFFLINE, Radio.OFF, CellLevel.OFF, CellLevel.OFF),
        )
        // None with calls and texts, the radio off for now: no "offline", and the radio may come back.
        val phone = PhoneTexts.status(Internet.NONE, TorMode.OFFLINE, Radio.OFF, CellLevel.PHONE, CellLevel.PHONE)
        assertEquals(R.string.status_mode_none_radio_off_phone, phone)
        assertEquals(phone, PhoneTexts.status(Internet.NONE, TorMode.OFFLINE, Radio.OFF, CellLevel.PHONE, null))
        assertTrue(text(phone).single().contains("The cellular radio is off for now; calls and texts reach this phone again"))
    }

    /** Mobile data the add-on did not allow (the gate lowered, or a race at Start) is not said to be on. */
    @Test
    fun mobileDataNotCarriedOutIsNotSaidToBeOn() {
        for (tor in listOf(TorMode.DIRECT, TorMode.BRIDGES)) {
            for (carried in listOf(CellLevel.OFF, CellLevel.PHONE)) {
                assertFalse("$tor $carried", PhoneTexts.statusIsPlural(Internet.MOBILE, tor, carried))
                assertEquals(R.string.value_cell_refused, PhoneTexts.internetValue(Internet.MOBILE, carried))
                for (radio in Radio.entries) {
                    assertEquals(R.string.status_mode_mobile_refused, PhoneTexts.status(Internet.MOBILE, tor, radio, CellLevel.DATA, carried))
                    val card = PhoneTexts.carrierNow(radio, Internet.MOBILE, tor, carried).map { names.getValue(it) }
                    assertFalse("$tor $carried $radio", "carrier_data_tor" in card || "carrier_data_bridges" in card)
                    assertEquals("$tor $carried $radio", radio != Radio.OFF, "carrier_data_off" in card)
                    val said = statusTexts(Internet.MOBILE, CellLevel.DATA, tor, radio, carried)
                    assertFalse("$tor $carried $radio", said.any { it.contains("over mobile data") || it.contains("Mobile data goes through Tor") })
                }
            }
            // Carried out, or not known yet: over mobile data.
            for (carried in listOf(null, CellLevel.DATA)) {
                val want = if (tor == TorMode.BRIDGES) R.plurals.status_mode_bridges_mobile else R.string.status_mode_direct_mobile
                assertEquals(want, PhoneTexts.status(Internet.MOBILE, tor, Radio.ON, CellLevel.DATA, carried))
                assertEquals(tor == TorMode.BRIDGES, PhoneTexts.statusIsPlural(Internet.MOBILE, tor, carried))
            }
        }
        val t = texts.getValue("status_mode_mobile_refused").single()
        assertTrue(t.contains("did not allow mobile data on this phone") && t.contains("Tor does not connect"))
    }

    @Test
    fun theWelcomeScreenNeverSaysOffline() {
        for (i in Internet.entries) {
            for (phone in listOf(false, true)) {
                for (tor in listOf(TorMode.DIRECT, TorMode.BRIDGES)) {
                    val c = Choices(torMode = tor).withInternet(i).withPhone(phone)
                    val said = all(PhoneTexts.carrierChoice(c))
                    assertFalse("$i $phone $tor", said.any { it.contains("offline", ignoreCase = true) })
                }
            }
        }
        listOf(
            "internet_wifi_detail", "internet_mobile_detail", "internet_none_detail", "phone_off_detail",
            "phone_calls_detail", "welcome_intro", "internet_mobile_unavailable", "phone_calls_unavailable",
        ).forEach { name -> assertFalse(name, texts.getValue(name).single().contains("offline", ignoreCase = true)) }
    }

    @Test
    fun theCarrierCardIsCompleteWheneverTheRadioMayBeOn() {
        val sees = listOf("carrier_sees_sim", "carrier_sees_imei", "carrier_sees_cells", "carrier_sees_calls", "carrier_no_tor_calls")
        for ((internet, cell) in sessions) {
            for (tor in listOf(TorMode.DIRECT, TorMode.BRIDGES)) {
                for (radio in Radio.entries) for (carried in listOf(null, cell)) {
                    val shown = PhoneTexts.carrierNow(radio, internet, tor, carried).map { names.getValue(it) }
                    if (radio == Radio.OFF) {
                        assertEquals(listOf("carrier_now_off"), shown.take(1))
                        assertFalse(shown.any { it in sees })
                    } else {
                        assertTrue("$internet $tor $radio", shown.containsAll(sees))
                    }
                    val data = when {
                        radio == Radio.OFF -> null
                        internet == Internet.MOBILE && tor == TorMode.BRIDGES -> "carrier_data_bridges"
                        internet == Internet.MOBILE -> "carrier_data_tor"
                        else -> "carrier_data_off"
                    }
                    if (data != null) assertTrue("$internet $tor $radio", data in shown)
                    assertEquals("$internet $radio", internet == Internet.WIFI, "carrier_hotspot" in shown)
                }
            }
        }
        // The Welcome screen's card follows the choice.
        val off = PhoneTexts.carrierChoice(Choices()).map { names.getValue(it) }
        assertEquals(listOf("carrier_choice_off", "carrier_hotspot"), off)
        val on = PhoneTexts.carrierChoice(Choices().withPhone(true)).map { names.getValue(it) }
        assertEquals("carrier_choice_on", on.first())
        assertTrue(on.containsAll(sees))
        val mobile = PhoneTexts.carrierChoice(Choices(torMode = TorMode.BRIDGES).withInternet(Internet.MOBILE)).map { names.getValue(it) }
        assertTrue(mobile.containsAll(sees + "carrier_data_bridges"))
        // Every Phone-on choice, None included, lists what the carrier sees; every Phone-off one says it is off.
        for (i in Internet.entries) {
            for (tor in listOf(TorMode.DIRECT, TorMode.BRIDGES)) {
                for (phone in listOf(false, true)) {
                    val c = Choices(torMode = tor).withInternet(i).withPhone(phone)
                    val shown = PhoneTexts.carrierChoice(c).map { names.getValue(it) }
                    if (c.cell == CellLevel.OFF) {
                        assertEquals("$i $tor $phone", "carrier_choice_off", shown.first())
                    } else {
                        assertEquals("$i $tor $phone", "carrier_choice_on", shown.first())
                        assertTrue("$i $tor $phone", shown.containsAll(sees))
                    }
                }
            }
        }
    }

    /**
     * The statements that matter most, word for word: Phone on is not
     * anonymous; with mobile data the carrier sees that Tor is used, but
     * not what you do; with Phone off no calls or texts reach the phone;
     * whenever the radio is on, an emergency call included, the carrier
     * sees the phone, its SIM and roughly where it is.
     */
    @Test
    fun theKeyStatementsAreSaid() {
        val t = { name: String -> texts.getValue(name).single() }
        // Phone on is not anonymous, and calls and texts do not go through Tor.
        assertTrue(t("phone_calls_detail").contains("Not anonymous: your carrier sees your SIM card, this phone and roughly where you are."))
        assertTrue(t("phone_calls_detail").contains("Calls and texts do not go through Tor."))
        assertTrue(t("carrier_no_tor_calls").contains("Calls and texts never go through Tor."))
        // Mobile data: the carrier sees that you use Tor, not what you do.
        assertTrue(t("internet_mobile_detail").contains("Your carrier sees that you use Tor, but not what you do."))
        assertTrue(t("carrier_data_tor").contains("your carrier sees only encrypted Tor traffic, and that you use Tor."))
        assertTrue(t("carrier_data_bridges").contains("Plain bridges do not hide that you use Tor."))
        // Phone off: no calls or texts, and no way named that would bring them.
        assertTrue(t("phone_off_detail").contains("The cellular radio stays off, so calls and texts cannot reach this phone."))
        assertTrue(t("carrier_choice_off").contains("With Phone off, the cellular radio stays off"))
        for (name in listOf("phone_off_detail", "carrier_choice_off")) assertFalse(name, t(name).contains("Wi-Fi"))
        // An emergency call switches the radio on: the carrier then sees what it sees for any call.
        assertTrue(t("phone_off_detail").contains("Android still switches the radio on for an emergency call."))
        assertTrue(
            t("carrier_choice_off").contains(
                "Android switches the radio on for an emergency call; your carrier then sees this phone, its SIM card and roughly where you are",
            ),
        )
        // Whenever the radio is on: the SIM, the phone and roughly where you are.
        assertTrue(t("carrier_sees_sim").contains("your SIM card"))
        assertTrue(t("carrier_sees_imei").contains("(its IMEI)"))
        assertTrue(t("carrier_sees_cells").contains("roughly where you are, all the time"))
        assertTrue(t("carrier_now_unknown").contains("While it is on, your carrier sees:"))
        assertTrue(t("carrier_now_on").contains("While it is, your carrier sees:"))
        assertTrue(t("carrier_choice_on").contains("While it is on, your carrier sees:"))
    }

    @Test
    fun theCarrierCardSaysWhatTheCarrierSees() {
        val t = { name: String -> texts.getValue(name).single() }
        assertTrue(t("carrier_sees_sim").contains("SIM card"))
        assertTrue(t("carrier_sees_imei").contains("IMEI"))
        assertTrue(t("carrier_sees_cells").contains("roughly where you are"))
        assertTrue(t("carrier_sees_calls").contains("who you call and text"))
        assertTrue(t("carrier_sees_calls").contains("what you say"))
        assertTrue(t("carrier_no_tor_calls").contains("never go through Tor"))
        assertTrue(t("carrier_data_tor").contains("only encrypted Tor traffic, and that you use Tor"))
        assertTrue(t("carrier_data_bridges").contains("Plain bridges do not hide that you use Tor"))
    }

    @Test
    fun theCorrectedTexts() {
        val t = { name: String -> texts.getValue(name).single() }
        // The new Wi-Fi address changes neither the IMEI nor the IMSI.
        assertTrue(t("mac_on").contains("IMEI") && t("mac_on").contains("IMSI"))
        assertTrue(t("mac_on").contains("does not change"))
        // Plain bridges do not hide Tor use.
        assertTrue(t("tor_bridges_detail").contains("do not hide that you use Tor"))
        assertFalse(t("tor_bridges_detail").contains("Hides"))
        // Administration no longer covers location.
        assertTrue(t("admin_detail").contains("Location stays off"))
        assertFalse(t("admin_detail").contains("turning Location on"))
        // Welcome cannot type the SIM PIN; type it only after a normal start,
        // decided from what can be known while Android's PIN screen covers Welcome.
        assertTrue(t("sim_pin_help").contains("Welcome cannot type it for you, and its warnings cannot be seen then"))
        assertTrue(t("sim_pin_help").contains("Type the PIN only after a normal start"))
        assertTrue(t("sim_pin_help").contains("After an update, start once without the SIM card"))
        assertTrue(t("warning_no_addon").contains("do not type it"))
        // "Stay offline" is gone: Internet: None.
        listOf("tor_offline", "tor_offline_detail", "status_mode_offline", "value_offline", "tor_offline_state")
            .forEach { assertFalse(it, it in texts) }
        assertTrue(t("start_refused_policies").contains("Internet: None"))
    }

    @Test
    fun simAndVolteLines() {
        for (s in SimState.entries) assertTrue(s.name, names.getValue(PhoneTexts.sim(s)).startsWith("sim_"))
        assertEquals(SimState.entries.size, SimState.entries.map { PhoneTexts.sim(it) }.toSet().size)
        assertEquals("Locked: needs its PIN", text(PhoneTexts.sim(SimState.PIN)).single())
        assertEquals("Unlocked", text(PhoneTexts.sim(SimState.READY)).single())
        assertEquals("None in the phone", text(PhoneTexts.sim(SimState.ABSENT)).single())
        // The PIN's help while a SIM is in the phone; the PUK's while one needs it; none without a SIM.
        assertEquals(R.string.sim_pin_help, PhoneTexts.simHelp(listOf(SimState.PIN, SimState.ABSENT)))
        assertEquals(R.string.sim_puk_help, PhoneTexts.simHelp(listOf(SimState.READY, SimState.PUK)))
        assertEquals(null, PhoneTexts.simHelp(listOf(SimState.ABSENT, SimState.ABSENT)))
        assertEquals(null, PhoneTexts.simHelp(emptyList()))
        // The VoLTE line outside Phone mode: not checked (the module reads IMS in Phone mode only).
        for (ims in ImsState.entries) assertEquals(R.string.ims_off, PhoneTexts.ims(ims, phoneMode = false))
        assertTrue(texts.getValue("ims_off").single().startsWith("Not checked"))
        assertEquals(R.string.ims_cell, PhoneTexts.ims(ImsState.CELL, phoneMode = true))
        assertEquals(R.string.ims_wifi, PhoneTexts.ims(ImsState.WIFI, phoneMode = true))
        // In Phone mode, the module's "off" before its first reading is not known yet, never off.
        assertEquals(R.string.ims_unknown, PhoneTexts.ims(ImsState.OFF, phoneMode = true))
        for (ims in ImsState.entries) assertTrue(ims.name, PhoneTexts.ims(ims, phoneMode = true) != R.string.ims_off)
        // Phone mode: carried out, or chosen while the module has not said yet.
        assertTrue(PhoneTexts.phoneMode(CellLevel.PHONE, null))
        assertFalse(PhoneTexts.phoneMode(CellLevel.PHONE, CellLevel.OFF))
        assertTrue(PhoneTexts.phoneMode(CellLevel.DATA, CellLevel.PHONE))
        assertFalse(PhoneTexts.phoneMode(CellLevel.OFF, null))
        assertEquals(R.string.value_cell_refused, PhoneTexts.phoneValue(CellLevel.PHONE, CellLevel.OFF))
        assertEquals(R.string.value_calls, PhoneTexts.phoneValue(CellLevel.DATA, CellLevel.PHONE))
        assertEquals(R.string.value_cell_refused, PhoneTexts.internetValue(Internet.MOBILE, CellLevel.PHONE))
        assertEquals(R.string.value_mobile, PhoneTexts.internetValue(Internet.MOBILE, null))
    }

    /** The warning for a SIM unlocked while the add-on is not running: only then. */
    @Test
    fun simUnlockedWithoutTheAddOn() {
        val unlocked = listOf(SimState.READY, SimState.ABSENT)
        assertTrue(PhoneTexts.simUnlockedWithoutAddOn(unlocked, addOnPresent = false))
        // The add-on running, or not known yet: no warning.
        assertFalse(PhoneTexts.simUnlockedWithoutAddOn(unlocked, addOnPresent = true))
        assertFalse(PhoneTexts.simUnlockedWithoutAddOn(unlocked, addOnPresent = null))
        // A locked SIM, or none: nothing to warn about (warning_no_addon says not to type the PIN).
        for (s in SimState.entries.filter { it != SimState.READY }) {
            assertFalse(s.name, PhoneTexts.simUnlockedWithoutAddOn(listOf(s, SimState.ABSENT), addOnPresent = false))
        }
        assertFalse(PhoneTexts.simUnlockedWithoutAddOn(emptyList(), addOnPresent = false))
        assertTrue(texts.getValue("warning_sim_unlocked_no_addon").single().contains("Restart the phone"))
    }

    /** No number that could be dialled, and no country or carrier named, in any WEL8 or WEL10 text. */
    @Test
    fun noNumberAndNoPlace() {
        val wel8 = texts.filterKeys {
            it.startsWith("internet_") || it.startsWith("phone_") || it.startsWith("sim_") || it.startsWith("carrier_") ||
                it.startsWith("ims_") || it.startsWith("radio_") || it.startsWith("status_mode_") || it.startsWith("cell_") ||
                it.startsWith("emergency_state_") || it.startsWith("emergency_number_") || it.startsWith("emergency_numbers_") ||
                it.startsWith("emergency_other_") || it.startsWith("position_")
        }
        assertTrue(wel8.size > 40)
        wel8.forEach { (name, v) ->
            v.forEach { s ->
                assertFalse(name, Regex("\\d{2,}").containsMatchIn(s.replace("%1\$d", "").replace("4G", "").replace("2G", "").replace("3G", "")))
            }
        }
    }

    /**
     * No country named in Welcome's code or its tests through a locale: no
     * Locale constant but ROOT, and language tags only (no region), so a
     * test that needs a language's number format names the language alone.
     */
    @Test
    fun noLocaleNamesACountry() {
        val files = listOf("src/main/java", "src/test/java").flatMap { d ->
            File(d).walkTopDown().filter { it.isFile && it.extension in setOf("kt", "java") }.toList()
        }
        assertTrue(files.size > 20)
        val constant = Regex("\\bLocale\\s*\\.\\s*([A-Z][A-Z_]*)\\b")
        val withRegion = Regex("\\bLocale\\s*\\(\\s*\"[^\"]*\"\\s*,|forLanguageTag\\s*\\(\\s*\"[A-Za-z]{2,8}[-_][^\"]*\"")
        for (f in files) {
            val code = SourceScan.withoutComments(f.readText())
            constant.findAll(code).forEach { assertEquals("${f.name}: ${it.value}", "ROOT", it.groupValues[1]) }
            assertFalse(f.name, withRegion.containsMatchIn(code))
        }
        // The scan sees a locale constant and a language tag (it is not empty by accident).
        val position = SourceScan.withoutComments(File("src/test/java/org/antumbra/welcome/PositionTest.kt").readText())
        assertTrue(constant.containsMatchIn(position) && position.contains("Locale.forLanguageTag(\"de\")"))
        // Seeds with a made-up region (the constant split, so that this file passes its own scan).
        for (seed in listOf("Locale" + ".ENGLISH", "Locale" + ".XX", "Locale(\"xx\", \"YY\")", "Locale.forLanguageTag(\"xx-YY\")")) {
            assertTrue(seed, constant.findAll(seed).any { it.groupValues[1] != "ROOT" } || withRegion.containsMatchIn(seed))
        }
    }
}
