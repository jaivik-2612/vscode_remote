// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.StatusBarManager
import android.content.ComponentName
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
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
import org.antumbra.welcome.ui.StatusScreen
import org.antumbra.welcome.ui.StatusUi

/** Screen 2, after Start. Also the "Antumbra" entry in the launcher. */
class StatusActivity : ComponentActivity() {
    private var check by mutableStateOf<AddOnCheck?>(null)
    private var message by mutableStateOf<String?>(null)
    private var messageIsError by mutableStateOf(false)

    @OptIn(ExperimentalComposeUiApi::class)
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            val session by Session.state.collectAsState()
            AntumbraTheme {
                Surface(color = MaterialTheme.colorScheme.surface, modifier = Modifier.fillMaxSize()) {
                    Box(Modifier.semantics { testTagsAsResourceId = true }) {
                        StatusScreen(
                            ui = StatusUi(
                                session = session,
                                check = check,
                                policyFailures = WelcomeModel.policyFailures,
                                wifiNotOn = WelcomeModel.wifiNotOn,
                                canPowerOff = PanicOff.canPowerOff(this@StatusActivity),
                                message = message,
                                messageIsError = messageIsError,
                            ),
                            onOpenWelcome = ::openWelcome,
                            onWifiSettings = { startActivity(Intent(Settings.ACTION_WIFI_SETTINGS)) },
                            onAddTile = ::addTile,
                            onPowerOff = {
                                message = PanicOff.trigger(this@StatusActivity).ifEmpty { null }
                                messageIsError = true
                            },
                            onEmergencyCall = ::emergencyCall,
                        )
                    }
                }
            }
        }
        // Poll the status page every two seconds while the screen is visible.
        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) {
                while (true) {
                    check = withContext(Dispatchers.IO) { AddOnCheck.run() }
                    delay(2000)
                }
            }
        }
    }

    private fun openWelcome() {
        // Re-enables Welcome as home if this app is the device owner.
        runCatching { Home.claim(this) }
        Home.showWelcome(this)
        finish()
    }

    private fun emergencyCall() {
        if (!EmergencyCall.open(this)) {
            message = getString(R.string.emergency_call_unavailable)
            messageIsError = true
        }
    }

    private fun addTile() {
        val statusBar = getSystemService(StatusBarManager::class.java)
        statusBar.requestAddTileService(
            ComponentName(this, PanicTileService::class.java),
            getString(R.string.tile_label),
            Icon.createWithResource(this, R.drawable.ic_power),
            mainExecutor,
        ) { result ->
            messageIsError = false
            message = getString(
                when (result) {
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED,
                    StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED,
                    -> R.string.tile_added
                    else -> R.string.tile_not_added
                },
            )
        }
    }
}
