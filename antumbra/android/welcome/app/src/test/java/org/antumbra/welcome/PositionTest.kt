// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL10's "Show my position" without Android: a fake platform and clock.
 * The refusals (nothing changed after any), the whole search, its limits,
 * Location never switched while a call holds, nothing written while it is
 * already off, the position's format, and source scans: GNSS only, nothing
 * stored, logged or sent, no location setting but the switch written, no
 * permission of Welcome's own revoked.
 */
class PositionTest {
    /** Test coordinates: open ocean, no place. */
    private val fix = Fix(10.12345, -140.54321, 5f, mock = true)

    private class FakePlatform : PositionPlatform {
        var t = 1_000_000L
        var owner = true
        var hold = false
        var assisted: Int? = 0
        var network = false
        var scanning: Boolean? = false
        var gps = true
        var permission = false
        var grantWorks = true
        var location = false
        var switchWorks = true
        var startWorks = true
        var active = false

        /** A call begins while the permission is granted (it waits for PermissionController), or while Location is switched on. */
        var callDuringGrant = false
        var callDuringSwitch = false

        /** Location's switch-on is not seen in time (setLocation(true) false) and lands later, when [land] is called. */
        var lateOn = false
        fun land() {
            location = true
        }
        var onFix: ((Fix) -> Unit)? = null
        var onOff: (() -> Unit)? = null

        /** What changed, in order: grants, switches, requests and their removal. */
        val log = ArrayList<String>()

        override fun now() = t
        override fun isOwner() = owner
        override fun callHold() = hold
        override fun assistedGps() = assisted
        override fun hasNetworkProvider() = network
        override fun wifiScanAlways() = scanning
        override fun hasGpsProvider() = gps
        override fun ensurePermission(): Boolean {
            if (!permission && owner && grantWorks) {
                log += "grant"
                permission = true
            }
            if (callDuringGrant) hold = true
            return permission
        }
        override fun locationOn() = location
        override fun setLocation(on: Boolean): Boolean {
            log += "location $on"
            if (on && lateOn) return false
            if (switchWorks) location = on
            if (on && callDuringSwitch) hold = true
            return switchWorks
        }
        override fun startFix(onFix: (Fix) -> Unit, onOff: () -> Unit): Boolean {
            log += "request gps"
            if (!startWorks) return false
            this.onFix = onFix
            this.onOff = onOff
            active = true
            return true
        }
        override fun stopFix() {
            if (active) log += "remove"
            active = false
        }
    }

    private fun machine(processStart: Boolean = false, setup: FakePlatform.() -> Unit = {}): Pair<FakePlatform, PositionMachine> {
        val p = FakePlatform().apply(setup)
        return p to PositionMachine(p, processStart)
    }

    @Test
    fun refusalsInOrderAndNothingChanged() {
        fun case(want: PositionRefusal, setup: FakePlatform.() -> Unit) = setup to want
        val cases = listOf(
            case(PositionRefusal.NOT_OWNER) { owner = false; hold = true; assisted = 1 },
            case(PositionRefusal.CALL) { hold = true; assisted = 1 },
            case(PositionRefusal.ASSISTED) { assisted = 1; network = true },
            case(PositionRefusal.ASSISTED) { assisted = null },
            case(PositionRefusal.ASSISTED) { assisted = 2 },
            case(PositionRefusal.NETWORK_PROVIDER) { network = true; scanning = true },
            case(PositionRefusal.WIFI_SCANNING) { scanning = true; gps = false },
            case(PositionRefusal.WIFI_SCANNING) { scanning = null },
            case(PositionRefusal.NO_GPS) { gps = false },
        )
        for ((setup, want) in cases) {
            val (p, m) = machine(setup = setup)
            assertEquals(want, m.refusal())
            m.press()
            assertEquals(PositionState.Refused(want), m.state)
            // Nothing granted, switched or asked; assisted GPS and every other setting untouched.
            assertEquals(want.name, emptyList<String>(), p.log)
            assertFalse(p.location)
        }
        assertNull(machine().second.refusal())
    }

    @Test
    fun theWholeSearch() {
        val (p, m) = machine()
        m.press()
        assertEquals(listOf("grant", "location true", "request gps"), p.log)
        assertEquals(PositionState.Looking(p.t), m.state)
        assertTrue(m.busy())
        p.t += 42_000
        p.onFix!!(fix)
        assertEquals(listOf("grant", "location true", "request gps", "remove", "location false"), p.log)
        assertEquals(PositionState.Found(fix, p.t), m.state)
        assertFalse(p.location)
        val ui = m.snapshot()
        assertTrue(ui.touched && !ui.offPending)
        assertEquals(R.string.position_off_again, PositionTexts.offLine(ui))
        // A second press: the permission is held, nothing granted again (and never revoked).
        m.press()
        assertEquals(listOf("location true", "request gps"), p.log.drop(5))
        assertFalse(p.log.any { it.contains("revoke") || it.contains("deny") })
    }

