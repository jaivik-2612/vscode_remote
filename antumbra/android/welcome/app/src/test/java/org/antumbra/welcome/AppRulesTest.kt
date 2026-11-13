// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import java.security.MessageDigest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL9's rules without Android: who gets location (only the chosen apps,
 * as chosen, never in the background), phone state denied without an
 * opt-in, carrier privileges matched as UiccAccessRule matches them, and
 * what is never touched (system apps, Welcome, the default phone and SMS
 * apps, every call and SMS permission). Then source scans of AppPolicies:
 * its triggers, its boot path, and that nothing names a chosen app.
 */
class AppRulesTest {
    private val self = "org.antumbra.welcome"
    private val all = AppRules.LOCATION + AppRules.PHONE + listOf(
        "android.permission.CALL_PHONE", "android.permission.SEND_SMS", "android.permission.RECEIVE_SMS",
        "android.permission.READ_SMS", "android.permission.ANSWER_PHONE_CALLS", "android.permission.READ_CALL_LOG",
        "android.permission.POST_NOTIFICATIONS", "android.permission.CAMERA",
    )

    private fun app(pkg: String, system: Boolean = false, certs: List<ByteArray> = listOf(pkg.toByteArray()), requested: Collection<String> = all) =
        InstalledApp(pkg, system, certs, requested.toSet())

    private val roles = RoleHolders(dialer = "x.dialer", sms = "x.sms")
    private val apps = listOf(
        app("android.system.dialer", system = true), app("android.system.gnss", system = true), app(self),
        app("x.dialer"), app("x.sms"), app("x.precise"), app("x.approximate"), app("x.other"),
    )
    private val chosen = mapOf("x.precise" to Precision.PRECISE, "x.approximate" to Precision.APPROXIMATE)

    private fun AppPlan.of(pkg: String): Map<String, Grant> = steps.filter { it.pkg == pkg }.associate { it.permission to it.grant }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun sha256(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b)
    private fun sha1(b: ByteArray) = MessageDigest.getInstance("SHA-1").digest(b)

    private val denied = mapOf(
        AppRules.COARSE to Grant.DENIED, AppRules.FINE to Grant.DENIED, AppRules.BACKGROUND to Grant.DENIED,
        AppRules.PHONE_STATE to Grant.DENIED, AppRules.PHONE_NUMBERS to Grant.DENIED,
    )

    @Test
    fun onlyTheChosenAppsGetLocationAsChosen() {
        // Before Start (or without a session): no app gets location.
        val before = AppRules.plan(apps, self, chosen = null, roles = roles, privileged = emptySet())
        for (pkg in listOf("x.precise", "x.approximate", "x.other")) assertEquals(pkg, denied, before.of(pkg))
        assertTrue(before.steps.none { it.grant == Grant.GRANTED })
        // In the session: precise gets coarse and fine, approximate coarse only, never background; every other app nothing.
        val session = AppRules.plan(apps, self, chosen, roles, emptySet())
        assertEquals(denied + mapOf(AppRules.COARSE to Grant.GRANTED, AppRules.FINE to Grant.GRANTED), session.of("x.precise"))
        assertEquals(denied + mapOf(AppRules.COARSE to Grant.GRANTED), session.of("x.approximate"))
        assertEquals(denied, session.of("x.other"))
        assertTrue(session.steps.none { it.permission == AppRules.BACKGROUND && it.grant == Grant.GRANTED })
        // A choice naming an app that is not installed changes nothing.
        assertEquals(session.steps, AppRules.plan(apps, self, chosen + ("x.gone" to Precision.PRECISE), roles, emptySet()).steps)
        // Each app's denials come before its grants.
        for (pkg in chosen.keys) {
            val grants = session.steps.filter { it.pkg == pkg }.map { it.grant }
            assertEquals(grants.sortedBy { it != Grant.DENIED }, grants)
        }
    }

    @Test
    fun onlyRequestedPermissionsAreSet() {
        val coarseOnly = listOf(app("x.coarse", requested = listOf(AppRules.COARSE)), app("x.none", requested = emptyList()))
        val plan = AppRules.plan(coarseOnly, self, mapOf("x.coarse" to Precision.PRECISE), roles, emptySet())
        assertEquals(listOf(GrantStep("x.coarse", AppRules.COARSE, Grant.GRANTED)), plan.steps)
    }

