// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.media.AudioManager
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MOD11 without Android: who may give Welcome the module's word, which words
 * it takes, and what Quick power off does with each of the three states
 * (emergency, ordinary, unknown). Unknown, and anything Welcome cannot use,
 * always waits exactly as before MOD11.
 */
class ModuleWordTest {
    private val minute = 60_000L
    private val second = 1_000L

    private fun values(
        calls: String = "ordinary",
        at: Any? = 100L,
        until: Any? = 0L,
        ims: String = "off",
        imsAt: Any? = 0L,
        v: Any? = 1,
    ): Map<String, Any?> = mapOf("v" to v, "calls" to calls, "at" to at, "until" to until, "ims" to ims, "ims_at" to imsAt)

    private fun word(calls: CallKind, atS: Long, untilS: Long = 0) = ModuleWord(calls, atS, untilS, ImsState.OFF, 0)

    /** A call that ended at [endS] seconds since boot, as the audio mode listener records it. */
    private fun callEndedAt(endS: Long): CallRecord = CallRecord().apply {
        onMode(AudioManager.MODE_IN_CALL, now = (endS - 60) * second)
        onMode(AudioManager.MODE_NORMAL, now = endS * second)
    }

    private fun wordsWith(word: ModuleWord?, now: Long): ModuleWords = ModuleWords().apply { take(word, now) }

    @Test
    fun onlyRootMayGiveTheWord() {
        assertTrue(ModuleWord.isAllowedWriter(0))
        // The shell (adb), the system, an app, an app in another user, tor and the filter.
        listOf(2000, 1000, 10123, 1002000, 2950, 2951, -1).forEach { assertFalse("uid $it", ModuleWord.isAllowedWriter(it)) }
    }

    @Test
    fun aWordOfEachKindIsTaken() {
        assertEquals(ModuleWord(CallKind.ORDINARY, 100, 0, ImsState.OFF, 0), ModuleWord.parse(values()))
        assertEquals(CallKind.NONE, ModuleWord.parse(values(calls = "none"))?.calls)
        assertEquals(CallKind.UNKNOWN, ModuleWord.parse(values(calls = "unknown"))?.calls)
        assertEquals(
            ModuleWord(CallKind.EMERGENCY, 100, 400, ImsState.OFF, 0),
            ModuleWord.parse(values(calls = "emergency", until = 400L)),
        )
        assertEquals(ImsState.CELL, ModuleWord.parse(values(ims = "cell", imsAt = 90L))?.ims)
        assertEquals(ImsState.WIFI, ModuleWord.parse(values(ims = "wifi", imsAt = 90L))?.ims)
        // No time since boot: the module says "unknown" at 0.
        assertEquals(CallKind.UNKNOWN, ModuleWord.parse(values(calls = "unknown", at = 0L))?.calls)
    }

    @Test
    fun anythingElseIsMalformed() {
        val good = values()
        listOf(
            good - "until",
            good + ("extra" to 1),
            values(v = 2),
            values(v = 1L),
            values(at = 100),
            values(at = "100"),
            values(at = -1L),
            values(until = -1L),
            values(imsAt = -1L),
            values(calls = "Ordinary"),
            values(calls = "emergency call"),
            values(ims = "lte"),
            values(calls = "emergency", until = 99L),
            values(calls = "emergency", until = 401L),
            values(until = 1L),
            values(calls = "none", until = 400L),
            values(ims = "off", imsAt = 90L),
            emptyMap(),
        ).forEach { assertNull(it.toString(), ModuleWord.parse(it)) }
    }

    @Test
    fun aForgedWordIsRefusedAndChangesNothing() {
        val now = 110 * second
        val words = wordsWith(word(CallKind.UNKNOWN, 105), now)
        val held = callEndedAt(100)
        val before = held.waitLeftMs(now, words)
        for (uid in listOf(10123, 2000, 1000)) {
            var read = false
            var taken = false
            assertThrows(SecurityException::class.java) {
                ModuleWord.receive(uid, ModuleWord.METHOD, null, { read = true; values(at = 105L) }) { taken = true; words.take(it, now) }
            }
            // Refused before its extras were even read.
            assertFalse("uid $uid", read)
            assertFalse("uid $uid", taken)
        }
        // A forged "ordinary" would have let Quick power off go at once: it still waits.
        assertEquals(before, held.waitLeftMs(now, words))
        assertEquals(PowerOffHold.AFTER_CALL, held.hold(callNow = false, callbackMode = false, now = now, words = words))
    }