    @Test
    fun theSearchLooksThreeMinutesAtMost() {
        assertEquals(180_000L, PositionMachine.SEARCH_MS)
        val (p, m) = machine()
        m.press()
        val start = p.t
        p.t = start + 179_999
        m.tick()
        assertTrue(m.state is PositionState.Looking)
        assertTrue(p.location)
        p.t = start + 180_000
        m.tick()
        assertEquals(PositionState.Ended(PositionEnd.TIMEOUT), m.state)
        assertEquals(listOf("remove", "location false"), p.log.takeLast(2))
        assertFalse(p.location)
        assertEquals(R.string.position_timeout, PositionTexts.end(PositionEnd.TIMEOUT))
    }

    @Test
    fun stopTheScreenLeavingAndStartSwitchOff() {
        for (why in listOf(PositionEnd.STOPPED, PositionEnd.LEFT, PositionEnd.START)) {
            val (p, m) = machine()
            m.press()
            m.end(why)
            assertEquals(PositionState.Ended(why), m.state)
            assertEquals(listOf("remove", "location false"), p.log.takeLast(2))
            assertFalse(p.location)
            assertFalse(m.busy())
        }
        // A fix that comes after the end is not shown.
        val (p, m) = machine()
        m.press()
        val late = p.onFix!!
        m.end(PositionEnd.LEFT)
        late(fix)
        assertEquals(PositionState.Ended(PositionEnd.LEFT), m.state)
        // Start also takes a position off the screen; leaving does not.
        val (_, m2) = machine()
        m2.press()
        m2.onFix(fix)
        m2.end(PositionEnd.LEFT)
        assertTrue(m2.state is PositionState.Found)
        m2.end(PositionEnd.START)
        assertEquals(PositionState.Idle, m2.state)
    }

    @Test
    fun locationSwitchedOffElsewhere() {
        val (p, m) = machine()
        m.press()
        // The moment the provider takes to follow the switch: not an end.
        p.onOff!!()
        assertTrue(m.state is PositionState.Looking)
        p.location = false
        p.onOff!!()
        assertEquals(PositionState.Ended(PositionEnd.WENT_OFF), m.state)
        // Already off: nothing written.
        assertFalse(p.log.contains("location false"))
    }

    /** A call beginning during a search: no switch while the hold lasts, off at the first look after it (every 5 s). */
    @Test
    fun noSwitchDuringACall() {
        val (p, m) = machine()
        m.press()
        p.hold = true
        m.tick()
        assertEquals(PositionState.Ended(PositionEnd.CALL), m.state)
        assertEquals("remove", p.log.last())
        assertTrue(p.location)
        var ui = m.snapshot()
        assertTrue(ui.offPending && ui.offWaitsForCall)
        assertEquals(R.string.position_off_call, PositionTexts.offLine(ui))
        repeat(30) {
            p.t += 10_000
            m.tick()
        }
        assertTrue(p.location)
        assertFalse(p.log.contains("location false"))
        assertTrue(m.busy())
        p.hold = false
        // Looked at again 5 s after the last look, not sooner.
        p.t += 1_000
        m.tick()
        assertTrue(p.location)
        p.t += 4_000
        m.tick()
        assertFalse(p.location)
        assertEquals("location false", p.log.last())
        ui = m.snapshot()
        assertFalse(ui.offPending)
        assertEquals(R.string.position_off_again, PositionTexts.offLine(ui))
        assertFalse(m.busy())
    }

    @Test
    fun offWhenSafeWritesNothingWhenOffAndWaitsForACall() {
        // Already off: nothing written, hold or not.
        for (hold in listOf(false, true)) {
            val (p, m) = machine { this.hold = hold }
            assertEquals(PositionMachine.Off.OFF, m.offWhenSafe())
            assertEquals(emptyList<String>(), p.log)
        }
        // On, during a hold (the baseline at boot or Start): left as it is.
        val (p, m) = machine { location = true; hold = true }
        assertEquals(PositionMachine.Off.WAITS_FOR_CALL, m.offWhenSafe())
        assertEquals(emptyList<String>(), p.log)
        assertTrue(p.location)
        // At shutdown: at once, hold or not.
        assertTrue(m.offNow())
        assertEquals(listOf("location false"), p.log)
        // On, no hold: off.
        val (p2, m2) = machine { location = true }
        assertEquals(PositionMachine.Off.OFF, m2.offWhenSafe())
        assertEquals(listOf("location false"), p2.log)
        // Not the device owner: nothing to retry (it could not switch it).
        val (p3, m3) = machine { location = true; owner = false }
        assertEquals(PositionMachine.Off.FAILED, m3.offWhenSafe())
        assertEquals(emptyList<String>(), p3.log)
        assertFalse(m3.busy())
    }