    /** Emergency safety: system apps, Welcome and the default phone and SMS apps are never named, refused or not. */
    @Test
    fun systemAppsWelcomeAndTheDefaultAppsAreNeverTouched() {
        val untouchable = setOf("android.system.dialer", "android.system.gnss", self, "x.dialer", "x.sms")
        val everyone = apps.map { it.pkg }.toSet()
        for (c in listOf(null, chosen, everyone.associateWith { Precision.PRECISE })) {
            val plan = AppRules.plan(apps, self, c, roles, privileged = everyone)
            assertTrue(plan.steps.none { it.pkg in untouchable })
            assertTrue(plan.refuse.none { it in untouchable })
            assertEquals(setOf("x.precise", "x.approximate", "x.other"), plan.refuse.toSet())
        }
        assertTrue(apps.filter { it.pkg in untouchable }.all { AppRules.leftAlone(it, self, roles) })
        assertFalse(AppRules.leftAlone(app("x.other"), self, roles))
        // Shutdown never names Welcome either.
        assertTrue(AppRules.atShutdown(mapOf(self to Precision.PRECISE, "x.a" to Precision.APPROXIMATE), self).none { it.pkg == self })
    }

    /** Phone state is denied to every other app, and granted to none: the opt-in waits for AM4 and PH3. */
    @Test
    fun phoneStateIsDeniedWithoutAnOptIn() {
        val plan = AppRules.plan(apps, self, chosen, roles, emptySet())
        for (pkg in listOf("x.precise", "x.approximate", "x.other")) {
            for (p in AppRules.PHONE) assertEquals("$pkg $p", Grant.DENIED, plan.of(pkg)[p])
        }
        assertTrue(plan.steps.none { it.permission in AppRules.PHONE && it.grant == Grant.GRANTED })
        // An app opted in is left as it is: nothing set, nothing granted.
        val optIn = AppRules.plan(apps, self, chosen, roles, emptySet(), phoneStateApps = setOf("x.other"))
        assertTrue(optIn.steps.none { it.pkg == "x.other" && it.permission in AppRules.PHONE })
        assertEquals(denied.filterKeys { it in AppRules.LOCATION }, optIn.of("x.other"))
    }

    /** No call or SMS permission, nor any other, is ever set in any app, whatever the inputs. */
    @Test
    fun onlyLocationAndPhoneStateAreEverSet() {
        val allowed = (AppRules.LOCATION + AppRules.PHONE).toSet()
        assertEquals(
            setOf(
                "android.permission.ACCESS_COARSE_LOCATION", "android.permission.ACCESS_FINE_LOCATION",
                "android.permission.ACCESS_BACKGROUND_LOCATION", "android.permission.READ_PHONE_STATE",
                "android.permission.READ_PHONE_NUMBERS",
            ),
            allowed,
        )
        for (r in listOf(roles, null)) {
            for (c in listOf(null, chosen)) {
                val plan = AppRules.plan(apps, self, c, r, apps.map { it.pkg }.toSet())
                assertTrue(plan.steps.all { it.permission in allowed })
            }
        }
        assertTrue(AppRules.atShutdown(chosen, self).all { it.permission in AppRules.LOCATION && it.grant == Grant.DENIED })
    }

    /** The default phone or SMS app cannot be read: no phone state and no refusal this pass (calls come first); location still goes. */
    @Test
    fun withoutTheDefaultAppsNoPhoneStateAndNoRefusal() {
        val plan = AppRules.plan(apps, self, chosen, roles = null, privileged = apps.map { it.pkg }.toSet())
        assertTrue(plan.rolesUnknown)
        assertTrue(plan.steps.none { it.permission in AppRules.PHONE })
        assertTrue(plan.refuse.isEmpty())
        assertEquals(Grant.GRANTED, plan.of("x.precise")[AppRules.FINE])
        assertEquals(Grant.DENIED, plan.of("x.other")[AppRules.COARSE])
        assertFalse(AppRules.plan(apps, self, chosen, roles, emptySet()).rolesUnknown)
    }

    /** An app with carrier privileges is refused, and gets no location even if it was chosen. */
    @Test
    fun aPrivilegedAppIsRefusedAndGetsNoLocation() {
        val plan = AppRules.plan(apps, self, chosen, roles, privileged = setOf("x.precise"))
        assertEquals(listOf("x.precise"), plan.refuse)
        assertEquals(denied, plan.of("x.precise"))
    }

