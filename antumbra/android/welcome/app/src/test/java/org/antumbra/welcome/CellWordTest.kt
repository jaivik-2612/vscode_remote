// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL8 without Android: the module's word on the cell radio (module_cell):
 * who may give it, which words Welcome takes, and that the provider looks
 * at the caller before anything else.
 */
class CellWordTest {
    private fun values(
        gate: Any? = "phone",
        cell: Any? = "none",
        radio: Any? = "off",
        at: Any? = 100L,
        v: Any? = 1,
    ): Map<String, Any?> = mapOf("v" to v, "gate" to gate, "cell" to cell, "radio" to radio, "at" to at)

    @Test
    fun aWordOfEachValueIsTaken() {
        assertEquals(CellWord(CellLevel.PHONE, null, RadioWord.OFF, 100), CellWord.parse(values()))
        for (g in CellLevel.entries) assertEquals(g, CellWord.parse(values(gate = g.wire))?.gate)
        for (c in CellLevel.entries) assertEquals(c, CellWord.parse(values(cell = c.wire))?.cell)
        for (r in RadioWord.entries) assertEquals(r, CellWord.parse(values(radio = r.wire))?.radio)
        // Before the module's first look: at 0.
        assertEquals(0L, CellWord.parse(values(at = 0L))?.atS)
        assertEquals(setOf("v", "gate", "cell", "radio", "at"), CellWord.KEYS)
        assertEquals("module_cell", CellWord.METHOD)
    }

    @Test
    fun anythingElseIsMalformed() {
        val good = values()
        listOf(
            good - "at",
            good + ("extra" to 1),
            values(v = 2),
            values(v = 1L),
            values(at = 100),
            values(at = "100"),
            values(at = -1L),
            values(gate = "none"),
            values(gate = "Phone"),
            values(gate = "calls"),
            values(gate = 1),
            values(cell = "Phone"),
            values(cell = ""),
            values(cell = null),
            values(radio = "1"),
            values(radio = "ON"),
            values(radio = null),
            emptyMap(),
        ).forEach { assertNull(it.toString(), CellWord.parse(it)) }
    }

    @Test
    fun onlyRootMayGiveItAndNothingIsReadBefore() {
        var cell: CellWord? = CellWord(CellLevel.DATA, CellLevel.DATA, RadioWord.ON, 50)
        for (uid in listOf(2000, 1000, 10123, 1002000, 2950, 2951, -1)) {
            var read = false
            assertThrows(SecurityException::class.java) {
                ModuleCalls.receive(uid, CellWord.METHOD, null, { read = true; values() }, { error("word") }) { cell = it }
            }
            // Refused before the extras were even read.
            assertFalse("uid $uid", read)
            // And before the method was looked at: an unknown one is refused the same way.
            assertThrows(SecurityException::class.java) {
                ModuleCalls.receive(uid, "anything", null, { read = true; values() }, { error("word") }) { cell = it }
            }
            assertFalse("uid $uid", read)
        }
        assertEquals(CellLevel.DATA, cell?.gate)
    }

    @Test
    fun rootGivesItAndAMalformedOneClearsIt() {
        var cell: CellWord? = null
        var word: ModuleWord? = ModuleWord(CallKind.NONE, 1, 0, ImsState.OFF, 0)
        ModuleCalls.receive(0, CellWord.METHOD, null, { values(gate = "data") }, { word = it }) { cell = it }
        assertEquals(CellLevel.DATA, cell?.gate)
        // MOD11's word is untouched by a cell word.
        assertEquals(CallKind.NONE, word?.calls)
        assertThrows(IllegalArgumentException::class.java) {
            ModuleCalls.receive(0, CellWord.METHOD, null, { values(gate = "everything") }, { word = it }) { cell = it }
        }
        // The malformed word cleared it: Welcome offers nothing that needs the gate.
        assertNull(cell)
        assertEquals(CallKind.NONE, word?.calls)
        // An unknown method changes neither word.
        cell = CellWord(CellLevel.PHONE, null, RadioWord.OFF, 1)
        assertThrows(IllegalArgumentException::class.java) {
            ModuleCalls.receive(0, "module_other", null, { values() }, { word = null }) { cell = null }
        }
        assertEquals(CellLevel.PHONE, cell?.gate)
        assertEquals(CallKind.NONE, word?.calls)
        assertThrows(IllegalArgumentException::class.java) {
            ModuleCalls.receive(0, CellWord.METHOD, "x", { values() }, { word = null }) { cell = it }
        }
        // MOD11's word still goes through.
        ModuleCalls.receive(
            0, ModuleWord.METHOD, null,
            { mapOf("v" to 1, "calls" to "unknown", "at" to 5L, "until" to 0L, "ims" to "off", "ims_at" to 0L) },
            { word = it },
        ) { error("cell") }
        assertEquals(CallKind.UNKNOWN, word?.calls)
    }

    /** The word stays in memory: never logged, written or handed out. */
    @Test
    fun theWordIsKeptInMemoryOnly() {
        val src = File("src/main/java/org/antumbra/welcome/CellWord.kt").readText()
        assertFalse(Regex("Log\\.[a-z]\\([^)]*(\\bword\\b|cellWord|CellWord|gate)", RegexOption.IGNORE_CASE).containsMatchIn(src))
        listOf("FileOutputStream", "writeText", "openFileOutput", "SharedPreferences", "setprop", "Settings.Global.put")
            .forEach { assertFalse(it, src.contains(it)) }
        // The provider dispatches only after the uid check, in one place.
        val provider = File("src/main/java/org/antumbra/welcome/StateProvider.kt").readText()
        assertEquals(1, Regex("""ModuleCalls\.receive\(Binder\.getCallingUid\(\), method""").findAll(provider).count())
        val calls = src.substring(src.indexOf("object ModuleCalls"))
        assertTrue(calls.indexOf("isAllowedWriter(uid)") < calls.indexOf("when (method)"))
    }
}
