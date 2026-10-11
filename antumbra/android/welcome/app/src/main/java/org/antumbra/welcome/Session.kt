// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import java.security.SecureRandom
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** How tor connects in this session (the provider's tor_mode column). */
enum class TorMode(val wire: String) {
    DIRECT("direct"),
    BRIDGES("bridges"),
    OFFLINE("offline"),
}

enum class BridgeSource { BUILT_IN, CUSTOM }

/** The Welcome screen's controls, before Start. */
data class Choices(
    val torMode: TorMode = TorMode.DIRECT,
    val bridgeSource: BridgeSource = BridgeSource.BUILT_IN,
    val bridgeText: String = "",
    val newMac: Boolean = true,
    val admin: Boolean = false,
    val unsafeBrowser: Boolean = false,
)

/**
 * What the provider reports. Before Start every field holds its safe value
 * (offline, no bridges, new MAC address, every switch off), so a module that
 * read the row too early would still keep the network closed. Only
 * started = true makes the other fields the user's choices.
 */
data class SessionState(
    val started: Boolean,
    val torMode: TorMode,
    val bridges: List<String>,
    val newMac: Boolean,
    val admin: Boolean,
    val unsafeBrowser: Boolean,
    val persistent: Boolean,
    val sessionId: String,
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
        torMode = TorMode.OFFLINE,
        bridges = emptyList(),
        newMac = true,
        admin = false,
        unsafeBrowser = false,
        persistent = false,
        sessionId = id,
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
        flow.value = SessionState(
            started = true,
            torMode = choices.torMode,
            bridges = if (choices.torMode == TorMode.BRIDGES) bridges.toList() else emptyList(),
            newMac = choices.newMac,
            admin = choices.admin,
            unsafeBrowser = choices.unsafeBrowser,
            persistent = false,
            sessionId = id,
        )
        return true
    }
}