    /** At shutdown the chosen apps' location is denied again: Android's stored grants keep no trace of the choice. */
    @Test
    fun shutdownDeniesTheChosenAppsAgain() {
        val steps = AppRules.atShutdown(chosen, self)
        for (pkg in chosen.keys) {
            for (p in AppRules.LOCATION) assertTrue("$pkg $p", GrantStep(pkg, p, Grant.DENIED) in steps)
        }
        assertTrue(steps.all { it.grant == Grant.DENIED && it.pkg in chosen.keys })
        assertEquals(emptyList<GrantStep>(), AppRules.atShutdown(emptyMap(), self))
        // After it, the session's grants and the plan before Start leave the same state for every app.
        val session = AppRules.plan(apps, self, chosen, roles, emptySet())
        val after = session.steps.associate { (it.pkg to it.permission) to it.grant }.toMutableMap()
        for (s in steps) after[s.pkg to s.permission] = s.grant
        val before = AppRules.plan(apps, self, null, roles, emptySet()).steps.associate { (it.pkg to it.permission) to it.grant }
        assertEquals(before, after)
    }

    @Test
    fun theCarrierCertificateListAsUiccAccessRuleDecodesIt() {
        val cert = "a probe's certificate".toByteArray()
        val h256 = hex(sha256(cert))
        val h1 = hex(sha1(cert))
        val probe = app("x.probe", certs = listOf("another".toByteArray(), cert))
        val other = app("x.other", certs = listOf(cert))
        fun refused(vararg entries: String) = CarrierRules.privilegedBy(entries.toList(), listOf(probe, other))
        // A hash alone: any package with the certificate, SHA-256 or SHA-1, in either case.
        assertEquals(setOf("x.probe", "x.other"), refused(h256))
        assertEquals(setOf("x.probe", "x.other"), refused(h256.uppercase()))
        assertEquals(setOf("x.probe", "x.other"), refused(h1))
        // Bound to packages: those only.
        assertEquals(setOf("x.probe"), refused("$h256:x.probe"))
        assertEquals(setOf("x.probe", "x.other"), refused("$h256:x.probe,x.other"))
        assertEquals(setOf("x.other"), refused("$h1:x.nothing,x.other"))
        assertEquals(emptySet<String>(), refused("$h256:x.nothing"))
        // Java's split: "hash:" is the hash alone; an empty name in a list is any package; "hash:," names nothing.
        assertEquals(setOf("x.probe", "x.other"), refused("$h256:"))
        assertEquals(setOf("x.probe", "x.other"), refused("$h256:x.nothing,,x.none"))
        assertEquals(emptySet<String>(), refused("$h256:,"))
        assertEquals(emptyList<String>(), CarrierRules.javaSplit(":", ':'))
        assertEquals(listOf(""), CarrierRules.javaSplit("", ':'))
        assertEquals(listOf("", "a"), CarrierRules.javaSplit(":a", ':'))
        assertEquals(listOf("a", "b"), CarrierRules.javaSplit("a:b::", ':'))
        // Only the part before the second ':' names packages, as String.split(":")[1].
        assertEquals(setOf("x.probe"), refused("$h256:x.probe:x.other"))
        // The SHA-1 is compared only with a 20-byte hash; another certificate's hash matches nothing.
        assertEquals(emptySet<String>(), refused(hex(sha256("x".toByteArray()))))
        assertEquals(emptySet<String>(), refused(h1 + "00"))
        // One entry Android cannot decode (IccUtils throws, nothing catches it) drops the slot's whole list.
        for (bad in listOf(h256.dropLast(1), "zz" + h256.drop(2), " $h256", "not hex", ":", "::", "$h256 ")) {
            assertEquals(bad, emptySet<String>(), refused(bad, h256))
            assertEquals(bad, emptySet<String>(), refused(h256, bad))
            assertNull(bad, CarrierRules.decode(listOf(h256, bad)))
        }
        // An empty entry, or an empty hash before ':', decodes (an empty hash, which matches nothing), so it drops nothing.
        assertEquals(setOf("x.probe", "x.other"), refused("", h256))
        assertEquals(setOf("x.probe", "x.other"), refused(":x.probe", h256))
        // Only a carrier's own configuration counts (isConfigForIdentifiedCarrier), and each slot's list stands alone.
        val apps2 = listOf(probe, other)
        assertEquals(emptySet<String>(), CarrierRules.privileged(listOf(SlotConfig(identified = false, entries = listOf(h256))), apps2))
        assertEquals(setOf("x.probe"), CarrierRules.privileged(
            listOf(SlotConfig(false, listOf(h256)), SlotConfig(true, listOf("$h256:x.probe")), SlotConfig(true, listOf(h256, "zz"))), apps2))
        assertEquals(emptySet<String>(), CarrierRules.privileged(listOf(SlotConfig(true, null)), apps2))
        assertNull(CarrierRules.hex("abc"))
        assertNull(CarrierRules.hex("0g"))
        assertNull(CarrierRules.hex("٠١"))
        assertEquals("00ff7f", hex(CarrierRules.hex("00FF7f")!!))
        assertEquals(emptySet<String>(), CarrierRules.privilegedBy(null, listOf(probe)))
        // Through the source the plan uses.
        val source: PrivilegeSource = CarrierConfigRules(listOf(SlotConfig(identified = true, entries = listOf("$h256:x.probe"))))
        val plan = AppRules.plan(listOf(probe, other), self, null, roles, source.privileged(listOf(probe, other))!!)
        assertEquals(listOf("x.probe"), plan.refuse)
    }

