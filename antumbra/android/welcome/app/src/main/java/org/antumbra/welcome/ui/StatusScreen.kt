// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.NumberFormat
import org.antumbra.welcome.AddOnCheck
import org.antumbra.welcome.R
import org.antumbra.welcome.SessionState
import org.antumbra.welcome.TorMode

data class StatusUi(
    val session: SessionState,
    /** Null before the first check. */
    val check: AddOnCheck? = null,
    val policyFailures: List<String> = emptyList(),
    /** Emergency off powers off (true) or restarts (false). */
    val canPowerOff: Boolean = false,
    /** A message, such as why Emergency off failed (an error) or that the tile was added. */
    val message: String? = null,
    val messageIsError: Boolean = false,
)

/**
 * Screen 2, after Start: Tor's bootstrap progress and the tracker filter's
 * counters, both read from http://127.0.0.1:5380/status, the session's
 * choices, and "Power off now".
 */
@Composable
fun StatusScreen(
    ui: StatusUi,
    onOpenWelcome: () -> Unit,
    onWifiSettings: () -> Unit,
    onAddTile: () -> Unit,
    onPowerOff: () -> Unit,
    scrollState: ScrollState = rememberScrollState(),
) {
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
            if (ui.session.started) Started(ui, onWifiSettings, onAddTile) else NotStarted(ui, onOpenWelcome)
            Spacer(Modifier.height(24.dp))
        }
        // "Power off now" stays on screen, above the navigation bar.
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier
                    .navigationBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 16.dp),
            ) {
                PowerOff(ui, onPowerOff)
            }
        }
    }
}

@Composable
private fun NotStarted(ui: StatusUi, onOpenWelcome: () -> Unit) {
    Title(stringResource(R.string.app_name))
    Spacer(Modifier.height(8.dp))
    Body(stringResource(R.string.status_not_started))
    // Tor's network is on although this process knows no session:
    // Welcome was restarted after Start.
    if (ui.check?.status?.module?.torNetworkEnabled == true) {
        Spacer(Modifier.height(16.dp))
        WarningBanner(stringResource(R.string.status_lost), tag = "warning_lost")
    }
    Spacer(Modifier.height(24.dp))
    Button(onClick = onOpenWelcome, modifier = Modifier.fillMaxWidth().height(56.dp).testTag("open_welcome")) {
        Text(stringResource(R.string.status_open_welcome))
    }
}

@Composable
private fun Started(ui: StatusUi, onWifiSettings: () -> Unit, onAddTile: () -> Unit) {
    val s = ui.session
    Title(stringResource(R.string.status_title))
    Spacer(Modifier.height(8.dp))
    Body(
        when (s.torMode) {
            TorMode.DIRECT -> stringResource(R.string.status_mode_direct)
            TorMode.BRIDGES -> pluralStringResource(R.plurals.status_mode_bridges, s.bridges.size, s.bridges.size)
            TorMode.OFFLINE -> stringResource(R.string.status_mode_offline)
        },
    )
    if (ui.policyFailures.isNotEmpty()) {
        Spacer(Modifier.height(16.dp))
        WarningBanner(
            stringResource(R.string.policy_failures, ui.policyFailures.joinToString()),
            tag = "warning_policies",
        )
    }

    Card(stringResource(R.string.card_tor), "card_tor") { TorPart(ui) }
    Card(stringResource(R.string.card_filter), "card_filter") { FilterPart(ui) }
    Card(stringResource(R.string.card_session), "card_session") { SessionPart(ui) }

    Spacer(Modifier.height(24.dp))
    OutlinedButton(
        onClick = onWifiSettings,
        enabled = s.torMode != TorMode.OFFLINE,
        modifier = Modifier.fillMaxWidth().height(56.dp).testTag("wifi_settings"),
    ) { Text(stringResource(R.string.wifi_settings)) }
    Spacer(Modifier.height(12.dp))
    OutlinedButton(
        onClick = onAddTile,
        modifier = Modifier.fillMaxWidth().height(56.dp).testTag("add_tile"),
    ) { Text(stringResource(R.string.add_tile)) }
    Spacer(Modifier.height(16.dp))
    Text(
        stringResource(if (ui.canPowerOff) R.string.power_off_detail_poweroff else R.string.power_off_detail_restart),
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 8.dp),
    )
}

