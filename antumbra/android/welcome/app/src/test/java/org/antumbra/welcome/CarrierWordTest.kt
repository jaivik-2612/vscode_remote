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
 * MOD10's live list: the module's word (exactly its three extras, from root
 * only), and the second PrivilegeSource it makes: a pass refuses the apps
 * the person installed that it names, and never a system app, Welcome or
 * the default phone or SMS app.
 */
class CarrierWordTest {
    private val self = "org.antumbra.welcome"
    private val roles = RoleHolders(dialer = "x.dialer", sms = "x.sms")

    private fun values(v: Any? = 1, packages: Any? = "x.simapp", at: Any? = 1234L) =
        mapOf("v" to v, "packages" to packages, "at" to at)

    private fun app(pkg: String, system: Boolean = false) =
        InstalledApp(pkg, system, listOf(pkg.toByteArray()), (AppRules.LOCATION + AppRules.PHONE).toSet())

    private val apps = listOf(
        app("android.system.phone", system = true), app("android.system.ims", system = true), app(self),
        app("x.dialer"), app("x.sms"), app("x.simapp"), app("x.esimapp"), app("x.other"),
    )

    @Test
    fun aWellFormedWord() {
        assertEquals(CarrierWord(setOf("x.simapp"), 1234), CarrierWord.parse(values()))
        assertEquals(CarrierWord(emptySet(), 0), CarrierWord.parse(values(packages = "", at = 0L)))
        assertEquals(setOf("a.b", "c.d_e9", "android"), CarrierWord.parse(values(packages = "a.b,c.d_e9,android"))?.packages)
        val max = (1..CarrierWord.MAX).joinToString(",") { "x.p$it" }
        assertEquals(CarrierWord.MAX, CarrierWord.parse(values(packages = max))?.packages?.size)
        assertEquals("module_carrier", CarrierWord.METHOD)
    }

    @Test
    fun anythingElseIsMalformed() {
        listOf(
            values(v = 2), values(v = 1L), values(v = "1"), values(v = null),
            values(packages = null), values(packages = 1), values(packages = "x.a,"), values(packages = ",x.a"),
            values(packages = "x.a,,x.b"), values(packages = "1x"), values(packages = "x.1"), values(packages = "x a"),
            values(packages = "x/a"), values(packages = "x.a "), values(packages = "x..a"), values(packages = "x.a."),
            values(packages = "***"), values(packages = (0..CarrierWord.MAX).joinToString(",") { "x.p$it" }),
            values(at = 1), values(at = -1L), values(at = "1"), values(at = null),
            values() + ("extra" to "x"), mapOf("v" to 1, "packages" to "x.a"), emptyMap(),
        ).forEach { assertNull(it.toString(), CarrierWord.parse(it)) }
    }

    @Test
    fun onlyRootMayGiveItAndNothingIsReadBefore() {
        for (uid in listOf(2000, 1000, 1001, 10123, 1002000, 2950, 2951, -1)) {
            var read = false
            assertThrows(SecurityException::class.java) {
                ModuleCalls.receive(uid, CarrierWord.METHOD, null, { read = true; values() }, { error("word") }, { error("carrier") }) { error("cell") }
            }
            assertFalse("uid $uid", read)
            assertThrows(SecurityException::class.java) {
                CarrierWord.receive(uid, CarrierWord.METHOD, null, { read = true; values() }) { error("carrier") }
            }
            assertFalse("uid $uid", read)
        }
    }

    @Test
    fun rootGivesItAndAMalformedOneChangesNothing() {
        var got: CarrierWord? = null
        ModuleCalls.receive(0, CarrierWord.METHOD, null, { values(packages = "x.simapp,x.esimapp") }, { error("word") }, { got = it }) { error("cell") }
        assertEquals(setOf("x.simapp", "x.esimapp"), got?.packages)
        // Malformed: refused (the module sees it was not taken), and nothing taken: the list held stays.
        assertThrows(IllegalArgumentException::class.java) {
            ModuleCalls.receive(0, CarrierWord.METHOD, null, { values(packages = "x.a,,") }, { error("word") }, { got = null }) { error("cell") }
        }
        assertEquals(setOf("x.simapp", "x.esimapp"), got?.packages)
        assertThrows(IllegalArgumentException::class.java) {
            ModuleCalls.receive(0, CarrierWord.METHOD, "x", { values() }, { error("word") }, { got = null }) { error("cell") }
        }
        assertEquals(setOf("x.simapp", "x.esimapp"), got?.packages)
        // The other words do not reach it, nor it them.
        var cell: CellWord? = null
        ModuleCalls.receive(
            0, CellWord.METHOD, null,
            { mapOf("v" to 1, "gate" to "phone", "cell" to "none", "radio" to "off", "at" to 5L) },
            { error("word") }, { error("carrier") },
        ) { cell = it }
        assertEquals(CellLevel.PHONE, cell?.gate)
    }