    @Test
    fun theWelcomeScreenOffersTheAppsAPassMayGrant() {
        val list = listOf(
            InstalledApp("x.b", false, requested = setOf(AppRules.COARSE), label = "beta"),
            InstalledApp("x.a", false, requested = setOf(AppRules.FINE, AppRules.COARSE), label = "Alpha"),
            InstalledApp("x.none", false, requested = setOf(AppRules.PHONE_STATE), label = "None"),
            InstalledApp("x.sys", true, requested = setOf(AppRules.COARSE), label = "System"),
            InstalledApp("x.sms", false, requested = setOf(AppRules.COARSE), label = "Messages"),
            InstalledApp(self, false, requested = setOf(AppRules.FINE), label = "Antumbra"),
        )
        assertEquals(listOf(LocationApp("x.a", "Alpha"), LocationApp("x.b", "beta")), AppRules.offered(list, self, roles))
        // An app that asks for fine location alone (written for Android 11 or earlier) is offered precise only.
        val fineOnly = AppRules.offered(listOf(InstalledApp("x.f", false, requested = setOf(AppRules.FINE), label = "Fine")), self, roles).single()
        assertTrue(fineOnly.fineOnly)
        assertEquals(listOf(Precision.PRECISE), fineOnly.precisions)
        assertEquals(listOf(Precision.APPROXIMATE, Precision.PRECISE), LocationApp("x.a", "Alpha").precisions)
        assertEquals(mapOf("x.f" to Precision.PRECISE), Choices().withLocationApp("x.f", true, first = fineOnly.precisions.first()).locationApps)
        // Approximate would give it nothing: no step grants it anything then, precise grants fine.
        val f = InstalledApp("x.f", false, requested = setOf(AppRules.FINE))
        assertTrue(AppRules.plan(listOf(f), self, mapOf("x.f" to Precision.APPROXIMATE), roles, emptySet()).steps.none { it.grant == Grant.GRANTED })
        assertEquals(listOf(GrantStep("x.f", AppRules.FINE, Grant.GRANTED)), AppRules.plan(listOf(f), self, mapOf("x.f" to Precision.PRECISE), roles, emptySet()).steps)
        // The screen offers both rows only where both apply.
        val screen = SourceScan.code("ui/WelcomeScreen.kt")
        assertTrue(screen.contains("if (Precision.APPROXIMATE in app.precisions) {"))
        assertTrue(screen.contains("c.withLocationApp(app.pkg, it, first = app.precisions.first())"))
        // Ticked approximate by default; precise only when chosen; nothing counts with Location off.
        val c = Choices().withLocationApp("x.a", true)
        assertEquals(mapOf("x.a" to Precision.APPROXIMATE), c.locationApps)
        assertEquals(emptyMap<String, Precision>(), c.chosenLocationApps)
        val on = c.copy(location = true).withPrecision("x.a", Precision.PRECISE).withPrecision("x.b", Precision.PRECISE)
        assertEquals(mapOf("x.a" to Precision.PRECISE), on.chosenLocationApps)
        assertEquals(mapOf("x.a" to Precision.PRECISE), on.withLocationApp("x.a", true).locationApps)
        assertEquals(emptyMap<String, Precision>(), on.withLocationApp("x.a", false).chosenLocationApps)
        assertFalse(Choices().location)
    }

