// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.security.MessageDigest

/** How much of your location a chosen app gets (WEL9): approximate unless you choose precise. */
enum class Precision { APPROXIMATE, PRECISE }

/** One installed package as the rules see it; [AppPolicies] reads it from PackageManager. */
class InstalledApp(
    val pkg: String,
    /** ApplicationInfo.FLAG_SYSTEM (an updated system app included): never touched. */
    val system: Boolean,
    /** Its signing certificates as UiccAccessRule.getSignatures gives them (Signature.toByteArray). */
    val certs: List<ByteArray> = emptyList(),
    /** The permissions it asks for: only those are set. */
    val requested: Set<String> = emptySet(),
    /** Its name in the launcher, for the Welcome screen only. */
    val label: String = pkg,
)

/**
 * An app the Welcome screen offers for location: on screen only.
 * [fineOnly]: it asks for fine location alone (an app written for Android
 * 11 or earlier), so approximate would give it nothing; it is offered
 * precise only, as Android's own dialog does for such apps.
 */
data class LocationApp(val pkg: String, val label: String, val fineOnly: Boolean = false) {
    /** The precisions the screen offers, the default first. */
    val precisions: List<Precision>
        get() = if (fineOnly) listOf(Precision.PRECISE) else listOf(Precision.APPROXIMATE, Precision.PRECISE)
}

/** The default phone and SMS apps, as Android names them now. */
data class RoleHolders(val dialer: String, val sms: String) {
    fun holds(pkg: String): Boolean = pkg == dialer || pkg == sms
}

enum class Grant { GRANTED, DENIED }

/** One setPermissionGrantState, as the device owner (POLICY_FIXED either way). */
data class GrantStep(val pkg: String, val permission: String, val grant: Grant)

/** A device owner's grant state for one permission, as DevicePolicyManager.getPermissionGrantState reads it. */
enum class PolicyState { DEFAULT, GRANTED, DENIED }

/**
 * A phone-state permission of a current default phone or SMS app that
 * Welcome lifts back to Android's default (PERMISSION_GRANT_STATE_DEFAULT)
 * when, and only when, it reads Welcome's own denial ([AppRules.liftsToApply]).
 */
data class Lift(val pkg: String, val permission: String)

/** What one pass does: the grant states, then the apps refused (hidden, their data kept), then the lifts. */
class AppPlan(
    val steps: List<GrantStep>,
    val refuse: List<String>,
    /** The default phone or SMS app could not be read: no phone-state step, no refusal and no lift in this pass. */
    val rolesUnknown: Boolean,
    /** Welcome's own phone-state block on the current default apps, to lift where it reads DENIED. */
    val lifts: List<Lift> = emptyList(),
)

/**
 * WEL9's rules for installed apps, apart from Android so that every case is
 * unit-tested (AppRulesTest); [AppPolicies] applies them. Only location
 * (coarse, fine, background) and phone state (READ_PHONE_STATE,
 * READ_PHONE_NUMBERS) are ever set: no call or SMS permission, in any app.
 *
 * Left alone, always: system apps (the dialer, Telephony, cell broadcast,
 * IMS, the location and GNSS providers among them), Welcome itself, and the
 * default phone and SMS apps. Every other app the person installed:
 * - location denied (POLICY_FIXED), unless the session chose it: then
 *   coarse granted, fine granted only when precise, background never;
 * - phone state denied, unless it is in [plan]'s phoneStateApps (empty: the
 *   opt-in for SIM-bound messaging apps waits for AM4 and PH3);
 * - refused when a [PrivilegeSource] says it has carrier privileges.
 * When the default phone or SMS app cannot be read, a pass sets no phone
 * state, refuses nothing and lifts nothing (calls come first); location
 * still goes, since no call or text depends on an app's location grant.
 * Apps that came with the phone keep Android's location permissions (WEL6).
 *
 * The one thing done to a default phone or SMS app: Welcome lifts its own
 * phone-state denial on it (one it set before the app became the default),
 * back to Android's default, never to granted ([Lift]).
 */
object AppRules {
    const val COARSE = "android.permission.ACCESS_COARSE_LOCATION"
    const val FINE = "android.permission.ACCESS_FINE_LOCATION"
    const val BACKGROUND = "android.permission.ACCESS_BACKGROUND_LOCATION"
    const val PHONE_STATE = "android.permission.READ_PHONE_STATE"
    const val PHONE_NUMBERS = "android.permission.READ_PHONE_NUMBERS"

    val LOCATION = listOf(COARSE, FINE, BACKGROUND)
    val PHONE = listOf(PHONE_STATE, PHONE_NUMBERS)

    /** Never touched by a pass: system apps, Welcome ([self]) and the default phone and SMS apps. */
    fun leftAlone(app: InstalledApp, self: String, roles: RoleHolders?): Boolean =
        app.system || app.pkg == self || roles?.holds(app.pkg) == true