@Composable
private fun PowerOff(ui: StatusUi, onPowerOff: () -> Unit) {
    if (ui.message != null) {
        Text(
            ui.message,
            color = if (ui.messageIsError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(bottom = 12.dp).testTag("status_message"),
        )
    }
    Button(
        onClick = onPowerOff,
        colors = ButtonDefaults.buttonColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
            contentColor = MaterialTheme.colorScheme.onErrorContainer,
        ),
        modifier = Modifier.fillMaxWidth().height(64.dp).testTag("poweroff_button"),
    ) {
        Text(stringResource(R.string.power_off_now), style = MaterialTheme.typography.titleMedium.copy(fontSize = 18.sp))
    }
}

@Composable
private fun TorPart(ui: StatusUi) {
    val module = ui.check?.status?.module
    val progress = module?.torBootstrap
    when {
        ui.session.torMode == TorMode.OFFLINE -> Body(stringResource(R.string.tor_offline_state), inset = false)
        ui.check == null -> Body(stringResource(R.string.tor_waiting), inset = false)
        !ui.check.status.filterAnswered -> Body(stringResource(R.string.addon_not_answering), inset = false)
        module == null || progress == null -> Body(stringResource(R.string.tor_no_module_status), inset = false)
        else -> {
            LinearProgressIndicator(
                progress = { progress / 100f },
                modifier = Modifier.fillMaxWidth().height(8.dp).testTag("tor_progress"),
            )
            Spacer(Modifier.height(12.dp))
            Text(
                if (progress >= 100) stringResource(R.string.tor_connected) else stringResource(R.string.tor_progress, progress),
                style = MaterialTheme.typography.bodyLarge,
            )
            if (progress < 100 && module.torSummary != null) {
                Text(
                    module.torSummary,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun FilterPart(ui: StatusUi) {
    val f = ui.check?.status?.filter
    if (f == null) {
        Body(stringResource(if (ui.check == null) R.string.tor_waiting else R.string.filter_unreachable), inset = false)
        return
    }
    val n = NumberFormat.getIntegerInstance()
    ValueLine(stringResource(R.string.filter_queries), n.format(f.queries), "filter_queries")
    ValueLine(stringResource(R.string.filter_blocked), n.format(f.blocked), "filter_blocked")
    if (f.listLoaded) {
        ValueLine(stringResource(R.string.filter_list_size), n.format(f.listSize), "filter_list_size")
        ValueLine(stringResource(R.string.filter_list_version), f.listVersion.ifEmpty { "–" }, "filter_list_version")
    } else {
        Body(stringResource(R.string.filter_no_list), inset = false)
    }
}

@Composable
private fun SessionPart(ui: StatusUi) {
    val s = ui.session
    val on = stringResource(R.string.value_on)
    val off = stringResource(R.string.value_off)
    ValueLine(
        stringResource(R.string.row_tor),
        stringResource(
            when (s.torMode) {
                TorMode.DIRECT -> R.string.value_direct
                TorMode.BRIDGES -> R.string.value_bridges
                TorMode.OFFLINE -> R.string.value_offline
            },
        ),
    )
    ValueLine(stringResource(R.string.row_mac), stringResource(if (s.newMac) R.string.value_new else R.string.value_keep))
    ValueLine(stringResource(R.string.row_admin), if (s.admin) on else off)
    ValueLine(stringResource(R.string.row_unsafe), if (s.unsafeBrowser) on else off)
    // The property set by root counts first; the module's status file
    // (which tor's uid could also write) is only shown.
    val module = ui.check?.status?.module
    val hash = ui.check?.firewallHash ?: module?.firewallHash?.takeIf { module.firewallState == "live" }
    ValueLine(
        stringResource(R.string.row_firewall),
        if (hash != null) stringResource(R.string.value_firewall_live, hash.take(12))
        else stringResource(R.string.value_firewall_unknown),
        tag = "row_firewall",
    )
}

@Composable
private fun Card(title: String, tag: String, content: @Composable ColumnScope.() -> Unit) {
    SectionTitle(title)
    Surface(
        shape = GroupShape,
        color = MaterialTheme.colorScheme.surfaceContainer,
        modifier = Modifier.fillMaxWidth().testTag(tag),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(4.dp), content = content)
    }
}

@Composable
private fun Title(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.headlineMedium,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.padding(horizontal = 8.dp).testTag("status_title"),
    )
}

/** Body text; [inset] lines it up with the title outside cards. */
@Composable
private fun Body(text: String, inset: Boolean = true) {
    Text(
        text,
        style = MaterialTheme.typography.bodyLarge,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = if (inset) 8.dp else 0.dp),
    )
}
