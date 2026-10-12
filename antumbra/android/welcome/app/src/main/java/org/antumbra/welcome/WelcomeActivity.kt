// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.addCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.antumbra.welcome.ui.AntumbraTheme
import org.antumbra.welcome.ui.WelcomeScreen
import org.antumbra.welcome.ui.WelcomeUi

/**
 * The Welcome screen's state for this process: in memory only, and kept
 * across activity re-creation (rotation, a new home intent).
 */
object WelcomeModel {
    var ui by mutableStateOf(WelcomeUi())

    /** Policies that failed at Start, for the status screen. */
    var policyFailures: List<String> = emptyList()

    /** Wi-Fi should be on for this session but is not (airplane mode). */
    var wifiNotOn: Boolean = false
}

/** Screen 1. The home screen and a locked task until Start (see Home). */
class WelcomeActivity : ComponentActivity() {

    @OptIn(ExperimentalComposeUiApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (Session.current().started) {
            openStatus()
            return
        }
        val policies = Policies(this)
        WelcomeModel.ui = WelcomeModel.ui.copy(notDeviceOwner = !policies.isDeviceOwner)
        // Also covers a first start right after provisioning.
        runCatching { Home.claim(this) }

        setContent {
            AntumbraTheme {
                Surface(color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxSize()) {
                    // Test tags become resource ids, so that uiautomator and
                    // the CI script can find the controls.
                    Box(Modifier.semantics { testTagsAsResourceId = true }) {
                        WelcomeScreen(
                            // CallWatch follows the calls: "Return to call" while one is in progress.
                            ui = WelcomeModel.ui.copy(inCall = CallWatch.callInProgress),
                            onChoices = { WelcomeModel.ui = WelcomeModel.ui.copy(choices = it, bridgeError = null) },
                            onStart = ::start,
                            onEmergencyCall = ::emergencyCall,
                            onReturnToCall = ::returnToCall,
                        )
                    }
                }
            }
        }

        // The home screen: Back goes nowhere.
        onBackPressedDispatcher.addCallback(this) { }

        // Check the add-on and the device owner while the screen is visible.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    val present = withContext(Dispatchers.IO) { AddOnCheck.run() }.present
                    WelcomeModel.ui = WelcomeModel.ui.copy(addOnPresent = present, notDeviceOwner = !policies.isDeviceOwner)
                    delay(3000)
                }
            }
        }
        // No screenshots and no recents thumbnail while bridge lines typed
        // by the user are on screen.
        lifecycleScope.launch {
            snapshotFlow {
                val c = WelcomeModel.ui.choices
                c.torMode == TorMode.BRIDGES && c.bridgeSource == BridgeSource.CUSTOM && c.bridgeText.isNotBlank()
            }.collect { secure ->
                if (secure) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
            }
        }
    }

    override fun onResume() {
        super.onResume()
        Home.lock(this)
    }

    /** Opens the emergency dial pad on top of Welcome, inside its locked task. */
    private fun emergencyCall() {
        val opened = EmergencyCall.open(this)
        WelcomeModel.ui = WelcomeModel.ui.copy(
            emergencyError = if (opened) null else getString(R.string.emergency_call_unavailable),
        )
    }

    /** Brings the call screen back over Welcome during a call (the lock task keeps every other way off). */
    private fun returnToCall() {
        val asked = EmergencyCall.returnToCall(this)
        WelcomeModel.ui = WelcomeModel.ui.copy(
            emergencyError = if (asked) null else getString(R.string.return_to_call_failed),
        )
    }

    private fun start() {
        val ui = WelcomeModel.ui
        if (ui.starting || Session.current().started) return
        // The Unsafe Browser does not exist yet (W11): never report it on.
        val choices = ui.choices.copy(unsafeBrowser = false)
        val bridges: List<String> = when {
            choices.torMode != TorMode.BRIDGES -> emptyList()
            else -> when (val r = bridgeLines(this, choices)) {
                is Bridges.Result.Ok -> r.lines
                is Bridges.Result.Error -> {
                    WelcomeModel.ui = ui.copy(
                        bridgeError = BridgeMessages.text(this, r.problem, choices.bridgeSource),
                        startError = null,
                    )
                    return
                }
            }
        }
        WelcomeModel.ui = ui.copy(starting = true, bridgeError = null, startError = null)
        lifecycleScope.launch {
            try {
                startSession(choices, bridges)
            } finally {
                // Cancelled before the session started (the activity went
                // away): let the user press Start again.
                if (!Session.current().started) WelcomeModel.ui = WelcomeModel.ui.copy(starting = false)
            }
        }
    }

    /**
     * Start: refused unless Welcome is the device owner; a network session
     * is also refused when a protective policy failed (only an offline
     * session can start then), and every Start is refused once the module
     * holds a session from this boot.
     */
    private suspend fun startSession(choices: Choices, bridges: List<String>) {
        val policies = Policies(this)
        if (!policies.isDeviceOwner) {
            refuse(getString(R.string.start_refused_not_owner), notDeviceOwner = true)
            return
        }
        val check = withContext(Dispatchers.IO) { AddOnCheck.run() }
        if (check.sessionLatched) {
            refuse(getString(R.string.start_refused_latched))
            return
        }
        // Policies first: the module opens the network as soon as the
        // provider reports started = 1. The boot lock keeps a late boot
        // broadcast from locking Wi-Fi again in between.
        val started = withContext(Dispatchers.IO) {
            synchronized(BootState.lock) {
                if (Session.current().started) return@synchronized null
                val result = policies.applyAtStart(choices, check.present)
                if (result.refused) return@synchronized result
                WelcomeModel.policyFailures = result.failed
                WelcomeModel.wifiNotOn = result.wifiNotOn
                // The module had its chance to act on a power-off request.
                PanicOff.clearRequest(this@WelcomeActivity)
                Session.start(choices, bridges)
                result
            }
        } ?: return
        if (started.refused) {
            refuse(getString(R.string.start_refused_policies, started.protective.joinToString()))
            return
        }
        // From here the bridge lines live in the session only.
        WelcomeModel.ui = WelcomeUi()
        SessionService.start(this)
        Home.release(this)
        openStatus()
        Home.disableWelcome(this)
    }

    private fun refuse(message: String, notDeviceOwner: Boolean = WelcomeModel.ui.notDeviceOwner) {
        WelcomeModel.ui = WelcomeModel.ui.copy(starting = false, startError = message, notDeviceOwner = notDeviceOwner)
    }

    private fun openStatus() {
        startActivity(Intent(this, StatusActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        finish()
    }

    companion object {
        const val BUILTIN_ASSET = "builtin-bridges-obfs4.txt"

        /** The bridge lines for the choices; built-in ones come from the APK's assets. */
        fun bridgeLines(context: Context, choices: Choices): Bridges.Result = when (choices.bridgeSource) {
            BridgeSource.CUSTOM -> Bridges.parse(choices.bridgeText, Bridges.TRANSPORTS_AVAILABLE)
            BridgeSource.BUILT_IN -> try {
                Bridges.parse(
                    context.assets.open(BUILTIN_ASSET).bufferedReader().use { it.readText() },
                    Bridges.TRANSPORTS_AVAILABLE,
                )
            } catch (e: java.io.IOException) {
                Bridges.Result.Error(Bridges.Problem.None())
            }
        }
    }
}

/** User-facing text for a bridge problem. */
object BridgeMessages {
    fun text(context: Context, p: Bridges.Problem, source: BridgeSource): String = when (p) {
        is Bridges.Problem.None ->
            if (source == BridgeSource.BUILT_IN) context.getString(R.string.bridges_builtin_missing)
            else context.getString(R.string.bridges_none)
        is Bridges.Problem.TooMany -> context.getString(R.string.bridges_too_many, p.max)
        is Bridges.Problem.Snowflake -> context.getString(R.string.bridges_snowflake, p.line)
        is Bridges.Problem.UnknownType -> context.getString(R.string.bridges_unknown, p.line, p.type.take(40))
        is Bridges.Problem.Characters -> context.getString(R.string.bridges_characters, p.line)
        is Bridges.Problem.TooLong -> context.getString(R.string.bridges_too_long, p.line)
        is Bridges.Problem.Ipv6 -> context.getString(R.string.bridges_ipv6, p.line)
        is Bridges.Problem.Address -> context.getString(R.string.bridges_address, p.line, p.address.take(60))
        is Bridges.Problem.Fingerprint -> context.getString(R.string.bridges_fingerprint, p.line)
        is Bridges.Problem.MissingArg -> context.getString(R.string.bridges_missing_arg, p.line, p.type, p.arg)
        is Bridges.Problem.NeedsTransport -> context.getString(R.string.bridges_needs_transport, p.line, p.type)
    }
}
