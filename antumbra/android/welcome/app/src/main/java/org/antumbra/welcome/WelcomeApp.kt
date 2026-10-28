// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter

class WelcomeApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // The system sends ACTION_SHUTDOWN to registered receivers only
        // (FLAG_RECEIVER_REGISTERED_ONLY in ShutdownThread), and defers it
        // for cached processes. Before Start the Welcome screen is in the
        // foreground; after Start the session service is. Either way this
        // process is not cached when the phone shuts down or restarts.
        registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == Intent.ACTION_SHUTDOWN) BootState.atShutdown(context)
                }
            },
            IntentFilter(Intent.ACTION_SHUTDOWN),
            Context.RECEIVER_NOT_EXPORTED,
        )
        // Quick power off waits during and after a call; for that, the process
        // follows the calls from its start (the same lifetime as above).
        CallWatch.start(this)
        // The radio line and the SIM's state (WEL8): a service-state
        // listener that gets no location (INCLUDE_LOCATION_DATA_NONE).
        CellWatch.start(this)
        // Show my position (WEL10): a search ends when the screen goes
        // off, and a Location left on by an earlier process goes off when
        // no call holds.
        registerReceiver(
            object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == Intent.ACTION_SCREEN_OFF) Position.leave(context)
                }
            },
            IntentFilter(Intent.ACTION_SCREEN_OFF),
            Context.RECEIVER_NOT_EXPORTED,
        )
        Position.atProcessStart(this)
    }
}