    @Test
    fun failuresChangeNothingOrAreRetried() {
        // The permission cannot be had: nothing switched.
        val (p, m) = machine { grantWorks = false }
        m.press()
        assertEquals(PositionState.Ended(PositionEnd.NO_PERMISSION), m.state)
        assertEquals(emptyList<String>(), p.log)
        // Location does not come on: nothing asked, nothing left on.
        val (p2, m2) = machine { switchWorks = false }
        m2.press()
        assertEquals(PositionState.Ended(PositionEnd.SWITCH_FAILED), m2.state)
        assertFalse(p2.log.contains("request gps"))
        assertFalse(p2.location)
        assertNull(PositionTexts.offLine(m2.snapshot()))
        // The request fails: Location off again.
        val (p3, m3) = machine { startWorks = false }
        m3.press()
        assertEquals(PositionState.Ended(PositionEnd.REQUEST_FAILED), m3.state)
        assertFalse(p3.location)
        // Location does not go off: tried again every 5 s.
        val (p4, m4) = machine()
        m4.press()
        p4.switchWorks = false
        p4.onFix!!(fix)
        assertTrue(p4.location)
        assertEquals(R.string.position_off_retry, PositionTexts.offLine(m4.snapshot()))
        val tries = p4.log.count { it == "location false" }
        p4.t += 1_000
        m4.tick()
        assertEquals(tries, p4.log.count { it == "location false" })
        p4.t += 4_000
        m4.tick()
        assertEquals(tries + 1, p4.log.count { it == "location false" })
        p4.switchWorks = true
        p4.t += 5_000
        m4.tick()
        assertFalse(p4.location)
        assertFalse(m4.snapshot().offPending)
    }

    /** Review finding 2: a call that begins while the first press grants the permission. Nothing is switched or asked. */
    @Test
    fun aCallThatBeginsDuringThePressSwitchesNothing() {
        val (p, m) = machine { callDuringGrant = true }
        m.press()
        assertEquals(PositionState.Refused(PositionRefusal.CALL), m.state)
        assertEquals(listOf("grant"), p.log)
        assertFalse(p.location)
        assertFalse(m.busy())
        assertNull(PositionTexts.offLine(m.snapshot()))
    }

    /** Review finding 2: a call that begins while Location comes on: no request, and Location left as it is until the hold ends. */
    @Test
    fun aCallThatBeginsDuringTheSwitchLeavesLocationAsItIsUntilTheHoldEnds() {
        val (p, m) = machine { callDuringSwitch = true }
        m.press()
        assertEquals(PositionState.Refused(PositionRefusal.CALL), m.state)
        assertEquals(listOf("grant", "location true"), p.log)
        assertTrue(p.location)
        var ui = m.snapshot()
        assertTrue(ui.offPending && ui.offWaitsForCall)
        assertEquals(R.string.position_off_call, PositionTexts.offLine(ui))
        repeat(20) {
            p.t += 10_000
            m.tick()
        }
        assertEquals(listOf("grant", "location true"), p.log)
        p.hold = false
        p.t += PositionMachine.RETRY_MS
        m.tick()
        assertEquals(listOf("grant", "location true", "location false"), p.log)
        ui = m.snapshot()
        assertFalse(ui.offPending || p.location || m.busy())
        assertEquals(R.string.position_off_again, PositionTexts.offLine(ui))
    }

