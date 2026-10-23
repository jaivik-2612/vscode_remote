// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WEL8: Welcome reads no identifier of the phone, the SIM or its number.
 * A device owner holding READ_PHONE_STATE (Welcome holds it, for "Return
 * to call") may read the IMEI, the IMSI and the SIM's serial number, so
 * Android does not stop it: this rule of Welcome's own code is checked
 * here, over every source file. Nor does it ask for the operator or the
 * network, which tell the country and the carrier, or for a call's number.
 *
 * Three rules, on the code with its comments taken out (strings stay, so a
 * name looked up by reflection counts):
 * - no forbidden getter, in its Java form (getImei, getSimOperatorName...)
 *   or its Kotlin property form (.imei, .simOperatorName...);
 * - no class that lists subscriptions, cells or cards (SubscriptionManager,
 *   SubscriptionInfo, CellInfo...);
 * - on a TelephonyManager or a ServiceState, only the members Welcome uses
 *   (an allow-list), so that a new member is a decision, not an accident.
 */
class NoIdentifiersTest {
    /** Getters, matched by their exact names. */
    private val getters = listOf(
        "getImei", "getMeid", "getDeviceId", "getSubscriberId", "getSimSerialNumber", "getIccId", "getLine1Number",
        "getPhoneNumber", "getVoiceMailNumber", "getVoiceMailAlphaTag", "getGroupIdLevel1", "getNai", "getSerial",
        "getOperatorNumeric", "getSimCountryIso", "getNetworkCountryIso", "getAllCellInfo", "getCellLocation",
        "getNeighboringCellInfo", "getCarrierName", "getDisplayName", "getMccString", "getMncString", "getCardId",
        "getUiccCardsInfo", "getUiccSlotsInfo", "getTypeAllocationCode", "getManufacturerCode", "getServiceState",
        "getSimSpecificCarrierId", "getCarrierIdFromSimMccMnc", "getMsisdn", "getIsimImpi", "getIsimImpu",
        "getIsimDomain", "getEsn", "getCdmaMdn", "getCdmaMin", "getForbiddenPlmns", "getEquivalentHomePlmns",
        "getManualNetworkSelectionPlmn", "getHandle", "getCallerDisplayName", "getContactDisplayName", "getNumber",
        "requestCellInfoUpdate", "requestNetworkScan",
    )

    /** Getter families, matched as prefixes: getSimOperator also covers getSimOperatorName. */
    private val families = listOf(
        "getSimOperator", "getNetworkOperator", "getOperatorAlpha", "getActiveSubscriptionInfo",
        "getAccessibleSubscriptionInfo", "getAvailableSubscriptionInfo", "getCompleteActiveSubscriptionInfo",
        "getSimCarrierId", "getCellIdentity",
    )

    /** The Kotlin property form of a getter: getSimOperator -> simOperator. */
    private fun property(getter: String): String = getter.removePrefix("get").replaceFirstChar { it.lowercase() }

    private val forbiddenClasses = listOf(
        "SubscriptionManager", "SubscriptionInfo", "CellInfo", "CellIdentity", "CellLocation", "CellSignalStrength",
        "UiccCardInfo", "UiccSlotInfo", "UiccPortInfo", "EuiccManager", "NetworkScan", "ANDROID_ID", "Build.SERIAL",
    )

    /** Members Welcome may use on a TelephonyManager or a ServiceState it holds. */
    private val allowed = mapOf(
        "TelephonyManager" to setOf("activeModemCount", "getSimState", "registerTelephonyCallback", "unregisterTelephonyCallback"),
        "ServiceState" to setOf("state"),
    )

    /** Its static constants Welcome may name: the SIM states, the location renouncement, the radio states. */
    private val allowedStatic = mapOf(
        "TelephonyManager" to Regex("SIM_STATE_[A-Z_]+|INCLUDE_LOCATION_DATA_NONE"),
        "ServiceState" to Regex("STATE_[A-Z_]+"),
    )

    /** The code without its comments (strings kept; "//" in a string is not a comment). */
    private fun withoutComments(src: String): String {
        val out = StringBuilder(src.length)
        var i = 0
        var depth = 0
        var inString = false
        var raw = false
        while (i < src.length) {
            val c = src[i]
            val next = if (i + 1 < src.length) src[i + 1] else ' '
            when {
                depth > 0 -> {
                    if (c == '*' && next == '/') { depth--; i += 2; out.append("  "); continue }
                    if (c == '/' && next == '*') { depth++; i += 2; out.append("  "); continue }
                    out.append(if (c == '\n') '\n' else ' ')
                }
                inString && raw -> {
                    if (src.startsWith("\"\"\"", i)) { inString = false; out.append("\"\"\""); i += 3; continue }
                    out.append(c)
                }
                inString -> {
                    if (c == '\\' && i + 1 < src.length) { out.append(c).append(next); i += 2; continue }
                    if (c == '"' || c == '\n') inString = false
                    out.append(c)
                }
                c == '/' && next == '/' -> {
                    while (i < src.length && src[i] != '\n') { out.append(' '); i++ }
                    continue
                }
                c == '/' && next == '*' -> { depth = 1; i += 2; out.append("  "); continue }
                src.startsWith("\"\"\"", i) -> { inString = true; raw = true; out.append("\"\"\""); i += 3; continue }
                c == '"' -> { inString = true; raw = false; out.append(c) }
                c == '\'' && i + 2 < src.length && (src[i + 2] == '\'' || (next == '\\' && i + 3 < src.length && src[i + 3] == '\'')) -> {
                    // A char literal such as '"' or '\'' is not the start of a string.
                    val len = if (next == '\\') 4 else 3
                    out.append(src, i, i + len)
                    i += len
                    continue
                }
                else -> out.append(c)
            }
            i++
        }
        return out.toString()
    }

    /** What the rules find in one source file's text (empty: nothing). */
    private fun violations(name: String, src: String): List<String> {
        val code = withoutComments(src)
        val found = ArrayList<String>()
        for ((list, tail) in listOf(getters to "\\b", families to "\\w*")) {
            for (g in list) {
                if (Regex("\\b$g$tail").containsMatchIn(code)) found += "$name: $g"
                if (Regex("(?:\\?\\.|!!\\.|\\.)\\s*${property(g)}$tail").containsMatchIn(code)) found += "$name: .${property(g)}"
            }
        }
        for (k in forbiddenClasses) {
            if (Regex("\\b${Regex.escape(k)}\\b").containsMatchIn(code)) found += "$name: $k"
        }
        for ((type, members) in allowed) {
            // Its static members.
            Regex("\\b$type\\s*\\.\\s*(\\w+)").findAll(code).forEach {
                val m = it.groupValues[1]
                if (!allowedStatic.getValue(type).matches(m)) found += "$name: $type.$m"
            }
            // The names that hold one: a declared type, or an initializer naming the class.
            val holders = HashSet<String>()
            Regex("\\b(\\w+)\\s*:\\s*$type\\b").findAll(code).forEach { holders += it.groupValues[1] }
            Regex("\\b(?:val|var)\\s+(\\w+)\\s*=\\s*[^\\n]*\\b$type\\b").findAll(code).forEach { holders += it.groupValues[1] }
            for (h in holders) {
                Regex("\\b$h\\s*(?:\\?\\.|!!\\.|\\.)\\s*(\\w+)").findAll(code).forEach {
                    val m = it.groupValues[1]
                    if (m !in members) found += "$name: $h.$m (a $type)"
                }
                if (Regex("\\bwith\\s*\\(\\s*$h\\s*\\)").containsMatchIn(code)) found += "$name: with($h) (a $type)"
            }
            // One used straight from getSystemService, without a name.
            Regex("$type::class\\.java\\s*\\)\\s*(?:\\?\\.|!!\\.|\\.)\\s*(\\w+)").findAll(code).forEach {
                val m = it.groupValues[1]
                if (m !in members) found += "$name: getSystemService($type).$m"
            }
        }
        return found
    }

    @Test
    fun noSourceAsksForAnIdentifier() {
        val sources = File("src/main/java").walkTopDown().filter { it.isFile && it.extension in setOf("kt", "java") }.toList()
        assertTrue(sources.size > 10)
        val found = sources.flatMap { violations(it.name, it.readText()) }
        assertEquals(emptyList<String>(), found)
        // The scan does see Welcome's own uses (the allow-list is not empty by accident).
        val cellWord = File("src/main/java/org/antumbra/welcome/CellWord.kt").readText()
        assertTrue(cellWord.contains("tm.getSimState(") && cellWord.contains("tm.activeModemCount"))
    }

    /** Each way of asking for an identifier that the rules must catch, in the forms Kotlin and Java allow. */
    @Test
    fun theScanCatchesEveryForm() {
        val tm = "val tm = context.getSystemService(TelephonyManager::class.java)\n"
        val seeds = listOf(
            "val x = tm.getImei(0)", "val x = tm.imei", "val x = tm.deviceId", "val x = tm.meid", "val x = tm?.meid",
            "val x = tm.simOperator", "val x = tm.networkOperator", "val x = tm.getSimOperatorName()",
            "val x = tm.simOperatorName", "val x = tm.networkOperatorName", "val x = tm.getNetworkOperatorName()",
            "fun f(ss: ServiceState) = ss.getOperatorAlphaLong()", "fun f(ss: ServiceState) = ss.operatorAlphaLong",
            "val x = tm.simCountryIso", "val x = tm.networkCountryIso", "val x = tm.groupIdLevel1",
            "val x = tm.voiceMailNumber", "val x = tm.nai", "val x = info.iccId", "val x = info.number",
            "val x = sm.activeSubscriptionInfoList", "val x = info.carrierName", "val x = tm.getTypeAllocationCode()",
            "val x = tm.typeAllocationCode", "val x = tm.manufacturerCode", "val x = tm.serviceState",
            "val x = tm!!.line1Number", "val x = tm.subscriberId", "val x = tm.simSerialNumber",
            "val x = call.details.handle", "val x = details.getHandle()", "val x = Build.getSerial()",
            "val x = Settings.Secure.getString(r, Settings.Secure.ANDROID_ID)",
            "val sm = context.getSystemService(SubscriptionManager::class.java)",
            "val x = tm.allCellInfo", "tm.requestCellInfoUpdate(e, cb)", "val x = tm.cellLocation",
            "val m = TelephonyManager::class.java.getMethod(\"getImei\")",
            // Members outside the allow-list, on a TelephonyManager however it is held.
            "val x = tm.simState", "val x = tm.phoneCount", "val x = tm.isNetworkRoaming",
            "val x = context.getSystemService(TelephonyManager::class.java)?.simCarrierIdName",
            "private var held: TelephonyManager? = null\nfun f() = held?.dataNetworkType",
            "fun f(t: TelephonyManager) = with(t) { simState }",
            "val x = TelephonyManager.EXTRA_STATE",
            "fun f(ss: ServiceState) = ss.roaming",
        )
        for (seed in seeds) {
            val code = if (seed.contains("tm") && !seed.contains("val tm")) tm + seed else seed
            assertTrue("not caught: $seed", violations("seed", code).isNotEmpty())
        }
        // Welcome's own uses, a comment that names a getter and "//" in a string are not.
        val fine = tm + """
            val n = tm.activeModemCount
            val s = (0 until n).map { SimState.of(tm.getSimState(it)) }
            tm.registerTelephonyCallback(TelephonyManager.INCLUDE_LOCATION_DATA_NONE, context.mainExecutor, callback)
            private var registered: TelephonyManager? = null
            fun stop() { registered?.unregisterTelephonyCallback(callback) }
            fun on(serviceState: ServiceState) { listenerState = serviceState.state }
            val off = ServiceState.STATE_POWER_OFF
            val absent = TelephonyManager.SIM_STATE_ABSENT
            // Never tm.getImei() or tm.simOperator: see NoIdentifiersTest.
            /* Nor getLine1Number, /* nested */ nor .iccId. */
            val uri = "content://org.antumbra.welcome.state" // getSubscriberId in a comment after a string
            val q = '"'
        """.trimIndent()
        assertEquals(emptyList<String>(), violations("fine", fine))
    }

    /** The listener gets no location: registered with INCLUDE_LOCATION_DATA_NONE, and Welcome holds no location permission. */
    @Test
    fun theListenerGetsNoLocation() {
        val src = File("src/main/java/org/antumbra/welcome/CellWord.kt").readText()
        assertTrue(src.contains("registerTelephonyCallback(TelephonyManager.INCLUDE_LOCATION_DATA_NONE,"))
        assertEquals(1, Regex("\\bregisterTelephonyCallback\\(").findAll(src).count())
        val manifest = File("src/main/AndroidManifest.xml").readText()
        listOf("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "READ_PRIVILEGED_PHONE_STATE", "READ_PHONE_NUMBERS", "READ_SMS")
            .forEach { assertTrue(it, !manifest.contains(it)) }
    }
}
