// SPDX-License-Identifier: GPL-3.0-or-later
package org.antumbra.welcome

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.IBinder

/**
 * Runs in the foreground from Start until shutdown. It keeps this process
 * (and with it the session's choices, which exist only in memory) alive, so
 * that the state provider keeps answering started = 1, and so that the
 * shutdown broadcast reaches the app. Its ongoing notification carries a
 * "Quick power off" action, reachable from the notification shade at any
 * time.
 */
class SessionService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!Session.current().started) {
            // Restarted in a new process that knows no session.
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, notification(this), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "session"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            context.startForegroundService(Intent(context, SessionService::class.java))
        }

        private fun notification(context: Context): Notification {
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, context.getString(R.string.channel_session), NotificationManager.IMPORTANCE_LOW)
                    .apply { setShowBadge(false) },
            )
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, StatusActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE,
            )
            val powerOff = PendingIntent.getBroadcast(
                context, 1,
                Intent(context, QuickPowerOffReceiver::class.java),
                PendingIntent.FLAG_IMMUTABLE,
            )
            val action = Notification.Action.Builder(
                Icon.createWithResource(context, R.drawable.ic_power),
                context.getString(R.string.tile_label),
                powerOff,
            ).setAuthenticationRequired(false).build()
            return Notification.Builder(context, CHANNEL)
                .setSmallIcon(R.drawable.ic_launcher_monochrome)
                .setContentTitle(context.getString(R.string.notification_title))
                .setContentText(context.getString(R.string.notification_text))
                .setContentIntent(open)
                .setOngoing(true)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
                .addAction(action)
                .build()
        }
    }
}