    @Test
    fun rootGivesTheWordAndAMalformedOneClearsIt() {
        val now = 110 * second
        val words = ModuleWords()
        val held = callEndedAt(100)
        ModuleWord.receive(0, ModuleWord.METHOD, null, { values(at = 105L) }) { words.take(it, now) }
        assertNull(held.hold(callNow = false, callbackMode = false, now = now, words = words))
        assertThrows(IllegalArgumentException::class.java) {
            ModuleWord.receive(0, ModuleWord.METHOD, null, { values(at = 105L, v = 2) }) { words.take(it, now) }
        }
        // The malformed word replaced the ordinary one: the wait is back.
        assertEquals(5, held.minutesLeft(now, words))
        assertThrows(IllegalArgumentException::class.java) {
            ModuleWord.receive(0, "query", null, { values() }) { words.take(it, now) }
        }
        assertThrows(IllegalArgumentException::class.java) {
            ModuleWord.receive(0, ModuleWord.METHOD, "x", { values() }) { words.take(it, now) }
        }
    }

    /** Ordinary: the one case in which Quick power off skips its wait after a call. */
    @Test
    fun aFreshOrdinaryWordAfterTheCallLetsQuickPowerOffGo() {
        val held = callEndedAt(100)
        val now = 110 * second
        assertNull(held.hold(callNow = false, callbackMode = false, now = now, words = wordsWith(word(CallKind.ORDINARY, 105), now)))
        assertNull(held.hold(callNow = false, callbackMode = false, now = now, words = wordsWith(word(CallKind.ORDINARY, 100), now)))
        // 30 s old still counts; 31 s does not.
        val words = wordsWith(word(CallKind.ORDINARY, 105), now)
        assertNull(held.hold(callNow = false, callbackMode = false, now = 135 * second, words = words))
        assertEquals(PowerOffHold.AFTER_CALL, held.hold(callNow = false, callbackMode = false, now = 136 * second, words = words))
    }

    @Test
    fun anOrdinaryWordThatDoesNotCoverTheCallWaitsAsBefore() {
        val held = callEndedAt(100)
        val now = 110 * second
        val today = held.minutesLeft(now)
        // Stale (31 s old), from a look before the call ended, or from the future.
        listOf(word(CallKind.ORDINARY, 79), word(CallKind.ORDINARY, 99), word(CallKind.ORDINARY, 111)).forEach {
            val words = wordsWith(it, now)
            assertEquals(it.toString(), PowerOffHold.AFTER_CALL, held.hold(callNow = false, callbackMode = false, now = now, words = words))
            assertEquals(it.toString(), today, held.minutesLeft(now, words))
        }
    }

    @Test
    fun duringACallAndInCallbackModeEveryWordWaits() {
        val now = 110 * second
        val words = wordsWith(word(CallKind.ORDINARY, 109), now)
        val inCall = CallRecord().apply { onMode(AudioManager.MODE_IN_CALL, now = 100 * second) }
        assertEquals(PowerOffHold.CALL, inCall.hold(callNow = false, callbackMode = false, now = now, words = words))
        assertEquals(PowerOffHold.CALL, CallRecord().hold(callNow = true, callbackMode = false, now = now, words = words))
        assertEquals(PowerOffHold.CALLBACK_MODE, CallRecord().hold(callNow = false, callbackMode = true, now = now, words = words))
    }

    /** "Unknown always waits": every word Welcome cannot use waits exactly as before MOD11. */
    @Test
    fun unknownAlwaysWaitsExactlyAsBefore() {
        val held = callEndedAt(100)
        val forged = ModuleWords()
        runCatching { ModuleWord.receive(10123, ModuleWord.METHOD, null, { values(at = 105L) }) { forged.take(it, 105 * second) } }
        val malformed = ModuleWords()
        runCatching { ModuleWord.receive(0, ModuleWord.METHOD, null, { values(at = 105L, until = 3L) }) { malformed.take(it, 105 * second) } }
        val cases = mapOf(
            "unknown" to wordsWith(word(CallKind.UNKNOWN, 105), 105 * second),
            "none" to wordsWith(word(CallKind.NONE, 105), 105 * second),
            "no word yet" to ModuleWords(),
            "forged" to forged,
            "malformed" to malformed,
            "no module" to null,
        )
        for ((name, words) in cases) {
            // Every whole second of the 5 minutes after the call's end, and 999 ms after each.
            for (now in (100 * second until 400 * second step second).flatMap { listOf(it, it + 999) }) {
                val t = now / 1000.0
                assertEquals("$name at $t s", PowerOffHold.AFTER_CALL, held.hold(callNow = false, callbackMode = false, now = now, words = words))
                assertEquals("$name at $t s", held.minutesLeft(now), held.minutesLeft(now, words))
                assertEquals("$name at $t s", held.waitLeftMs(now), held.waitLeftMs(now, words))
            }
            assertNull(name, held.hold(callNow = false, callbackMode = false, now = 400 * second, words = words))
        }
        // Without a call there is nothing to wait for, whatever the word.
        assertNull(CallRecord().hold(callNow = false, callbackMode = false, now = 105 * second, words = cases["unknown"]))
    }

