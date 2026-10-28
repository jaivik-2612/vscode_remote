// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import org.antumbra.welcome.EmergencyNumbers
import org.antumbra.welcome.EmergencyTexts
import org.antumbra.welcome.EmergencyUi
import org.antumbra.welcome.NumberReading
import org.antumbra.welcome.PositionFormat
import org.antumbra.welcome.PositionRefusal
import org.antumbra.welcome.PositionState
import org.antumbra.welcome.PositionTexts
import org.antumbra.welcome.PositionUi
import org.antumbra.welcome.R

/**
 * The emergency card (WEL10), on the Welcome and status screens: the
 * general emergency number Android lists now, in large digits; the state
 * lines (no SIM, SIM locked, radio off, VoLTE not connected) that say this
 * phone can still try, and point to the other phone too; "Show my
 * position", one fix from the satellite receiver, shown here only. Every
 * line is its own node with its own test tag, so that CI reads them one by
 * one. The pinned Emergency call button stays as it is.
 */
@Composable
fun EmergencyCard(
    emergency: EmergencyUi,
    position: PositionUi,
    onShowPosition: () -> Unit,
    onStopPosition: () -> Unit,
    onHidePosition: () -> Unit,
) {
    SectionTitle(stringResource(R.string.card_emergency))
    Surface(
        shape = GroupShape,
        color = MaterialTheme.colorScheme.surfaceContainer,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("card_emergency"),
    ) {
        Column(Modifier.padding(20.dp)) {
            val n = emergency.reading
            // One number, or several Android ranks alike (each Android's, in its order).
            val numbers = EmergencyNumbers.shown(n)
            Text(
                stringResource(if (n is NumberReading.Several) R.string.emergency_numbers_label else R.string.emergency_number_label),
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.primary,
            )
            if (numbers.isNotEmpty()) {
                val spoken = if (n is NumberReading.Several) {
                    stringResource(R.string.emergency_numbers_spoken, numbers.joinToString(", ") { EmergencyNumbers.spoken(it) })
                } else {
                    stringResource(R.string.emergency_number_spoken, EmergencyNumbers.spoken(numbers.single()))
                }
                Text(
                    numbers.joinToString(EmergencyNumbers.BETWEEN),
                    style = if (n is NumberReading.Several) MaterialTheme.typography.displaySmall else MaterialTheme.typography.displayMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier
                        .testTag("emergency_number_value")
                        .semantics { contentDescription = spoken },
                )
            }
            CardLine(stringResource(EmergencyTexts.numberText(n)), "emergency_number_text")
            emergency.states.forEach {
                CardLine(stringResource(EmergencyTexts.text(it)), "emergency_state_${it.word}", MaterialTheme.colorScheme.onSurface)
            }
            if (EmergencyTexts.otherPhone(emergency.states)) {
                CardLine(stringResource(R.string.emergency_other_phone), "emergency_other_phone", MaterialTheme.colorScheme.onSurface)
            }
            Spacer(Modifier.height(16.dp))
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Spacer(Modifier.height(8.dp))
            PositionPart(emergency.refusal, position, onShowPosition, onStopPosition, onHidePosition)
        }
    }
}

@Composable
private fun CardLine(text: String, tag: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant, style: TextStyle? = null) {
    Spacer(Modifier.height(8.dp))
    Text(text, style = style ?: MaterialTheme.typography.bodyMedium, color = color, modifier = Modifier.testTag(tag))
}

/** "Show my position": its explanation, the search, or the position in large type. */
@Composable
private fun PositionPart(
    refusal: PositionRefusal?,
    p: PositionUi,
    onShow: () -> Unit,
    onStop: () -> Unit,
    onHide: () -> Unit,
) {
    val s = p.state
    when (s) {
        is PositionState.Looking -> {
            CardLine(stringResource(R.string.position_looking), "position_status", MaterialTheme.colorScheme.onSurface)
            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = onStop, modifier = Modifier.fillMaxWidth().height(56.dp).testTag("position_stop")) {
                Text(stringResource(R.string.position_stop), style = MaterialTheme.typography.titleMedium)
            }
            return
        }
        is PositionState.Found -> Coordinates(s, p.now)
        is PositionState.Refused -> CardLine(stringResource(PositionTexts.refusal(s.why)), "position_status", MaterialTheme.colorScheme.error)
        is PositionState.Ended -> CardLine(stringResource(PositionTexts.end(s.why)), "position_status", MaterialTheme.colorScheme.onSurface)
        PositionState.Idle -> {
            CardLine(stringResource(R.string.position_detail), "position_detail")
            CardLine(stringResource(R.string.position_detail_apps), "position_detail_apps")
        }
    }
    PositionTexts.offLine(p)?.let { CardLine(stringResource(it), "position_location") }
    if (refusal != null && s != PositionState.Refused(refusal)) {
        CardLine(stringResource(PositionTexts.refusal(refusal)), "position_refusal", MaterialTheme.colorScheme.error)
    }
    Spacer(Modifier.height(12.dp))
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.fillMaxWidth()) {
        if (s is PositionState.Found) {
            OutlinedButton(onClick = onHide, modifier = Modifier.weight(1f).height(56.dp).testTag("position_hide")) {
                Text(stringResource(R.string.position_hide), style = MaterialTheme.typography.titleMedium)
            }
        }
        OutlinedButton(
            onClick = onShow,
            enabled = refusal == null,
            modifier = Modifier.weight(1f).height(56.dp).testTag("position_button"),
        ) {
            Text(stringResource(R.string.position_button), style = MaterialTheme.typography.titleMedium)
        }
    }
}

/** The position in large type, sent nowhere: latitude, longitude, the line for a map, accuracy, age. */
@Composable
private fun Coordinates(f: PositionState.Found, now: Long) {
    val (latText, lat) = PositionFormat.latitude(f.fix.latitude)
    val (lonText, lon) = PositionFormat.longitude(f.fix.longitude)
    CardLine(stringResource(R.string.position_lat_label), "position_lat_label", style = MaterialTheme.typography.labelLarge)
    Text(
        stringResource(latText, lat),
        style = MaterialTheme.typography.displaySmall,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.testTag("position_lat"),
    )
    CardLine(stringResource(R.string.position_lon_label), "position_lon_label", style = MaterialTheme.typography.labelLarge)
    Text(
        stringResource(lonText, lon),
        style = MaterialTheme.typography.displaySmall,
        color = MaterialTheme.colorScheme.onSurface,
        modifier = Modifier.testTag("position_lon"),
    )
    CardLine(stringResource(R.string.position_map, PositionFormat.map(f.fix.latitude, f.fix.longitude)), "position_map")
    PositionFormat.accuracy(f.fix.accuracyM)?.let { CardLine(stringResource(R.string.position_accuracy, it), "position_accuracy") }
    val age = PositionFormat.ageMinutes(f.at, now)
    CardLine(
        if (age == 0) stringResource(R.string.position_age_now) else pluralStringResource(R.plurals.position_age, age, age),
        "position_age",
    )
    if (f.fix.mock) CardLine(stringResource(R.string.position_mock), "position_mock", MaterialTheme.colorScheme.onSurface)
}