    /**
     * The decision on the default apps: Welcome lifts only its own
     * phone-state block on the current default phone and SMS apps, back to
     * Android's default, and only where it reads DENIED; never to granted,
     * never another permission, never a system app or Welcome. A former
     * default is denied again on the next pass.
     */
    @Test
    fun welcomeLiftsOnlyItsOwnBlockOnTheCurrentDefaultApps() {
        val plan = AppRules.plan(apps, self, chosen, roles, emptySet())
        assertEquals(
            setOf(Lift("x.dialer", AppRules.PHONE_STATE), Lift("x.dialer", AppRules.PHONE_NUMBERS),
                Lift("x.sms", AppRules.PHONE_STATE), Lift("x.sms", AppRules.PHONE_NUMBERS)),
            plan.lifts.toSet(),
        )
        assertTrue(plan.lifts.all { it.permission in AppRules.PHONE })
        // Only from DENIED: never from GRANTED or DEFAULT.
        for (state in PolicyState.entries) {
            val todo = AppRules.liftsToApply(plan.lifts) { state }
            assertEquals(state.name, if (state == PolicyState.DENIED) plan.lifts else emptyList<Lift>(), todo)
        }
        val mixed = AppRules.liftsToApply(plan.lifts) { if (it.pkg == "x.sms" && it.permission == AppRules.PHONE_STATE) PolicyState.DENIED else PolicyState.GRANTED }
        assertEquals(listOf(Lift("x.sms", AppRules.PHONE_STATE)), mixed)
        // A system default app or Welcome as a default: nothing lifted; nor when the defaults cannot be read.
        val systemRoles = RoleHolders(dialer = "android.system.dialer", sms = self)
        assertTrue(AppRules.plan(apps, self, chosen, systemRoles, emptySet()).lifts.isEmpty())
        assertTrue(AppRules.plan(apps, self, chosen, null, emptySet()).lifts.isEmpty())
        // Only what the app asks for.
        val asks = listOf(app("x.sms", requested = listOf(AppRules.PHONE_STATE)))
        assertEquals(listOf(Lift("x.sms", AppRules.PHONE_STATE)), AppRules.plan(asks, self, null, roles, emptySet()).lifts)
        // The defaults change: the former SMS app is denied again, the new one lifted.
        val next = AppRules.plan(apps, self, chosen, RoleHolders(dialer = "x.dialer", sms = "x.other"), emptySet())
        assertEquals(Grant.DENIED, next.of("x.sms")[AppRules.PHONE_STATE])
        assertEquals(Grant.DENIED, next.of("x.sms")[AppRules.PHONE_NUMBERS])
        assertTrue(next.lifts.any { it.pkg == "x.other" } && next.lifts.none { it.pkg == "x.sms" })
        // Applied with DEFAULT, after reading DENIED, and nowhere else.
        val pass = SourceScan.function(policies, "pass(")
        assertTrue(pass.contains("val lifts = AppRules.liftsToApply(plan.lifts) { policyState(dpm, admin, it) }"))
        assertTrue(pass.contains("dpm.setPermissionGrantState(admin, l.pkg, l.permission, DevicePolicyManager.PERMISSION_GRANT_STATE_DEFAULT)"))
        assertEquals(1, Regex("PERMISSION_GRANT_STATE_DEFAULT").findAll(policies).count())
        assertTrue(SourceScan.function(policies, "policyState(").contains("DevicePolicyManager.PERMISSION_GRANT_STATE_DENIED -> PolicyState.DENIED"))
        // A change of default app brings a pass: the screens' polls, and Telecom's broadcast for the phone app.
        for (f in listOf("WelcomeActivity.kt", "StatusActivity.kt")) assertTrue(f, SourceScan.code(f).contains("AppWatch.rolesLook(this@"))
        assertTrue(policies.contains("IntentFilter(TelecomManager.ACTION_DEFAULT_DIALER_CHANGED)"))
        assertTrue(SourceScan.function(policies, "rolesLook(").contains("AppPolicies.request(context, \"default apps\")"))
        assertTrue(AppRules.due(null, 0, 30_000) && !AppRules.due(1_000, 30_999, 30_000) && AppRules.due(1_000, 31_000, 30_000))
    }