    /** Emergency: Quick power off waits at least until the word's end, even for a call this process did not see. */
    @Test
    fun anEmergencyWordMakesQuickPowerOffWait() {
        val noCall = CallRecord()
        val now = 110 * second
        val words = wordsWith(word(CallKind.EMERGENCY, 105, 400), now)
        assertEquals(PowerOffHold.AFTER_CALL, noCall.hold(callNow = false, callbackMode = false, now = now, words = words))
        assertEquals(290 * second, noCall.waitLeftMs(now, words))
        assertEquals(5, noCall.minutesLeft(now, words))
        assertEquals(PowerOffHold.AFTER_CALL, noCall.hold(callNow = false, callbackMode = false, now = 399 * second, words = words))
        assertNull(noCall.hold(callNow = false, callbackMode = false, now = 400 * second, words = words))
        // With a call it saw end later than the word's end: the longer of the two.
        val held = callEndedAt(200)
        assertEquals(held.waitLeftMs(now = 300 * second), held.waitLeftMs(300 * second, words))
        assertEquals(PowerOffHold.AFTER_CALL, held.hold(callNow = false, callbackMode = false, now = 450 * second, words = words))
        // A word from a look in the future (clocks disagree): the whole 5 minutes from now.
        assertEquals(CallWatch.CALLBACK_WINDOW_MS, wordsWith(word(CallKind.EMERGENCY, 200, 300), now).emergencyLeftMs(now))
        // The end is never more than 5 minutes after the look.
        assertEquals(405 * second, word(CallKind.EMERGENCY, 105, 900).emergencyEndMs(now))
    }

    @Test
    fun aLaterWordNeverShortensAnEmergencyWait() {
        val noCall = CallRecord()
        val words = ModuleWords()
        words.take(word(CallKind.EMERGENCY, 105, 400), 110 * second)
        words.take(word(CallKind.ORDINARY, 300), 300 * second)
        words.take(word(CallKind.NONE, 310), 310 * second)
        words.take(null, 320 * second)
        assertEquals(PowerOffHold.AFTER_CALL, noCall.hold(callNow = false, callbackMode = false, now = 320 * second, words = words))
        assertEquals(80 * second, noCall.waitLeftMs(320 * second, words))
        // An ordinary word relaxes Welcome's own wait, never the module's emergency one.
        val held = callEndedAt(290)
        assertEquals(80 * second, held.waitLeftMs(320 * second, wordsWith(word(CallKind.ORDINARY, 300), 300 * second).also {
            it.take(word(CallKind.EMERGENCY, 105, 400), 300 * second)
            it.take(word(CallKind.ORDINARY, 315), 315 * second)
        }))
    }

    @Test
    fun theImsReadingCountsFor15Minutes() {
        val words = ModuleWords()
        assertEquals(ImsState.UNKNOWN, words.ims(100 * second))
        words.take(ModuleWord(CallKind.NONE, 1000, 0, ImsState.CELL, 990), 1000 * second)
        assertEquals(ImsState.CELL, words.ims(1000 * second))
        assertEquals(ImsState.CELL, words.ims(990 * second + 15 * minute))
        assertEquals(ImsState.UNKNOWN, words.ims(990 * second + 15 * minute + 1))
        words.take(ModuleWord(CallKind.NONE, 2000, 0, ImsState.OFF, 0), 2000 * second)
        assertEquals(ImsState.OFF, words.ims(2000 * second))
        words.take(null, 2001 * second)
        assertEquals(ImsState.UNKNOWN, words.ims(2001 * second))
    }

    @Test
    fun theWindowIsAndroidsOwnAndTheProviderTakesTheWord() {
        assertEquals(CallWatch.CALLBACK_WINDOW_MS, ModuleWord.WINDOW_S * 1000)
        assertEquals("module_word", ModuleWord.METHOD)
        // The provider's call hands the binder's own uid straight to receive (tested above), and does
        // nothing before it. Only the emulator (welcome_module_word) checks the uid through binder.
        // Since WEL8 it goes through ModuleCalls.receive, which checks the uid
        // before it looks at the method (CellWordTest).
        val provider = File("src/main/java/org/antumbra/welcome/StateProvider.kt").readText()
        val call = Regex(
            """override fun call\(method: String, arg: String\?, extras: Bundle\?\): Bundle \{\s*""" +
                """ModuleCalls\.receive\(Binder\.getCallingUid\(\), method, arg, \{""",
        )
        assertTrue(call.containsMatchIn(provider))
        assertEquals(1, Regex("""\.receive\(""").findAll(provider).count())
        assertFalse(provider.contains("isAllowedWriter"))
        // The word is never logged.
        listOf("ModuleWord.kt", "StateProvider.kt", "EmergencyCall.kt").forEach {
            val src = File("src/main/java/org/antumbra/welcome/$it").readText()
            assertFalse(it, Regex("Log\\.[a-z]\\([^)]*(\\bword\\b|\\bcalls\\b|ModuleWord|CallKind)", RegexOption.IGNORE_CASE).containsMatchIn(src))
        }
        assertNotNull(CallKind.of("emergency"))
    }
}
