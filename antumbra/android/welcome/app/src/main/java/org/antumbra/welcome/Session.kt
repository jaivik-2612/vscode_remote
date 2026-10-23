// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.security.SecureRandom
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * How tor connects in this session (the provider's tor_mode column):
 * OFFLINE when the session has no Internet.
 */
enum class TorMode(val wire: String) {
    DIRECT("direct"),
    BRIDGES("bridges"),
    OFFLINE("offline"),
}

enum class BridgeSource { BUILT_IN, CUSTOM }

/** The session's Internet (WEL8): Wi-Fi or the SIM's mobile data, both through Tor, or none. */
enum class Internet { WIFI, MOBILE, NONE }

/**
 * The cell radio for the session (the provider's cell column), in the
 * order of what each allows: OFF (the radio stays off), PHONE (calls and
 * texts: the radio on from Start, mobile data off), DATA (also mobile data,
 * through Tor). Also the Phone-mode gate's levels, as the module reports
 * them ([CellWord]).
 */
enum class CellLevel(val wire: String) {
    OFF("off"),
    PHONE("phone"),
    DATA("data"),
    ;

    companion object {
        fun of(wire: String): CellLevel? = entries.firstOrNull { it.wire == wire }
    }
}

/**
 * The Welcome screen's controls, before Start. Internet and Phone are two
 * choices; Tor's way to connect applies only when there is Internet.
 * Mobile data needs the cellular radio, and while the radio is on the
 * carrier delivers calls and texts, so Mobile data always comes with
 * Phone: calls and texts ([cell]); Phone: off cannot be chosen with it
 * ([withPhone]). The person's own Phone choice ([phone]) is kept, and
 * counts again once Internet is not mobile data.
 */
data class Choices(
    val internet: Internet = Internet.WIFI,
    /** DIRECT or BRIDGES: how tor connects when there is Internet. */
    val torMode: TorMode = TorMode.DIRECT,
    /** Phone: calls and texts (the cell radio on from Start), as the person chose it. */
    val phone: Boolean = false,
    // Built-in bridges are obfs4, which needs lyrebird (Bridges.TRANSPORTS_AVAILABLE).
    val bridgeSource: BridgeSource = if (Bridges.TRANSPORTS_AVAILABLE) BridgeSource.BUILT_IN else BridgeSource.CUSTOM,
    val bridgeText: String = "",
    val newMac: Boolean = true,
    val admin: Boolean = false,
    /** Always false in v0: the Unsafe Browser comes later (W11). */
    val unsafeBrowser: Boolean = false,
) {
    /** The provider's cell column for these choices. */
    val cell: CellLevel
        get() = when {
            internet == Internet.MOBILE -> CellLevel.DATA
            phone -> CellLevel.PHONE
            else -> CellLevel.OFF
        }

    /** The provider's tor_mode for these choices: offline without Internet, else direct or bridges. */
    val wireTorMode: TorMode
        get() = when {
            internet == Internet.NONE -> TorMode.OFFLINE
            torMode == TorMode.BRIDGES -> TorMode.BRIDGES
            else -> TorMode.DIRECT
        }

    /** Internet chosen (Mobile data brings calls and texts with it: [cell]). */
    fun withInternet(i: Internet): Choices = copy(internet = i)

    /** Phone chosen; Off is refused while Internet is mobile data (unchanged then). */
    fun withPhone(on: Boolean): Choices = if (!on && internet == Internet.MOBILE) this else copy(phone = on)
}

/**
 * What the provider reports. Before Start every field holds its safe value
 * (offline, no bridges, new MAC address, every switch off), so a module that
 * read the row too early would still keep the network closed. Only
 * started = true makes the other fields the user's choices.
 */
data class SessionState(
    val started: Boolean,
    val internet: Internet,
    val torMode: TorMode,
    val bridges: List<String>,
    val newMac: Boolean,
    val admin: Boolean,
    val unsafeBrowser: Boolean,
    val persistent: Boolean,
    val sessionId: String,
    /** The cell radio chosen (OFF before Start); the module carries out no more than its gate allows. */
    val cell: CellLevel,
)

/**
 * The session, in memory only: nothing about it is written to storage
 * (pivot checks: "Keep Welcome's own session state in memory only").
 *
 * It lives as long as the app's process. After Start the session service
 * runs in the foreground, which keeps the process alive until shutdown. If
 * the process dies anyway, a new process starts with started = false and a
 * new session_id; the module must keep the first started = 1 it read in a
 * boot and ignore later rows until the next boot (README, "The state
 * provider").
 */
object Session {
    /** 128 random bits, new in every process. */
    val id: String = ByteArray(16).also { SecureRandom().nextBytes(it) }
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    /** The row before Start. */
    internal val notStarted = SessionState(
        started = false,
        internet = Internet.NONE,
        torMode = TorMode.OFFLINE,
        bridges = emptyList(),
        newMac = true,
        admin = false,
        unsafeBrowser = false,
        persistent = false,
        sessionId = id,
        cell = CellLevel.OFF,
    )

    private val flow = MutableStateFlow(notStarted)
    val state: StateFlow<SessionState> = flow.asStateFlow()

    fun current(): SessionState = flow.value

    /**
     * Fixes the session's choices. Returns false (and changes nothing) if
     * the session had already started: the choices cannot change until the
     * phone restarts.
     */
    @Synchronized
    fun start(choices: Choices, bridges: List<String>): Boolean {
        if (flow.value.started) return false
        val torMode = choices.wireTorMode
        flow.value = SessionState(
            started = true,
            internet = choices.internet,
            torMode = torMode,
            bridges = if (torMode == TorMode.BRIDGES) bridges.toList() else emptyList(),
            newMac = choices.newMac,
            admin = choices.admin,
            unsafeBrowser = choices.unsafeBrowser,
            persistent = false,
            sessionId = id,
            cell = choices.cell,
        )
        return true
    }
}