    /** A new install: its own pass first (location, phone state, carrier privileges), the same steps as in a pass over every app. */
    @Test
    fun aNewInstallIsDeniedAloneFirst() {
        val privileged = setOf("x.other")
        val all = AppRules.plan(apps, self, chosen, roles, privileged)
        for (a in apps) {
            val one = AppRules.plan(listOf(a), self, chosen, roles, privileged)
            assertEquals(a.pkg, all.steps.filter { it.pkg == a.pkg }, one.steps)
            assertEquals(a.pkg, all.refuse.filter { it == a.pkg }, one.refuse)
        }
        val receiver = policies.substring(policies.indexOf("Intent.ACTION_PACKAGE_ADDED, Intent.ACTION_PACKAGE_REPLACED -> {"))
        val first = receiver.indexOf("intent.data?.schemeSpecificPart?.let { AppPolicies.requestPackage(context, it) }")
        assertTrue(first > 0)
        assertTrue(first < receiver.indexOf("AppPolicies.request(context, \"install\")"))
        val request = SourceScan.function(policies, "requestPackage(")
        assertTrue(request.contains("pass(app, \"install\", pkg)"))
        assertTrue(SourceScan.function(policies, "pass(").contains("if (only == null) installedApps(context) else listOfNotNull(installedApp(context, only))"))
    }

    /** Shutdown against a pass still running: once the gate is closed no grant runs; denials never wait on it. */
    @Test
    fun noGrantLandsAfterShutdownCloses() {
        val gate = GrantGate()
        var grants = 0
        assertTrue(gate.grant { grants++; true })
        assertFalse(gate.isClosed())
        gate.close()
        assertTrue(gate.isClosed())
        assertFalse(gate.grant { grants++; true })
        assertEquals(1, grants)
        // The pass grants only through the gate; shutdown closes it before its denials, on the same thread.
        val pass = SourceScan.function(policies, "pass(")
        assertTrue(pass.contains("if (s.grant == Grant.GRANTED) gate.grant { setGrant(dpm, admin, s) } else setGrant(dpm, admin, s)"))
        val shutdown = SourceScan.function(policies, "atShutdown(")
        assertTrue(shutdown.indexOf("gate.close()") in 0 until shutdown.indexOf("for (s in steps) if (setGrant(dpm, admin, s))"))
        assertTrue(shutdown.contains(".join(SHUTDOWN_WAIT_MS)"))
        // Shutdown's steps are denials only, so the gate never holds them back.
        assertTrue(AppRules.atShutdown(chosen, self).all { it.grant == Grant.DENIED })
        // And they come last at shutdown, after Wi-Fi's steps (the broadcast has 10 s in all).
        val boot = SourceScan.function(SourceScan.code("Receivers.kt"), "atShutdown(")
        assertTrue(boot.indexOf("policies.forgetWifiNetworks()") in 0 until boot.indexOf("policies.appsAtShutdown()"))
        assertTrue(boot.indexOf("policies.lockWifiOff()") < boot.indexOf("policies.appsAtShutdown()"))
        assertFalse(SourceScan.function(SourceScan.code("Policies.kt"), "applyBaseline(").contains("AppPolicies.atShutdown"))
    }

    // --- Source scans --------------------------------------------------------

    private val policies = SourceScan.code("AppPolicies.kt")

    /** The plan goes to Android as it is: its grant state, and a refused app hidden, its data kept; never uninstalled. */
    @Test
    fun thePlanIsAppliedAsItIs() {
        val pass = SourceScan.function(policies, "pass(")
        assertTrue(pass.contains("AppRules.plan(apps, context.packageName, chosen, roles, privileged.orEmpty() + live)"))
        // MOD10's live list: the second source, read only when the default apps could be read (calls first).
        assertTrue(pass.contains("val live = if (roles == null) emptySet() else LiveList.privileged(apps)"))
        assertTrue(pass.contains("val chosen = if (started) Session.locationApps() else null"))
        assertTrue(pass.contains("dpm.setApplicationHidden(admin, pkg, true)"))
        val set = SourceScan.function(policies, "setGrant(")
        assertTrue(set.contains("if (s.grant == Grant.GRANTED) DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED else DevicePolicyManager.PERMISSION_GRANT_STATE_DENIED"))
        // The plan's grant states, and the lifts of Welcome's own block (welcomeLiftsOnlyItsOwnBlockOnTheCurrentDefaultApps).
        assertEquals(2, Regex("setPermissionGrantState\\(").findAll(policies).count())
        for (f in SourceScan.sources()) {
            val code = SourceScan.withoutComments(f.readText())
            for (w in listOf("PackageInstaller", "uninstall", "deletePackage", "setPackagesSuspended", "setApplicationHidden(admin, pkg, false)", "clearApplicationUserData")) {
                assertFalse("${f.name}: $w", code.contains(w))
            }
            // The opt-in for SIM-bound messaging apps exists only as the plan's empty default.
            if (f.name != "AppRules.kt") assertFalse(f.name, code.contains("phoneStateApps"))
        }
        // Each step is caught on its own.
        assertTrue(set.contains("} catch (e: Exception) {"))
    }

