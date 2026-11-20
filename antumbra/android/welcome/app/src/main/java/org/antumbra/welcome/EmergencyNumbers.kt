// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.TelephonyManager
import android.telephony.emergency.EmergencyNumber

/**
 * One entry of Android's emergency-number list, as WEL10 uses it: nothing
 * else of it is read. [sources] is the bitmask of where Android has it from
 * (EmergencyNumber.EMERGENCY_NUMBER_SOURCE_*; 0 for Android's own fallback).
 */
data class EmergencyEntry(val digits: String, val categories: Set<Int>, val routing: Int, val sources: Int)

/** What the emergency card says about the number (WEL10). */
sealed interface NumberReading {
    /** Before the first reading. */
    data object NotYet : NumberReading

    /** Android's general emergency number now. */
    data class Found(val digits: String) : NumberReading

    /**
     * Several general numbers that Android ranks alike, none from the
     * network, the SIM or Android's database (its own fallback list without
     * a SIM, say): all of them, in Android's order. Android places a call to
     * any of them as an emergency call.
     */
    data class Several(val numbers: List<String>) : NumberReading

    /** The lists were read, and none of them holds a general emergency number. */
    data object NoneListed : NumberReading

    /** The lists could not be read (no permission, no telephony, the phone process down), or Android has none. */
    data object Unreadable : NumberReading
}

/**
 * The general emergency number, read from Android's own emergency-number
 * list at run time (WEL10). Welcome never names a number itself: no number
 * is written in its code or its texts (EmergencyNumbersTest scans both).
 *
 * TelephonyManager.getEmergencyNumberList (READ_PHONE_STATE, which Welcome
 * holds) gives one list per active subscription, or one for the default
 * subscription without a SIM. Each holds what the network, the SIM,
 * Android's country database and the modem said; with no word from the
 * modem yet (the radio never on since power-on), Android's own fallback
 * from 3GPP 22.101. Only four things are read from each entry: its digits,
 * its categories, its routing and its sources. The subscription ids, the
 * country and the network code of an entry are never looked at
 * (NoIdentifiersTest).
 */
object EmergencyNumbers {
    /** Longer numbers are not shown: Android's general numbers are short. */
    const val MAX_DIGITS = 8

    /** Between the numbers of [NumberReading.Several] on screen: a line may break after the dot, never before it. */
    const val BETWEEN = " · "

    /** Placed as an ordinary call, not as an emergency call. */
    private const val NORMAL = EmergencyNumber.EMERGENCY_CALL_ROUTING_NORMAL

    private val GENERAL = setOf(
        EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_POLICE,
        EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_AMBULANCE,
        EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_FIRE_BRIGADE,
    )

    /**
     * A general emergency number: "unspecified" (Android's "general
     * emergency call, all categories"), or police, ambulance and fire
     * together.
     */
    fun isGeneral(categories: Set<Int>): Boolean =
        EmergencyNumber.EMERGENCY_SERVICE_CATEGORY_UNSPECIFIED in categories || categories.containsAll(GENERAL)

    /** Where Android has a number from, as far as WEL10 trusts it alone: the network, the SIM or Android's database. */
    private const val TRUSTED = EmergencyNumber.EMERGENCY_NUMBER_SOURCE_NETWORK_SIGNALING or
        EmergencyNumber.EMERGENCY_NUMBER_SOURCE_SIM or EmergencyNumber.EMERGENCY_NUMBER_SOURCE_DATABASE

    /**
     * Android's own rank of an entry's [sources] (EmergencyNumber's display
     * priority, the first key of its compareTo): network > SIM > database >
     * default > modem config. Android's fallback list has none of them: 0.
     */
    fun rank(sources: Int): Int = listOf(
        EmergencyNumber.EMERGENCY_NUMBER_SOURCE_NETWORK_SIGNALING to 16,
        EmergencyNumber.EMERGENCY_NUMBER_SOURCE_SIM to 8,
        EmergencyNumber.EMERGENCY_NUMBER_SOURCE_DATABASE to 4,
        EmergencyNumber.EMERGENCY_NUMBER_SOURCE_DEFAULT to 2,
        EmergencyNumber.EMERGENCY_NUMBER_SOURCE_MODEM_CONFIG to 1,
    ).sumOf { (bit, score) -> if (sources and bit != 0) score else 0 }