    /**
     * Review finding 3: Location's switch-on is not seen within the wait
     * (setLocation(true) false), then lands. Welcome looks again RETRY_MS
     * later and switches it off, with no other event; and says "Nothing was
     * changed" only once Location reads off and was never on.
     */
    @Test
    fun aLateSwitchOnIsUndone() {
        // It lands after the press, before the look: off at the look, by the ticks alone.
        val (p, m) = machine { lateOn = true }
        m.press()
        assertEquals(PositionState.Ended(PositionEnd.SWITCH_FAILED), m.state)
        assertTrue(m.busy())
        assertNull(PositionTexts.offLine(m.snapshot()))
        p.t += 2_000
        p.land()
        m.tick()
        assertTrue(p.location)
        p.t += PositionMachine.RETRY_MS
        m.tick()
        assertFalse(p.location)
        assertEquals(listOf("grant", "location true", "location false"), p.log)
        assertFalse(m.busy())
        assertEquals(R.string.position_off_again, PositionTexts.offLine(m.snapshot()))
        // The reviewer's probe: it lands, then the screen leaves: off at once.
        val (p2, m2) = machine { lateOn = true }
        m2.press()
        p2.land()
        m2.end(PositionEnd.LEFT)
        assertFalse(p2.location)
        // The screen leaving before it lands does not end the look.
        val (p3, m3) = machine { lateOn = true }
        m3.press()
        p3.t += 1_000
        m3.end(PositionEnd.LEFT)
        p3.land()
        repeat(10) {
            p3.t += 1_000
            m3.tick()
        }
        assertFalse(p3.location)
        // It never lands: "Nothing was changed" once the look has found Location off, not before.
        val (p4, m4) = machine { lateOn = true }
        m4.press()
        assertNull(PositionTexts.offLine(m4.snapshot()))
        p4.t += PositionMachine.RETRY_MS
        m4.tick()
        assertFalse(m4.busy())
        assertEquals(R.string.position_unchanged, PositionTexts.offLine(m4.snapshot()))
        assertEquals(listOf("grant", "location true"), p4.log)
        assertEquals("Location could not be switched on.", StringsXml.text(PositionTexts.end(PositionEnd.SWITCH_FAILED)))
        assertEquals("Nothing was changed: Location is off.", StringsXml.of("position_unchanged"))
        // It lands during a call: left as it is until the hold ends.
        val (p5, m5) = machine { lateOn = true }
        m5.press()
        p5.land()
        p5.hold = true
        p5.t += PositionMachine.RETRY_MS
        m5.tick()
        assertTrue(p5.location)
        assertEquals(R.string.position_off_call, PositionTexts.offLine(m5.snapshot()))
        p5.hold = false
        p5.t += PositionMachine.RETRY_MS
        m5.tick()
        assertFalse(p5.location)
    }

    /**
     * Review finding 4: the process's machine. Welcome's call record starts
     * empty with the process, so a Location found on at its first look (left
     * on by an earlier process) is held as after a call: not switched off
     * before CALLBACK_WINDOW_MS from the process's start, whichever switch-off
     * comes first (atProcessStart, or the baseline at boot).
     */
    @Test
    fun aProcessStartWithLocationOnWaitsAsAfterACall() {
        assertEquals(CallWatch.CALLBACK_WINDOW_MS, 5 * 60_000L)
        val (p, m) = machine(processStart = true) { location = true }
        val start = p.t
        assertEquals(PositionMachine.Off.WAITS_FOR_CALL, m.offWhenSafe())
        assertTrue(p.location && m.busy())
        val ui = m.snapshot()
        assertTrue(ui.offPending && ui.offWaitsForStart && !ui.offWaitsForCall)
        assertEquals(R.string.position_off_start, PositionTexts.offLine(ui))
        while (p.t < start + CallWatch.CALLBACK_WINDOW_MS - PositionMachine.RETRY_MS) {
            p.t += PositionMachine.RETRY_MS
            m.tick()
            // The baseline, Start or the screen leaving meanwhile change nothing either.
            assertEquals(PositionMachine.Off.WAITS_FOR_CALL, m.offWhenSafe())
            m.end(PositionEnd.LEFT)
        }
        assertTrue(p.location)
        assertEquals(emptyList<String>(), p.log)
        p.t = start + CallWatch.CALLBACK_WINDOW_MS
        m.tick()
        assertFalse(p.location)
        assertEquals(listOf("location false"), p.log)
        assertFalse(m.busy())
        // A call then still holds it, as always.
        val (p2, m2) = machine(processStart = true) { location = true; hold = true }
        m2.offWhenSafe()
        p2.t += CallWatch.CALLBACK_WINDOW_MS
        m2.tick()
        assertTrue(p2.location)
        assertEquals(R.string.position_off_call, PositionTexts.offLine(m2.snapshot()))
        p2.hold = false
        p2.t += PositionMachine.RETRY_MS
        m2.tick()
        assertFalse(p2.location)
        // Location off at the first look: nothing written, and no wait later (a search ends with Location off at once).
        val (p3, m3) = machine(processStart = true)
        assertEquals(PositionMachine.Off.OFF, m3.offWhenSafe())
        assertFalse(m3.busy())
        m3.press()
        p3.onFix!!(fix)
        assertFalse(p3.location)
        assertEquals(listOf("grant", "location true", "request gps", "remove", "location false"), p3.log)
        // Not the process's machine: no wait.
        val (p4, m4) = machine { location = true }
        assertEquals(PositionMachine.Off.OFF, m4.offWhenSafe())
        assertFalse(p4.location)
        // The process's machine is the one made with processStart, and the process's start asks it.
        assertTrue(position.contains("PositionMachine(AndroidPosition(context.applicationContext, worker) { changed() }, processStart = true)"))
        assertTrue(position.contains("fun atProcessStart(context: Context) = later(context) { it.offWhenSafe() }"))
        assertEquals(1, Regex("processStart = true").findAll(SourceScan.sources().joinToString { SourceScan.withoutComments(it.readText()) }).count())
        assertTrue(SourceScan.code("WelcomeApp.kt").contains("Position.atProcessStart(this)"))
    }

