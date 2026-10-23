// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class StateRowTest {

    @Test
    fun columnsMatchTheSharedContract() {
        assertEquals(
            listOf("started", "tor_mode", "bridges", "mac", "admin", "unsafe_browser", "persistent", "session_id", "cell"),
            StateRow.COLUMNS,
        )
        assertEquals("org.antumbra.welcome.state", StateRow.AUTHORITY)
        assertEquals("session", StateRow.PATH)
    }

    @Test
    fun onlyRootAndShellMayRead() {
        assertTrue(StateRow.isAllowedCaller(0))
        assertTrue(StateRow.isAllowedCaller(2000))
        // system, an app, the shell uid of another user, tor's and the filter's uids
        listOf(1000, 10123, 1002000, 2950, 2951, -1).forEach { assertFalse("uid $it", StateRow.isAllowedCaller(it)) }
    }

    @Test
    fun beforeStartEveryValueIsTheSafeOne() {
        val v = StateRow.values(Session.notStarted)
        assertEquals(0, v["started"])
        assertEquals("offline", v["tor_mode"])
        assertEquals("", v["bridges"])
        assertEquals("new", v["mac"])
        assertEquals(0, v["admin"])
        assertEquals(0, v["unsafe_browser"])
        assertEquals(0, v["persistent"])
        assertTrue(Regex("[0-9a-f]{32}").matches(v["session_id"] as String))
        // WEL8: the cell radio off before Start.
        assertEquals("off", v["cell"])
    }

    @Test
    fun startedRowCarriesTheChoicesWithBridgesOnePerLine() {
        val s = SessionState(
            started = true, internet = Internet.MOBILE, torMode = TorMode.BRIDGES,
            bridges = listOf("192.0.2.1:443", "192.0.2.2:443"),
            newMac = false, admin = true, unsafeBrowser = true, persistent = false, sessionId = "abc", cell = CellLevel.DATA,
        )
        val v = StateRow.values(s)
        assertEquals(1, v["started"])
        assertEquals("bridges", v["tor_mode"])
        assertEquals("192.0.2.1:443\n192.0.2.2:443", v["bridges"])
        assertEquals("keep", v["mac"])
        assertEquals(1, v["admin"])
        assertEquals(1, v["unsafe_browser"])
        assertEquals(0, v["persistent"])
        assertEquals("abc", v["session_id"])
        assertEquals("data", v["cell"])
        assertEquals(StateRow.COLUMNS.toSet(), v.keys)
    }

    @Test
    fun projectionIsCheckedAndKeepsItsOrder() {
        assertEquals(StateRow.COLUMNS, StateRow.columns(null))
        assertEquals(listOf("bridges", "started"), StateRow.columns(arrayOf("bridges", "started")))
        // The module's projection since WEL8 (session_read).
        assertEquals(
            listOf("started", "tor_mode", "mac", "session_id", "cell"),
            StateRow.columns(arrayOf("started", "tor_mode", "mac", "session_id", "cell")),
        )
        assertThrows(IllegalArgumentException::class.java) { StateRow.columns(arrayOf("started", "secret")) }
        assertThrows(IllegalArgumentException::class.java) { StateRow.columns(emptyArray()) }
    }

    @Test
    fun sessionStartsOnceAndBridgesOnlyInBridgeMode() {
        // Session is a process-wide object; this is the only test that starts it.
        val choices = Choices(internet = Internet.WIFI, torMode = TorMode.DIRECT, newMac = true).withPhone(true)
        assertTrue(Session.start(choices, listOf("192.0.2.1:443")))
        val s = Session.current()
        assertTrue(s.started)
        assertEquals(TorMode.DIRECT, s.torMode)
        assertEquals(Internet.WIFI, s.internet)
        assertEquals(CellLevel.PHONE, s.cell)
        assertEquals("phone", StateRow.values(s)["cell"])
        assertEquals(emptyList<String>(), s.bridges)
        assertFalse(Session.start(Choices(internet = Internet.NONE), emptyList()))
        assertEquals(TorMode.DIRECT, Session.current().torMode)
        assertEquals(CellLevel.PHONE, Session.current().cell)
    }
}
