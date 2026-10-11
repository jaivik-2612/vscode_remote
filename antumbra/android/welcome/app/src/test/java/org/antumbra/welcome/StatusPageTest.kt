// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class StatusPageTest {
    /** The filter's document (antumbra/android/dnsfilter internal/status) with a module part. */
    private val full = """
        {"service":"antumbra-dnsfilter","version":"0.1.0","uptime_seconds":12,
         "queries":1234,"blocked":56,"forwarded":1100,"local":0,"servfail":3,"refused":0,
         "formerr":0,"notimp":0,"rate_limited":0,"dropped":0,"upstream_errors":3,
         "list":{"loaded":true,"version":"2026-10-11","size":195726,"exceptions":12,"sha256":"ab"},
         "upstream":{"address":"127.0.0.1:9053","network":"udp","owner_uid":2950,"state":"ok"},
         "policy":{"blocked_answer":"nxdomain","filter_aaaa":true,"local_names":false},
         "module":{"tor":{"bootstrap":45,"summary":"Loading relay descriptors","network":"enabled"},
                   "firewall":{"state":"live","hash":"0123abcd4567ef89"}}}
    """.trimIndent()

    @Test
    fun parsesFilterCountersAndModuleProgress() {
        val s = StatusPage.parse(full)
        assertNull(s.error)
        val f = s.filter!!
        assertEquals(1234L, f.queries)
        assertEquals(56L, f.blocked)
        assertTrue(f.listLoaded)
        assertEquals(195726L, f.listSize)
        assertEquals("2026-10-11", f.listVersion)
        assertEquals("ok", f.upstreamState)
        val m = s.module!!
        assertEquals(45, m.torBootstrap)
        assertEquals("Loading relay descriptors", m.torSummary)
        assertEquals(true, m.torNetworkEnabled)
        assertEquals("live", m.firewallState)
        assertEquals("0123abcd4567ef89", m.firewallHash)
    }

    @Test
    fun moduleNullOrPartial() {
        val noModule = StatusPage.parse("""{"service":"antumbra-dnsfilter","queries":1,"module":null}""")
        assertNotNull(noModule.filter)
        assertNull(noModule.module)
        val partial = StatusPage.parse("""{"service":"antumbra-dnsfilter","module":{"tor":{"bootstrap":250}}}""")
        assertNull(partial.module!!.torBootstrap)
        assertNull(partial.module.torNetworkEnabled)
        assertFalse(partial.filter!!.listLoaded)
    }

    @Test
    fun refusesOtherDocuments() {
        assertNull(StatusPage.parse("not json").filter)
        assertNull(StatusPage.parse("""{"service":"something-else","queries":1}""").filter)
        assertFalse(AddOnCheck(null, StatusPage.parse("{}")).present)
    }

    @Test
    fun addOnPresenceRule() {
        val answered = StatusPage.parse(full)
        assertTrue(AddOnCheck(null, answered).present)
        assertTrue(AddOnCheck("0123abcd", AddOnStatus(null, null, "refused")).present)
        assertFalse(AddOnCheck(null, AddOnStatus(null, null, "refused")).present)
    }
}