    /** Review finding 5: Location's switch that cannot be read counts as on (Welcome tries to switch it off, and never says it is off). */
    @Test
    fun anUnreadableLocationCountsAsOn() {
        for (t in listOf(SecurityException("no"), IllegalStateException("no"), RuntimeException("x"))) {
            assertTrue(t.javaClass.simpleName, AndroidPosition.switchOn { throw t })
        }
        assertTrue(AndroidPosition.switchOn { true })
        assertFalse(AndroidPosition.switchOn { false })
        assertTrue(position.contains("override fun locationOn(): Boolean = switchOn { lm.isLocationEnabled }"))
        assertEquals(1, Regex("isLocationEnabled").findAll(position).count())
        // Read as on: the machine switches it off, and the card does not say it is off.
        val (p, m) = machine { location = true; switchWorks = false }
        m.offWhenSafe()
        assertEquals(R.string.position_off_retry, PositionTexts.offLine(m.snapshot()))
        assertEquals(listOf("location false"), p.log)
    }

    /** Review finding 5: the window rules, the same for both screens. */
    @Test
    fun theWindowRules() {
        val secure = android.view.WindowManager.LayoutParams.FLAG_SECURE
        val keepOn = android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        assertEquals(secure or keepOn, WindowRules.MASK)
        val states = listOf(
            PositionState.Idle, PositionState.Refused(PositionRefusal.CALL), PositionState.Looking(0),
            PositionState.Found(fix, 0), PositionState.Ended(PositionEnd.TIMEOUT),
        )
        val typed = Choices(torMode = TorMode.BRIDGES, bridgeSource = BridgeSource.CUSTOM, bridgeText = "obfs4 192.0.2.1:443 X")
        for (s in states) {
            val found = s is PositionState.Found
            val looking = s is PositionState.Looking
            assertEquals(s.toString(), found, WindowRules.secure(s))
            assertEquals(s.toString(), looking, WindowRules.keepOn(s))
            assertEquals(s.toString(), (if (found) secure else 0) or (if (looking) keepOn else 0), WindowRules.flags(s))
            assertEquals(s.toString(), found, WindowRules.secure(s, Choices()))
            // Bridge lines typed: secure whatever the position.
            assertTrue(s.toString(), WindowRules.secure(s, typed))
            assertEquals(s.toString(), secure or (if (looking) keepOn else 0), WindowRules.flags(s, typed))
        }
        assertFalse(WindowRules.typedBridges(typed.copy(bridgeText = " ")))
        assertFalse(WindowRules.typedBridges(typed.copy(bridgeSource = BridgeSource.BUILT_IN)))
        assertFalse(WindowRules.typedBridges(typed.copy(torMode = TorMode.DIRECT)))
        // Each screen sets exactly those flags from the rules, and no other way.
        val uses = mapOf(
            "WelcomeActivity.kt" to "snapshotFlow { WindowRules.flags(Position.ui.state, WelcomeModel.ui.choices) }\n                .collect { window.setFlags(it, WindowRules.MASK) }",
            "StatusActivity.kt" to "snapshotFlow { WindowRules.flags(Position.ui.state) }\n                .collect { window.setFlags(it, WindowRules.MASK) }",
        )
        for ((f, use) in uses) {
            val code = SourceScan.code(f)
            assertTrue(f, code.contains(use))
            for (w in listOf("FLAG_SECURE", "FLAG_KEEP_SCREEN_ON", "window.addFlags", "window.clearFlags", "window.attributes", "keepScreenOn", "setRecentsScreenshotEnabled")) {
                assertFalse("$f: $w", code.contains(w))
            }
            assertEquals(f, 1, Regex("window\\.setFlags\\(").findAll(code).count())
        }
    }

