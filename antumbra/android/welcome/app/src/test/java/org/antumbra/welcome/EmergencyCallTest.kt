// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.admin.DevicePolicyManager
import android.media.AudioManager
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** WEL7 without Android: the lock task's features, when Panic off waits, and the texts. */
class EmergencyCallTest {
    private val minute = 60_000L

    @Test
    fun lockTaskLetsEmergencyCallsThroughAndNothingElse() {
        val f = Home.LOCK_TASK_FEATURES
        assertTrue(f and DevicePolicyManager.LOCK_TASK_FEATURE_KEYGUARD != 0)
        assertTrue(f and DevicePolicyManager.LOCK_TASK_FEATURE_GLOBAL_ACTIONS != 0)
        // No way out of the locked task before Start.
        listOf(
            DevicePolicyManager.LOCK_TASK_FEATURE_HOME,
            DevicePolicyManager.LOCK_TASK_FEATURE_OVERVIEW,
            DevicePolicyManager.LOCK_TASK_FEATURE_NOTIFICATIONS,
        ).forEach { assertEquals(0, f and it) }
    }

    @Test
    fun onlyThePhoneServiceModesCountAsACall() {
        assertTrue(CallRecord.isCallMode(AudioManager.MODE_IN_CALL))
        assertTrue(CallRecord.isCallMode(AudioManager.MODE_CALL_REDIRECT))
        // Any app may set these: ringing, VoIP, screening.
        listOf(
            AudioManager.MODE_NORMAL, AudioManager.MODE_RINGTONE, AudioManager.MODE_IN_COMMUNICATION,
            AudioManager.MODE_CALL_SCREENING, AudioManager.MODE_COMMUNICATION_REDIRECT,
        ).forEach { assertFalse("mode $it", CallRecord.isCallMode(it)) }
    }

    @Test
    fun panicOffWaitsDuringACallAndInCallbackMode() {
        val r = CallRecord()
        assertNull(r.hold(callNow = false, callbackMode = false, now = 1_000))
        assertEquals(PanicHold.CALL, r.hold(callNow = true, callbackMode = false, now = 1_000))
        assertEquals(PanicHold.CALLBACK_MODE, r.hold(callNow = false, callbackMode = true, now = 1_000))
        // The listener saw a call that the mode read now no longer shows: still a call.
        r.onMode(AudioManager.MODE_IN_CALL, now = 1_000)
        assertEquals(PanicHold.CALL, r.hold(callNow = false, callbackMode = false, now = 2_000))
    }

    @Test
    fun panicOffWaitsFiveMinutesAfterAnyCall() {
        val r = CallRecord()
        val end = 10 * minute
        r.onMode(AudioManager.MODE_RINGTONE, now = end - 3 * minute)
        r.onMode(AudioManager.MODE_IN_CALL, now = end - 2 * minute)
        r.onMode(AudioManager.MODE_NORMAL, now = end)
        assertEquals(end, r.lastEnd)
        assertEquals(PanicHold.AFTER_CALL, r.hold(callNow = false, callbackMode = false, now = end))
        assertEquals(5, r.minutesLeft(end))
        assertEquals(5, r.minutesLeft(end + 1))
        assertEquals(1, r.minutesLeft(end + 4 * minute + 59_999))
        assertEquals(PanicHold.AFTER_CALL, r.hold(callNow = false, callbackMode = false, now = end + 5 * minute - 1))
        assertNull(r.hold(callNow = false, callbackMode = false, now = end + 5 * minute))
        assertEquals(0, r.minutesLeft(end + 60 * minute))
        // A clock that went backwards counts as a call that just ended.
        assertEquals(5, r.minutesLeft(end - minute))
    }

    @Test
    fun ringingOrVoipAloneDoesNotHold() {
        val r = CallRecord()
        r.onMode(AudioManager.MODE_RINGTONE, now = 0)
        r.onMode(AudioManager.MODE_NORMAL, now = minute)
        r.onMode(AudioManager.MODE_IN_COMMUNICATION, now = 2 * minute)
        r.onMode(AudioManager.MODE_NORMAL, now = 3 * minute)
        assertNull(r.lastEnd)
        assertNull(r.hold(callNow = false, callbackMode = false, now = 3 * minute))
    }

    @Test
    fun theCallInProgressFollowsTheMode() {
        val r = CallRecord()
        assertFalse(r.inCall)
        r.onMode(AudioManager.MODE_IN_CALL, now = 0)
        assertTrue(r.inCall)
        r.onMode(AudioManager.MODE_CALL_REDIRECT, now = minute)
        assertTrue(r.inCall)
        r.onMode(AudioManager.MODE_NORMAL, now = 2 * minute)
        assertFalse(r.inCall)
    }

    /** "Return to call" (TelecomManager.showInCallScreen) needs READ_PHONE_STATE, which Welcome grants itself. */
    @Test
    fun returnToCallHasItsPermissionAndText() {
        val manifest = File("src/main/AndroidManifest.xml").readText()
        assertTrue(manifest.contains("<uses-permission android:name=\"android.permission.READ_PHONE_STATE\" />"))
        val xml = File("src/main/res/values/strings.xml").readText()
        assertTrue(xml.contains("<string name=\"return_to_call\">Return to call</string>"))
    }

    @Test
    fun callbackWindowIsAndroidsOwn() {
        assertEquals(5 * minute, CallWatch.CALLBACK_WINDOW_MS)
        assertEquals("android.intent.action.DIAL_EMERGENCY", EmergencyCall.ACTION_DIAL_EMERGENCY)
    }

    /** What the person reads: "Panic off" only, and no emergency number anywhere. */
    @Test
    fun textsSayPanicOffAndNameNoNumber() {
        val xml = File("src/main/res/values/strings.xml").readText()
        assertFalse(xml.contains("Emergency off", ignoreCase = true))
        assertTrue(xml.contains("<string name=\"tile_label\">Panic off</string>"))
        val texts = Regex("<(string|item)[^>]*>([^<]*)</(string|item)>").findAll(xml)
            .map { it.groupValues[2] }
            .filter { it.contains("emergency", ignoreCase = true) }
            .toList()
        assertTrue(texts.size >= 5)
        texts.forEach { assertFalse(it, Regex("\\d{2,}").containsMatchIn(it.replace("%1\$d", ""))) }
    }
}