    /**
     * A receiver for ACTION_CARRIER_CONFIG_CHANGED would never fire: the
     * phone process sends it, and it reaches no unexported receiver. The
     * trigger is CarrierConfigManager's listener, registered from the
     * process's start path (WelcomeApp.onCreate), with the install listener
     * and a pass; this fails if it is not.
     */
    @Test
    fun theTriggersAreRegisteredFromTheProcessStart() {
        val app = SourceScan.code("WelcomeApp.kt")
        assertTrue(app.indexOf("AppWatch.start(this)") > app.indexOf("override fun onCreate()"))
        assertEquals(1, Regex("AppWatch\\.start\\(").findAll(SourceScan.sources().joinToString { SourceScan.withoutComments(it.readText()) }).count())
        // AppWatch is the file's last object; its start registers both listeners (a receiver's onReceive inside it).
        val start = policies.substring(policies.indexOf("fun start(app: Application)"))
        assertTrue(start.contains("?.registerCarrierConfigChangeListener(app.mainExecutor) { _, _, _, _ ->"))
        assertTrue(start.contains("AppPolicies.request(app, \"carrier configuration\")"))
        assertTrue(start.contains("addAction(Intent.ACTION_PACKAGE_ADDED)") && start.contains("addAction(Intent.ACTION_PACKAGE_REPLACED)"))
        assertTrue(start.contains("addDataScheme(\"package\")"))
        assertTrue(start.contains("AppPolicies.request(app, \"process start\")"))
        // No receiver that cannot fire: nothing names the broadcast, in the code or the manifest.
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertFalse(manifest.contains("CARRIER_CONFIG_CHANGED"))
        for (f in SourceScan.sources()) {
            val code = SourceScan.withoutComments(f.readText())
            assertFalse(f.name, code.contains("ACTION_CARRIER_CONFIG_CHANGED") || code.contains("CARRIER_CONFIG_CHANGED"))
            // RoleManager's listener needs OBSERVE_ROLE_HOLDERS: the default apps are read at every pass instead.
            assertFalse(f.name, code.contains("addOnRoleHoldersChangedListener"))
        }
        assertTrue(SourceScan.function(policies, "pass(").contains("val roles = roleHolders(context)"))
        assertTrue(manifest.contains("android.permission.QUERY_ALL_PACKAGES"))
        // Carrier privileges as CarrierPrivilegesTracker has them: a carrier's own configuration only.
        assertTrue(SourceScan.function(policies, "slots(").contains("SlotConfig(CarrierConfigManager.isConfigForIdentifiedCarrier(bundle), bundle.getStringArray(KEY)?.toList())"))
    }

    /** The Welcome screen's list: read only after an install, update, removal or a change of default app; no certificate, no system app's label. */
    @Test
    fun theWelcomeScreensListIsCheap() {
        val offered = SourceScan.function(policies, "offered(")
        assertTrue(offered.contains("PackageManager.PackageInfoFlags.of(LIST_FLAGS.toLong())"))
        assertFalse(offered.contains("FLAGS.toLong()") && !offered.contains("LIST_FLAGS.toLong()"))
        assertTrue(policies.contains("private const val LIST_FLAGS = PackageManager.GET_PERMISSIONS or"))
        assertFalse(Regex("LIST_FLAGS = [^\\n]*\\n[^\\n]*GET_SIGNING_CERTIFICATES").containsMatchIn(policies))
        assertTrue(offered.indexOf(".filter { !isSystem(it) && it.packageName != context.packageName }") in 0 until offered.indexOf("getApplicationLabel"))
        val welcome = SourceScan.code("WelcomeActivity.kt")
        assertTrue(welcome.contains("val apps = if (generation == WelcomeModel.appsGeneration) {"))
        // The poll's, and Start's once (only apps still offered keep their choice).
        assertEquals(2, Regex("AppPolicies\\.offered\\(").findAll(welcome).count())
        assertTrue(SourceScan.function(welcome, "startSession(").contains("AppPolicies.offered(this@WelcomeActivity)"))
        val receiver = policies.substring(policies.indexOf("fun start(app: Application)"))
        assertTrue(receiver.contains("Intent.ACTION_PACKAGE_REMOVED -> changed()"))
        assertTrue(receiver.contains("addAction(Intent.ACTION_PACKAGE_REMOVED)"))
    }