    @Test
    fun thePositionStaysFifteenMinutesAtMost() {
        assertEquals(15 * 60_000L, PositionMachine.SHOW_MS)
        val (p, m) = machine()
        m.press()
        p.onFix!!(fix)
        val at = p.t
        p.t = at + PositionMachine.SHOW_MS - 1
        m.tick()
        assertTrue(m.state is PositionState.Found)
        p.t = at + PositionMachine.SHOW_MS
        m.tick()
        assertEquals(PositionState.Idle, m.state)
        // Hide.
        m.press()
        p.onFix!!(fix)
        m.hide()
        assertEquals(PositionState.Idle, m.state)
        // A press while looking is ignored.
        m.press()
        val before = p.log.toList()
        m.press()
        assertEquals(before, p.log)
    }

    @Test
    fun theFormat() {
        val default = Locale.getDefault()
        try {
            // Languages whose decimal mark is a comma, and one with its own digits (language tags only).
            for (locale in listOf(Locale.ROOT, Locale.forLanguageTag("de"), Locale.forLanguageTag("fr"), Locale.forLanguageTag("ar"))) {
                Locale.setDefault(locale)
                assertEquals(R.string.position_north to "10.12345", PositionFormat.latitude(10.12345))
                assertEquals(R.string.position_west to "140.54321", PositionFormat.longitude(-140.54321))
                assertEquals("10.12345, -140.54321", PositionFormat.map(10.12345, -140.54321))
                assertEquals(R.string.position_south to "45.67891", PositionFormat.latitude(-45.678912))
                assertEquals(R.string.position_east to "75.43210", PositionFormat.longitude(75.4321))
                assertEquals("-45.67891, 75.43210", PositionFormat.map(-45.678912, 75.4321))
            }
        } finally {
            Locale.setDefault(default)
        }
        // Rounded first: no "-0.00000", no southern zero.
        assertEquals(R.string.position_north to "0.00000", PositionFormat.latitude(-0.000004))
        assertEquals(R.string.position_east to "0.00000", PositionFormat.longitude(-0.000004))
        assertEquals("0.00000, 0.00000", PositionFormat.map(-0.000004, -0.000001))
        assertEquals(R.string.position_east to "180.00000", PositionFormat.longitude(180.0))
        assertEquals(R.string.position_west to "180.00000", PositionFormat.longitude(-180.0))
        assertEquals(R.string.position_south to "90.00000", PositionFormat.latitude(-90.0))
        assertEquals(5, PositionFormat.accuracy(5f))
        assertEquals(1, PositionFormat.accuracy(0.2f))
        assertNull(PositionFormat.accuracy(null))
        assertNull(PositionFormat.accuracy(Float.NaN))
        assertEquals(0, PositionFormat.ageMinutes(0, 59_999))
        assertEquals(3, PositionFormat.ageMinutes(0, 3 * 60_000 + 5))
        assertEquals(0, PositionFormat.ageMinutes(10, 0))
        // The texts take the digits as written.
        assertEquals("%1\$s° N", StringsXml.of("position_north"))
        assertEquals("%1\$s° W", StringsXml.of("position_west"))
        assertEquals("On a map: %1\$s", StringsXml.of("position_map"))
    }

    @Test
    fun theTextsForEachEnd() {
        for (r in PositionRefusal.entries) assertTrue(r.name, StringsXml.text(PositionTexts.refusal(r)).isNotBlank())
        assertEquals(PositionRefusal.entries.size, PositionRefusal.entries.map { PositionTexts.refusal(it) }.toSet().size)
        for (e in PositionEnd.entries) assertTrue(e.name, StringsXml.text(PositionTexts.end(e)).isNotBlank())
        assertEquals(R.string.position_refused_assisted, PositionTexts.refusal(PositionRefusal.ASSISTED))
        assertEquals(R.string.position_stopped, PositionTexts.end(PositionEnd.CALL))
        // No off line before Location was ever on.
        assertNull(PositionTexts.offLine(PositionUi()))
        assertNull(PositionTexts.offLine(PositionUi(state = PositionState.Refused(PositionRefusal.ASSISTED))))
        assertNull(PositionTexts.offLine(PositionUi(state = PositionState.Ended(PositionEnd.NO_PERMISSION))))
    }

    // --- Source scans --------------------------------------------------------

    private val position = SourceScan.code("Position.kt")
    private val card = SourceScan.code("ui/EmergencyCard.kt")