    /**
     * What to show from [entries], in Android's own order
     * (EmergencyNumber.compareTo: the best-ranked source first, then the
     * digits as text). Only general numbers count, digits only, 1 to
     * [MAX_DIGITS] of them, each once; those Android does not place as an
     * ordinary call, unless there are none of those.
     *
     * One number only when the first one is from the network, the SIM or
     * Android's database, or outranks every other one. Otherwise Android
     * ranks several alike and its order between them is only the digits'
     * text order: with no SIM and no word from the modem, Android's fallback
     * list (EmergencyNumberTracker: 3GPP 22.101's numbers, all general, none
     * from any source) would put a number first that is not the general
     * number in most places. Then every number ranked like the first is
     * shown, in Android's order ([NumberReading.Several]). (Android sets the
     * ordinary-call routing only on its database's numbers, which are shown
     * alone, so a list never holds one.)
     */
    fun pick(entries: List<EmergencyEntry>): NumberReading {
        val general = entries.filter { e ->
            e.digits.length in 1..MAX_DIGITS && e.digits.all { it in '0'..'9' } && isGeneral(e.categories)
        }
        val pool = general.filter { it.routing != NORMAL }.ifEmpty { general }.distinctBy { it.digits }
        val best = pool.firstOrNull() ?: return NumberReading.NoneListed
        val alike = pool.filter { rank(it.sources) >= rank(best.sources) }
        return if (best.sources and TRUSTED != 0 || alike.size == 1) {
            NumberReading.Found(best.digits)
        } else {
            NumberReading.Several(alike.map { it.digits })
        }
    }

    /** The numbers a reading shows: one, several, or none. */
    fun shown(r: NumberReading): List<String> = when (r) {
        is NumberReading.Found -> listOf(r.digits)
        is NumberReading.Several -> r.numbers
        else -> emptyList()
    }

    /**
     * [fetch] gives every entry of every list (empty: lists without a
     * general number), or null when Android has no list ("not available").
     * Whatever it throws makes the reading [NumberReading.Unreadable].
     */
    fun read(fetch: () -> List<EmergencyEntry>?): NumberReading = try {
        fetch()?.let(::pick) ?: NumberReading.Unreadable
    } catch (e: RuntimeException) {
        NumberReading.Unreadable
    }

    /** Android's lists now. Not asked during a call (the screens keep their last reading then). */
    fun read(context: Context): NumberReading = read { entries(context) }

    private fun entries(context: Context): List<EmergencyEntry>? {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return null
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return null
        val lists = try {
            tm.emergencyNumberList
        } catch (e: SecurityException) {
            return null
        }
        if (lists.isEmpty()) return null
        return lists.values.flatten().sorted().map { n: EmergencyNumber ->
            EmergencyEntry(n.number, n.emergencyServiceCategories.toSet(), n.emergencyCallRouting, n.emergencyNumberSources.fold(0, Int::or))
        }
    }

    /** The digits one by one, for the screen reader ("1 2 3", not "one hundred twenty-three"). */
    fun spoken(digits: String): String = digits.toList().joinToString(" ")
}

/**
 * The emergency card's reading for the screens' poll (WEL10): Android's
 * number (not asked again during a call: the last reading stays), the
 * state lines from WEL8's [PhoneStatus], or the CI hook's lines in a test
 * build ([TestHook.emergencyStates]), and why "Show my position" would be
 * refused. Off the main thread. Kept in memory only.
 */
object EmergencyWatch {
    @Volatile
    private var lastNumber: NumberReading = NumberReading.NotYet

    fun read(context: Context, phone: PhoneStatus, phoneMode: Boolean): EmergencyUi {
        if (!CallWatch.inCall(context)) lastNumber = EmergencyNumbers.read(context)
        val hook = TestHook.emergencyStates(context)
        return EmergencyUi(
            reading = hook?.reading ?: lastNumber,
            states = hook?.states ?: EmergencyTexts.states(phone, phoneMode),
            refusal = Position.refusal(context),
        )
    }
}