    /**
     * A cut shutdown leaves the chosen grants; the next boot's
     * baseline denies them at LOCKED_BOOT_COMPLETED (Welcome's boot receiver
     * is direct-boot aware), listing every package whether or not it runs in
     * direct boot, and no step throws.
     */
    @Test
    fun theBootPathDeniesAsEarlyAsItCan() {
        val baseline = SourceScan.function(SourceScan.code("Policies.kt"), "applyBaseline(")
        assertTrue(baseline.contains("if (!atShutdown) step(failures, \"apps\") { AppPolicies.request(context, \"baseline\") }"))
        assertTrue(SourceScan.function(SourceScan.code("Policies.kt"), "appsAtShutdown(").contains("check(AppPolicies.atShutdown(context) == 0)"))
        val manifest = File("src/main/AndroidManifest.xml").readText().replace(Regex("\\s+"), " ")
        assertTrue(manifest.contains("android:name=\".BootReceiver\" android:directBootAware=\"true\""))
        assertTrue(manifest.contains("<action android:name=\"android.intent.action.LOCKED_BOOT_COMPLETED\" />"))
        assertTrue(SourceScan.code("Receivers.kt").contains("Intent.ACTION_LOCKED_BOOT_COMPLETED,"))
        assertTrue(Regex("LIST_FLAGS = [^\\n]*PackageManager\\.MATCH_DIRECT_BOOT_AWARE or\\s+PackageManager\\.MATCH_DIRECT_BOOT_UNAWARE").containsMatchIn(policies))
        assertTrue(policies.contains("private const val FLAGS = LIST_FLAGS or PackageManager.GET_SIGNING_CERTIFICATES"))
        val request = SourceScan.function(policies, "request(")
        assertTrue(request.contains("try {\n                pass(app, why, null)\n            } catch (e: Exception) {"))
        assertTrue(SourceScan.function(policies, "requestPackage(").contains("try {\n                pass(app, \"install\", pkg)\n            } catch (e: Exception) {"))
    }

    /** Nothing about which apps were chosen goes to the provider, the status the module reads, or a log. */
    @Test
    fun theChosenAppsGoNowhere() {
        for (f in listOf("StateProvider.kt", "SessionService.kt", "AddOnStatus.kt", "ModuleWord.kt", "CellWord.kt")) {
            val code = SourceScan.code(f)
            assertFalse(f, Regex("locationApps|Precision|AppPolicies|AppRules").containsMatchIn(code))
        }
        // The row's state holds no location choice.
        val session = SourceScan.code("Session.kt")
        val state = session.substring(session.indexOf("data class SessionState("), session.indexOf("object Session {"))
        assertFalse(state.contains("location"))
        // Welcome's log lines name no app: only counts and the pass's reason in what they print.
        var calls = 0
        for (f in listOf("AppPolicies.kt", "AppRules.kt", "Session.kt", "WelcomeActivity.kt", "StatusActivity.kt", "Policies.kt")) {
            val code = SourceScan.code(f)
            Regex("\\bLog\\.[a-z]\\(").findAll(code).forEach {
                val args = SourceScan.arguments(code, it.range.last + 1).replace(Regex("[\\w.]+\\.size\\b"), "N")
                calls++
                assertFalse("$f: $args", Regex("\\bpkg\\b|packageName|\\bchosen\\b|locationApps|\\brefuse\\b|\\bapps\\b|\\bsteps\\b|\\bs\\.").containsMatchIn(args))
            }
        }
        assertTrue(calls >= 8)
        assertTrue(policies.contains("Log.i("))
    }
}