    /** GNSS only: the GPS provider alone is asked; never fused, network, passive or a remembered fix. */
    @Test
    fun onlyTheSatelliteReceiverIsAsked() {
        for (f in SourceScan.sources()) {
            val code = SourceScan.withoutComments(f.readText())
            if (f.name != "Position.kt") assertFalse(f.name, Regex("\\bLocationManager\\b|\\bLocationRequest\\b|\\bLocationListener\\b").containsMatchIn(code))
            for (w in listOf(
                "getLastKnownLocation", "lastKnownLocation", "getCurrentLocation", "FUSED_PROVIDER", "PASSIVE_PROVIDER",
                "setLocationSettingsIgnored", "requestSingleUpdate",
                "addNmeaListener", "registerGnssStatusCallback", "registerGnssMeasurementsCallback", "sendExtraCommand",
            )) {
                assertFalse("${f.name}: $w", code.contains(w))
            }
        }
        // No provider named by its string (LocationManager.GPS_PROVIDER is "gps").
        assertFalse(Regex("\"(fused|passive|network|gps)\"").containsMatchIn(position))
        assertEquals(1, Regex("requestLocationUpdates\\(").findAll(position).count())
        assertTrue(position.contains("lm.requestLocationUpdates(LocationManager.GPS_PROVIDER, request, executor, l)"))
        assertEquals(listOf("hasProvider(LocationManager.NETWORK_PROVIDER)"), Regex("\\w*\\(?LocationManager\\.NETWORK_PROVIDER\\)?").findAll(position).map { it.value }.toList())
        assertTrue(position.contains(".setMaxUpdates(1)"))
        assertTrue(position.contains(".setDurationMillis(PositionMachine.SEARCH_MS)"))
    }

    /** The position is shown on screen and nowhere else. */
    @Test
    fun thePositionGoesNowhere() {
        for ((name, code) in listOf("Position.kt" to position, "EmergencyCard.kt" to card)) {
            Regex("Log\\.[a-z]\\(([^\\n]*)").findAll(code).forEach {
                assertFalse("$name: ${it.value}", it.groupValues[1].contains("$") || it.groupValues[1].contains("+"))
            }
            for (w in listOf(
                "File(", "openFileOutput", "SharedPreferences", "getSharedPreferences", "putString", "SystemProperty",
                "ClipboardManager", "ClipData", "putExtra", "ContentValues", "Settings.Global.put", "Settings.Secure.put",
                "Settings.System.put", "setGlobalSetting", "setSecureSetting", "Notification", "sendBroadcast", "startActivity",
                "Intent(", "Socket", "URL(", "HttpURLConnection", "println", "toString()",
            )) {
                assertFalse("$name: $w", code.contains(w))
            }
        }
        // Not in the provider, the status the module reads, the add-on's status page or the module's words.
        for (f in listOf("StateProvider.kt", "SessionService.kt", "AddOnStatus.kt", "ModuleWord.kt", "CellWord.kt", "Session.kt")) {
            val code = SourceScan.code(f)
            assertFalse(f, Regex("\\bPosition\\w*\\b|\\bFix\\b").containsMatchIn(code))
        }
        // A screen showing it cannot be captured (theWindowRules); a search ends when the screen leaves.
        for (f in listOf("WelcomeActivity.kt", "StatusActivity.kt")) {
            val code = SourceScan.code(f)
            assertTrue(f, code.contains("WindowRules.flags(Position.ui.state"))
            assertTrue(f, code.contains("if (!isChangingConfigurations) Position.leave(this)"))
        }
        // The screen going off ends a search too, and Start ends it first.
        assertTrue(SourceScan.code("WelcomeApp.kt").contains("if (intent.action == Intent.ACTION_SCREEN_OFF) Position.leave(context)"))
        val start = SourceScan.code("WelcomeActivity.kt")
        assertTrue(start.indexOf("Position.endForStart(this@WelcomeActivity)") in 0 until start.indexOf("policies.applyAtStart(choices, check.present)"))
    }

