// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.antumbra.welcome.BridgeSource
import org.antumbra.welcome.Bridges
import org.antumbra.welcome.Choices
import org.antumbra.welcome.R
import org.antumbra.welcome.TorMode

/** What the Welcome screen shows besides the choices themselves. */
data class WelcomeUi(
    val choices: Choices = Choices(),
    val bridgeError: String? = null,
    val notDeviceOwner: Boolean = false,
    /** Null while the first check is running. */
    val addOnPresent: Boolean? = null,
    val starting: Boolean = false,
    /** Why Start was refused (not the device owner, a protection failed, a session already held). */
    val startError: String? = null,
)

/**
 * Screen 1: the session choices, as Tails' Welcome Screen asks them, and a
 * large "Start Antumbra" button that stays on screen.
 */
@Composable
fun WelcomeScreen(
    ui: WelcomeUi,
    onChoices: (Choices) -> Unit,
    onStart: () -> Unit,
    scrollState: ScrollState = rememberScrollState(),
) {
    val c = ui.choices
    Column(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        Column(
            modifier = Modifier
                .weight(1f)
                .fillMaxWidth()
                .verticalScroll(scrollState)
                .statusBarsPadding()
                .padding(horizontal = 16.dp),
        ) {
            Spacer(Modifier.height(24.dp))
            Text(
                stringResource(R.string.welcome_title),
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onSurface,
                modifier = Modifier
                    .padding(horizontal = 8.dp)
                    .testTag("welcome_title"),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                stringResource(R.string.welcome_intro),
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 8.dp),
            )
            if (ui.notDeviceOwner) {
                Spacer(Modifier.height(16.dp))
                WarningBanner(stringResource(R.string.warning_not_owner), tag = "warning_not_owner")
            }
            if (ui.addOnPresent == false) {
                Spacer(Modifier.height(16.dp))
                WarningBanner(stringResource(R.string.warning_no_addon), tag = "warning_no_addon")
            }

            SectionTitle(stringResource(R.string.section_tor))
            RowGroup(Modifier.selectableGroup()) {
                RadioRow(
                    stringResource(R.string.tor_direct), stringResource(R.string.tor_direct_detail),
                    selected = c.torMode == TorMode.DIRECT, tag = "tor_direct",
                    onSelect = { onChoices(c.copy(torMode = TorMode.DIRECT)) },
                )
                GroupDivider()
                RadioRow(
                    stringResource(R.string.tor_bridges), stringResource(R.string.tor_bridges_detail),
                    selected = c.torMode == TorMode.BRIDGES, tag = "tor_bridges",
                    onSelect = { onChoices(c.copy(torMode = TorMode.BRIDGES)) },
                )
                if (c.torMode == TorMode.BRIDGES) {
                    BridgeChoices(ui, onChoices)
                }
                GroupDivider()
                RadioRow(
                    stringResource(R.string.tor_offline), stringResource(R.string.tor_offline_detail),
                    selected = c.torMode == TorMode.OFFLINE, tag = "tor_offline",
                    onSelect = { onChoices(c.copy(torMode = TorMode.OFFLINE)) },
                )
            }

            SectionTitle(stringResource(R.string.section_network))
            RowGroup {
                SwitchRow(
                    stringResource(R.string.mac_title),
                    stringResource(if (c.newMac) R.string.mac_on else R.string.mac_off),
                    checked = c.newMac, tag = "switch_mac",
                    onCheckedChange = { onChoices(c.copy(newMac = it)) },
                )
            }

            SectionTitle(stringResource(R.string.section_storage))
            RowGroup {
                InfoRow(
                    stringResource(R.string.persistent_title), stringResource(R.string.persistent_detail),
                    tag = "row_persistent", enabled = false,
                )
            }

            SectionTitle(stringResource(R.string.section_additional))
            RowGroup {
                SwitchRow(
                    stringResource(R.string.admin_title), stringResource(R.string.admin_detail),
                    checked = c.admin, tag = "switch_admin",
                    onCheckedChange = { onChoices(c.copy(admin = it)) },
                )
                GroupDivider()
                // Shown, but off and disabled until the Unsafe Browser app
                // exists (W11): nothing in v0 would act on it.
                SwitchRow(
                    stringResource(R.string.unsafe_title), stringResource(R.string.unsafe_detail),
                    checked = false, tag = "switch_unsafe_browser", enabled = false,
                    onCheckedChange = {},
                )
            }
            Spacer(Modifier.height(24.dp))
        }

        // The Start button stays visible above the navigation bar and the keyboard.
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .navigationBarsPadding()
                    .imePadding()
                    .padding(horizontal = 16.dp, vertical = 16.dp),
            ) {
                if (ui.startError != null) {
                    Text(
                        ui.startError,
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier
                            .fillMaxWidth()
                            .widthIn(max = 480.dp)
                            .padding(bottom = 12.dp)
                            .testTag("start_error"),
                    )
                }
                Button(
                    onClick = onStart,
                    enabled = !ui.starting,
                    contentPadding = ButtonDefaults.ContentPadding,
                    modifier = Modifier
                        .fillMaxWidth()
                        .widthIn(max = 480.dp)
                        .height(64.dp)
                        .testTag("start_button"),
                ) {
                    Text(
                        stringResource(if (ui.starting) R.string.starting else R.string.start),
                        style = MaterialTheme.typography.titleMedium.copy(fontSize = 18.sp),
                    )
                }
            }
        }
    }
}

@Composable
private fun BridgeChoices(ui: WelcomeUi, onChoices: (Choices) -> Unit) {
    val c = ui.choices
    Column(Modifier.selectableGroup()) {
        RadioRow(
            stringResource(R.string.bridges_builtin),
            stringResource(
                if (Bridges.TRANSPORTS_AVAILABLE) R.string.bridges_builtin_detail else R.string.bridges_builtin_unavailable,
            ),
            selected = c.bridgeSource == BridgeSource.BUILT_IN, tag = "bridges_builtin", indent = true,
            enabled = Bridges.TRANSPORTS_AVAILABLE,
            onSelect = { onChoices(c.copy(bridgeSource = BridgeSource.BUILT_IN)) },
        )
        RadioRow(
            stringResource(R.string.bridges_custom), stringResource(R.string.bridges_custom_detail),
            selected = c.bridgeSource == BridgeSource.CUSTOM, tag = "bridges_custom", indent = true,
            onSelect = { onChoices(c.copy(bridgeSource = BridgeSource.CUSTOM)) },
        )
    }
    if (c.bridgeSource == BridgeSource.CUSTOM) {
        OutlinedTextField(
            value = c.bridgeText,
            onValueChange = { onChoices(c.copy(bridgeText = it)) },
            label = { Text(stringResource(R.string.bridges_field_label)) },
            supportingText = { Text(ui.bridgeError ?: stringResource(R.string.bridges_field_help)) },
            isError = ui.bridgeError != null,
            minLines = 3,
            maxLines = 8,
            textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            // A password keyboard type: keyboards neither learn nor suggest
            // from it, so bridge lines do not end up in the keyboard's
            // dictionary on flash. The text itself stays visible.
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
            modifier = Modifier
                .fillMaxWidth()
                .padding(start = 16.dp, end = 16.dp, bottom = 16.dp)
                .testTag("bridges_text"),
        )
    } else if (ui.bridgeError != null) {
        Text(
            ui.bridgeError,
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(start = 56.dp, end = 16.dp, bottom = 16.dp),
        )
    }
    Spacer(Modifier.height(4.dp))
}