    /**
     * One pass. [chosen] is the session's location choice (null before Start
     * or without a session: no app gets location); [roles] null when the
     * default phone or SMS app could not be read; [privileged] the packages a
     * [PrivilegeSource] gives carrier privileges. [apps] may be every
     * installed app or only one just installed: an app's steps are the same
     * either way.
     */
    fun plan(
        apps: List<InstalledApp>,
        self: String,
        chosen: Map<String, Precision>?,
        roles: RoleHolders?,
        privileged: Set<String>,
        phoneStateApps: Set<String> = emptySet(),
    ): AppPlan {
        val targets = apps.filter { !leftAlone(it, self, roles) }
        val refuse = if (roles == null) emptyList() else targets.map { it.pkg }.filter { it in privileged }
        val steps = ArrayList<GrantStep>()
        for (app in targets) {
            // A refused app gets no location, whatever was chosen.
            val precision = if (app.pkg in refuse) null else chosen?.get(app.pkg)
            val own = mutableListOf(
                BACKGROUND to Grant.DENIED,
                FINE to if (precision == Precision.PRECISE) Grant.GRANTED else Grant.DENIED,
                COARSE to if (precision != null) Grant.GRANTED else Grant.DENIED,
            )
            if (roles != null && app.pkg !in phoneStateApps) own += PHONE.map { it to Grant.DENIED }
            // Each app's denials first, then its grants.
            for ((permission, grant) in own.sortedBy { it.second != Grant.DENIED }) {
                if (permission in app.requested) steps += GrantStep(app.pkg, permission, grant)
            }
        }
        // The current default apps (not the system's, not Welcome): Welcome's own phone-state block lifted.
        val lifts = if (roles == null) emptyList() else apps
            .filter { roles.holds(it.pkg) && !it.system && it.pkg != self }
            .flatMap { app -> PHONE.filter { it in app.requested }.map { Lift(app.pkg, it) } }
        return AppPlan(steps, refuse, rolesUnknown = roles == null, lifts = lifts)
    }

    /** A rate limit: true when nothing was done yet ([last] null), or [every] has passed since [last]. */
    fun due(last: Long?, now: Long, every: Long): Boolean = last == null || now - last >= every

    /** The lifts that apply: only where the grant state reads Welcome's own denial; never from GRANTED or DEFAULT. */
    fun liftsToApply(lifts: List<Lift>, state: (Lift) -> PolicyState): List<Lift> =
        lifts.filter { state(it) == PolicyState.DENIED }

    /**
     * At shutdown: the chosen apps' location denied again, so that Android's
     * stored grants keep no trace of the choice (every other app is denied
     * already). The next boot denies them as well, in case shutdown is cut.
     */
    fun atShutdown(chosen: Map<String, Precision>, self: String): List<GrantStep> =
        chosen.keys.filter { it != self }.flatMap { pkg -> LOCATION.map { GrantStep(pkg, it, Grant.DENIED) } }

    /**
     * The apps the Welcome screen offers for location: those a pass may
     * grant it to, and that ask for it. (One with carrier privileges is
     * refused at the next pass, and then no longer listed.)
     */
    fun offered(apps: List<InstalledApp>, self: String, roles: RoleHolders?): List<LocationApp> =
        apps.filter { !leftAlone(it, self, roles) && (COARSE in it.requested || FINE in it.requested) }
            .map { LocationApp(it.pkg, it.label, fineOnly = COARSE !in it.requested) }
            .sortedWith(compareBy({ it.label.lowercase() }, { it.pkg }))
}

/**
 * Grants stop for good once shutdown closes the gate: a pass still running
 * grants nothing after the shutdown's denials begin. One monitor holds both
 * a grant under way and the closing, so a grant either lands before the
 * gate closes (and the shutdown's denial follows it) or not at all.
 * Denials never go through the gate.
 */
class GrantGate {
    private var closed = false

    /** Runs [grant] unless the gate is closed; false when it did not run. */
    @Synchronized
    fun grant(grant: () -> Boolean): Boolean = if (closed) false else grant()

    /** No grant runs after this returns (one under way is waited for). */
    @Synchronized
    fun close() {
        closed = true
    }

    @Synchronized
    fun isClosed(): Boolean = closed
}

/**
 * A list of apps with carrier privileges that Welcome can read. Android has
 * three sources (CarrierPrivilegesTracker): the SIM's own access rules (and
 * an eSIM profile's), the carrier configuration's certificate list, and
 * test overrides. A device owner can read only the carrier configuration
 * ([CarrierConfigRules], through CarrierConfigSource); the others are
 * exposed only through @SystemApi, so MOD10's live list from root, the
 * tracker's whole set, is the second source ([LiveList]). A pass refuses
 * what either names, as far as [AppRules.plan] may refuse.
 */