    /**
     * Welcome never writes assisted_gps_enabled, or any GNSS, SUPL, XTRA or
     * location provider setting (Android's emergency location may depend on
     * them): it reads assisted_gps_enabled and writes only Location's own
     * switch, through the device owner's setLocationEnabled, in Position.kt
     * alone.
     */
    @Test
    fun noLocationSettingButTheSwitchIsWritten() {
        val keys = Regex("assisted_gps|ASSISTED_GPS|supl|SUPL|xtra|XTRA|gnss|GNSS|gps_|location_providers|LOCATION_PROVIDERS|location_mode|LOCATION_MODE|wifi_scan_always|ble_scan_always|SCAN_ALWAYS")
        for (f in SourceScan.sources()) {
            val code = SourceScan.withoutComments(f.readText())
            // Every settings write names only the adb keys Policies has always written.
            Regex("(?:setGlobalSetting|setSecureSetting|setSystemSetting|Settings\\.(?:Global|Secure|System)\\.put\\w*)\\(([^\\n]*)").findAll(code).forEach {
                assertFalse("${f.name}: ${it.value}", keys.containsMatchIn(it.groupValues[1]))
                assertTrue("${f.name}: ${it.value}", f.name == "Policies.kt" && Regex("ADB_(WIFI_)?ENABLED").containsMatchIn(it.groupValues[1]))
            }
            for (w in listOf("setProviderEnabledForUser", "setLocationEnabledForUser", "setLocationProviderEnabled", "setAdasGnssLocationEnabled", "setExtraLocationControllerPackage")) {
                assertFalse("${f.name}: $w", code.contains(w))
            }
            if (f.name != "Position.kt") assertFalse(f.name, code.contains("setLocationEnabled(") || code.contains(AndroidPosition.ASSISTED_GPS_ENABLED))
        }
        assertEquals(1, Regex("dpm\\.setLocationEnabled\\(admin, on\\)").findAll(position).count())
        assertEquals(1, Regex("setLocationEnabled\\(").findAll(position).count())
        // Read only.
        assertEquals(listOf("Settings.Global.getInt(context.contentResolver, ASSISTED_GPS_ENABLED, 1)"),
            Regex("[\\w.]+\\([^()\\n]*ASSISTED_GPS_ENABLED[^()\\n]*\\)").findAll(position).map { it.value }.toList())
        assertEquals("assisted_gps_enabled", AndroidPosition.ASSISTED_GPS_ENABLED)
    }

    /** Welcome never revokes a permission of its own: that kills its process, and the session with it. */
    @Test
    fun noPermissionOfWelcomesOwnIsRevoked() {
        for (f in SourceScan.sources()) {
            val code = SourceScan.withoutComments(f.readText())
            for (w in listOf("PERMISSION_GRANT_STATE_DENIED", "PERMISSION_GRANT_STATE_DEFAULT", "revokeSelfPermission", "revokeRuntimePermission", "revokeSelfPermissionsOnKill")) {
                assertFalse("${f.name}: $w", code.contains(w))
            }
            // Each call's arguments (to its closing parenthesis): the last is GRANTED.
            Regex("setPermissionGrantState\\(").findAll(code).forEach {
                var depth = 1
                var i = it.range.last + 1
                while (depth > 0) {
                    if (code[i] == '(') depth++ else if (code[i] == ')') depth--
                    i++
                }
                val args = code.substring(it.range.last + 1, i - 1).trim().trimEnd(',').trim()
                assertTrue("${f.name}: $args", args.endsWith("DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED"))
            }
        }
        assertEquals(listOf("android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"), AndroidPosition.PERMISSIONS)
        assertTrue(position.contains("PERMISSIONS.all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }"))
    }

    /** The baseline's Location off goes through offWhenSafe; shutdown's at once (PoliciesTest has the lists). */
    @Test
    fun theBaselineWaitsForACallButShutdownDoesNot() {
        val policies = SourceScan.code("Policies.kt")
        val baseline = SourceScan.function(policies, "applyBaseline(")
        assertTrue(baseline.contains("if (atShutdown) {\n                check(Position.offNow(context))"))
        assertTrue(baseline.contains("check(Position.offWhenSafe(context) != PositionMachine.Off.FAILED)"))
        assertFalse(policies.contains("setLocationEnabled"))
        assertTrue(SourceScan.code("Receivers.kt").contains("policies.applyBaseline(atShutdown = true)"))
        assertEquals(1, Regex("atShutdown = true").findAll(SourceScan.sources().joinToString { SourceScan.withoutComments(it.readText()) }).count())
        // The hold: Quick power off's, plus Telecom's own "in a call", and no permission counts as a hold.
        val hold = SourceScan.function(SourceScan.code("EmergencyCall.kt"), "locationHold(")
        assertTrue(hold.contains("record.hold(CallRecord.isCallMode(mode), inCallbackMode(context), now, words) != null) return true"))
        assertTrue(hold.contains("!= PackageManager.PERMISSION_GRANTED) return true"))
        assertTrue(hold.contains("telecom.isInCall"))
        assertTrue(position.contains("override fun callHold(): Boolean = CallWatch.locationHold(context)"))
        assertTrue(File("src/main/java/org/antumbra/welcome/WelcomeApp.kt").readText().contains("Position.atProcessStart(this)"))
    }
}