    @Test
    fun theListHeldTellsWhenItChanged() {
        // The process's own list (only this test touches it): none at the start.
        assertEquals(emptySet<String>(), LiveList.privileged(apps))
        assertFalse(LiveList.take(CarrierWord(emptySet(), 1)))
        assertTrue(LiveList.take(CarrierWord(setOf("x.simapp", "x.notinstalled"), 2)))
        assertEquals(setOf("x.simapp"), LiveList.privileged(apps))
        assertFalse(LiveList.take(CarrierWord(setOf("x.notinstalled", "x.simapp"), 3)))
        assertTrue(LiveList.take(CarrierWord(emptySet(), 4)))
        assertEquals(emptySet<String>(), LiveList.privileged(apps))
        // A change brings a pass over every app; the same list brings none.
        assertTrue(SourceScan.code("CarrierWord.kt").contains("if (take(w) && context != null) AppPolicies.request(context, \"carrier privileges\")"))
        assertTrue(SourceScan.code("StateProvider.kt").contains("CallWatch::take, { LiveList.takeFrom(context, it) }, CellWatch::take"))
    }

    /** A live-list app the person installed is refused (hidden, its data kept), whatever else it was chosen for. */
    @Test
    fun anAppOnTheLiveListIsRefused() {
        val word = CarrierWord.parse(values(packages = "x.simapp,x.esimapp,x.notinstalled"))
        val privileged = LiveListRules.privileged(word, apps)
        assertEquals(setOf("x.simapp", "x.esimapp"), privileged)
        val plan = AppRules.plan(apps, self, mapOf("x.simapp" to Precision.PRECISE), roles, privileged)
        assertEquals(listOf("x.simapp", "x.esimapp"), plan.refuse)
        // Refused: no location even though it was chosen.
        assertTrue(plan.steps.none { it.pkg == "x.simapp" && it.grant == Grant.GRANTED })
        // Without a word, the live list names nothing.
        assertEquals(emptySet<String>(), LiveListRules.privileged(null, apps))
        assertEquals(emptyList<String>(), AppRules.plan(apps, self, null, roles, LiveListRules.privileged(null, apps)).refuse)
        // With the carrier configuration's source, the union: each refuses what it names.
        val config = CarrierConfigRules(emptyList()).privileged(apps)
        assertEquals(listOf("x.simapp", "x.esimapp"), AppRules.plan(apps, self, null, roles, config + privileged).refuse)
    }

    /** Never a system app, Welcome itself, or the default phone or SMS app, whatever the list names. */
    @Test
    fun theLiveListNeverRefusesSystemAppsWelcomeOrTheDefaultApps() {
        val word = CarrierWord.parse(
            values(packages = "android.system.phone,android.system.ims,org.antumbra.welcome,x.dialer,x.sms,x.other"),
        )
        val privileged = LiveListRules.privileged(word, apps)
        assertEquals(6, privileged.size)
        val plan = AppRules.plan(apps, self, null, roles, privileged)
        assertEquals(listOf("x.other"), plan.refuse)
        for (pkg in listOf("android.system.phone", "android.system.ims", self, "x.dialer", "x.sms")) {
            assertFalse(pkg, pkg in plan.refuse)
            assertTrue(pkg, plan.steps.none { it.pkg == pkg })
        }
        // The default phone or SMS app unreadable: nothing refused at all (calls come first).
        assertEquals(emptyList<String>(), AppRules.plan(apps, self, null, roles = null, privileged = privileged).refuse)
        // A pass over one package just installed refuses it as a pass over every app would.
        assertEquals(listOf("x.other"), AppRules.plan(apps.filter { it.pkg == "x.other" }, self, null, roles, privileged).refuse)
        assertEquals(emptyList<String>(), AppRules.plan(apps.filter { it.pkg == "android.system.ims" }, self, null, roles, privileged).refuse)
    }

    /** The list stays in memory: never logged, written or handed out; the pass's log counts only. */
    @Test
    fun theListIsKeptInMemoryOnly() {
        val src = File("src/main/java/org/antumbra/welcome/CarrierWord.kt").readText()
        listOf("Log.", "FileOutputStream", "writeText", "openFileOutput", "SharedPreferences", "setprop", "Settings.Global.put")
            .forEach { assertFalse(it, src.contains(it)) }
        val pass = SourceScan.function(SourceScan.code("AppPolicies.kt"), "pass(")
        // Only how many of the refused the module's list named: not how many it names.
        assertTrue(pass.contains("val byLiveList = plan.refuse.count { it in live }"))
        assertTrue(pass.contains("(\$byLiveList of them by the module's list)"))
        assertFalse(pass.contains("live.size"))
        listOf("\${live}", "\$live ", "live.joinToString", "\${privileged}", "\${plan.refuse}").forEach { assertFalse(it, pass.contains(it)) }
        // The provider dispatches the three words after the uid check, in one place.
        val calls = File("src/main/java/org/antumbra/welcome/CellWord.kt").readText().let { it.substring(it.indexOf("object ModuleCalls")) }
        assertTrue(calls.indexOf("isAllowedWriter(uid)") < calls.indexOf("CarrierWord.METHOD -> CarrierWord.receive(uid, method, arg, values, carrier)"))
    }
}