interface PrivilegeSource {
    /** The packages among [apps] this source gives carrier privileges; null when it could not be read. */
    fun privileged(apps: List<InstalledApp>): Set<String>?
}

/** One entry of KEY_CARRIER_CERTIFICATE_STRING_ARRAY, decoded: a certificate hash, for one package or (null or empty) any. */
class CarrierRule(val hash: ByteArray, val pkg: String?)

/**
 * One SIM slot's carrier configuration as CarrierPrivilegesTracker uses it:
 * [identified] is CarrierConfigManager.isConfigForIdentifiedCarrier (a
 * carrier's own configuration has been applied); [entries] its certificate
 * list.
 */
class SlotConfig(val identified: Boolean, val entries: List<String>?)

/** The carrier configuration's certificate lists, one per SIM slot, matched as Android matches them. */
class CarrierConfigRules(private val slots: List<SlotConfig>) : PrivilegeSource {
    override fun privileged(apps: List<InstalledApp>): Set<String> = CarrierRules.privileged(slots, apps)
}

/**
 * KEY_CARRIER_CERTIFICATE_STRING_ARRAY as CarrierPrivilegesTracker and
 * UiccAccessRule read it. A slot's list counts only when a carrier's own
 * configuration has been applied ([SlotConfig.identified]). An entry is
 * "hash" or "hash:package1,package2", the hash in hexadecimal (either
 * case), split as Java's String.split does. A package-bound rule matches
 * only its packages; an empty package name matches any. A rule matches an
 * app when the SHA-256 of one of its signing certificates is the hash, or
 * the SHA-1 when the hash is 20 bytes long. When one entry cannot be decoded
 * (an odd length, a character that is not hexadecimal, nothing before the
 * ':'), Android drops the slot's whole list (IccUtils throws and nothing
 * catches it), and so does Welcome.
 */
object CarrierRules {
    /** A whole list's rules, or null when one entry cannot be decoded. */
    fun decode(entries: List<String>?): List<CarrierRule>? {
        val rules = ArrayList<CarrierRule>()
        for (entry in entries.orEmpty()) {
            val parts = javaSplit(entry, ':')
            if (parts.isEmpty()) return null
            val hash = hex(parts[0]) ?: return null
            if (parts.size == 1) {
                rules += CarrierRule(hash, null)
            } else {
                for (pkg in javaSplit(parts[1], ',')) rules += CarrierRule(hash, pkg)
            }
        }
        return rules
    }

    fun matches(rule: CarrierRule, pkg: String, cert: ByteArray): Boolean {
        if (!rule.pkg.isNullOrEmpty() && rule.pkg != pkg) return false
        if (rule.hash.contentEquals(digest("SHA-256", cert))) return true
        return rule.hash.size == 20 && rule.hash.contentEquals(digest("SHA-1", cert))
    }

    /** One slot's list, as a carrier's own configuration. */
    fun privilegedBy(entries: List<String>?, apps: List<InstalledApp>): Set<String> =
        privileged(listOf(SlotConfig(identified = true, entries = entries)), apps)

    fun privileged(slots: List<SlotConfig>, apps: List<InstalledApp>): Set<String> {
        val rules = slots.filter { it.identified }.flatMap { decode(it.entries).orEmpty() }
        if (rules.isEmpty()) return emptySet()
        return apps.filter { app -> app.certs.any { cert -> rules.any { matches(it, app.pkg, cert) } } }.map { it.pkg }.toSet()
    }

    /** IccUtils.hexStringToBytes, which takes 0-9, A-F and a-f; null where it would throw. */
    fun hex(s: String): ByteArray? {
        if (s.length % 2 != 0) return null
        val out = ByteArray(s.length / 2)
        for (i in out.indices) {
            val hi = nibble(s[2 * i]) ?: return null
            val lo = nibble(s[2 * i + 1]) ?: return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    /** IccUtils.hexCharToInt: ASCII hexadecimal only. */
    private fun nibble(c: Char): Int? = when (c) {
        in '0'..'9' -> c - '0'
        in 'A'..'F' -> c - 'A' + 10
        in 'a'..'f' -> c - 'a' + 10
        else -> null
    }

    /** String.split(String) with one separator: trailing empty strings removed, and nothing left when only separators remain. */
    fun javaSplit(s: String, sep: Char): List<String> {
        if (sep !in s) return listOf(s)
        val parts = s.split(sep).toMutableList()
        while (parts.isNotEmpty() && parts.last().isEmpty()) parts.removeAt(parts.size - 1)
        return parts
    }

    private fun digest(algorithm: String, data: ByteArray): ByteArray = MessageDigest.getInstance(algorithm).digest(data)
}
