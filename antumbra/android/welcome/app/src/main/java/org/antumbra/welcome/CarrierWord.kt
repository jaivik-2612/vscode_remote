// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.content.Context

/**
 * The module's live list (MOD10, method "module_carrier"): the apps with
 * carrier privileges as Android's CarrierPrivilegesTracker has them, from
 * all three of its sources (the SIM's own access rules, an eSIM profile's
 * among them; the carrier configuration; test overrides), which root reads
 * from the telephony registry's dump. A device owner can read only the
 * carrier configuration ([CarrierConfigSource]); the others are exposed
 * only through @SystemApi. [packages] the package names, [atS] the module's
 * read in seconds since boot.
 *
 * Only root may give it (StateProvider.call, [ModuleCalls]). Welcome keeps
 * it in memory ([LiveList]) and never hands it out, writes it or logs it.
 * It can only make Welcome refuse more of the apps the person installed:
 * never a system app, Welcome itself, or the default phone or SMS app
 * ([AppRules.plan] leaves them alone, whatever a source says).
 */
data class CarrierWord(val packages: Set<String>, val atS: Long) {
    companion object {
        /** The provider's method (StateProvider.call). */
        const val METHOD = "module_carrier"
        const val VERSION = 1

        /** At most this many packages (the module sends no more). */
        const val MAX = 200

        /** The extras of a word, every one of them, and nothing else. */
        val KEYS = setOf("v", "packages", "at")

        /** A package name as Android takes it: segments of letters, digits and _, each beginning with a letter. */
        private val NAME = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*")

        /**
         * The word in [values] (the call's extras), or null unless they are
         * exactly [KEYS] with these types and values: v the Int 1; packages
         * a String, the names joined by commas (empty for none), at most
         * [MAX], each a valid package name; at a Long of 0 or more.
         */
        fun parse(values: Map<String, Any?>): CarrierWord? {
            if (values.keys != KEYS) return null
            if (values["v"] != VERSION) return null
            val list = values["packages"] as? String ?: return null
            val at = values["at"] as? Long ?: return null
            if (at < 0) return null
            val names = if (list.isEmpty()) emptyList() else list.split(',')
            if (names.size > MAX || names.any { !NAME.matches(it) }) return null
            return CarrierWord(names.toSet(), at)
        }

        /**
         * The provider's whole call for this method, apart from Android
         * classes, like [CellWord.receive]: any caller but root is refused
         * before anything is looked at. From root a well-formed word goes to
         * [take]; a malformed one changes nothing (the list Welcome holds
         * stays: keeping it refuses more, the safe side here) and is refused
         * with IllegalArgumentException, so that the module sees it was not
         * taken.
         */
        fun receive(uid: Int, method: String, arg: String?, values: () -> Map<String, Any?>, take: (CarrierWord) -> Unit) {
            if (!ModuleWord.isAllowedWriter(uid)) throw SecurityException("uid $uid may not call $method")
            require(method == METHOD) { "Unknown method: $method" }
            require(arg == null) { "No argument expected" }
            take(requireNotNull(parse(values())) { "Malformed word" })
        }
    }
}

/**
 * MOD10's live list as a [PrivilegeSource]: the installed apps it names.
 * [AppRules.plan] then refuses those it may refuse.
 */
object LiveListRules {
    fun privileged(word: CarrierWord?, apps: List<InstalledApp>): Set<String> {
        val named = word?.packages ?: return emptySet()
        return apps.map { it.pkg }.filter { it in named }.toSet()
    }
}

/**
 * The live list Welcome holds, in memory only, for the life of the process
 * (none at its start: the module tells it again when a new process holds
 * none and the list is not empty). The second [PrivilegeSource] beside the
 * carrier configuration ([AppPolicies]' pass takes both).
 */
object LiveList : PrivilegeSource {
    @Volatile
    private var word: CarrierWord? = null

    /** The module's word (StateProvider.call, from root only). True when the list changed: a pass is due then. */
    @Synchronized
    fun take(w: CarrierWord): Boolean {
        val changed = word?.packages.orEmpty() != w.packages
        word = w
        return changed
    }

    /** From the provider: the word kept, and a pass over every app when the list changed (its refusals only add). */
    fun takeFrom(context: Context?, w: CarrierWord) {
        if (take(w) && context != null) AppPolicies.request(context, "carrier privileges")
    }

    /** Never null: without a word it names nothing. */
    override fun privileged(apps: List<InstalledApp>): Set<String> = LiveListRules.privileged(word, apps)
}
