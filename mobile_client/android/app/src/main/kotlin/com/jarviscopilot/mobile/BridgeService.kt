package com.jarviscopilot.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/// Foreground service. Its only job is to keep the process alive so
/// the Dart WS bridge stays connected even when the user backgrounds
/// the app. The actual WS work runs in the Dart isolate; the service
/// just hosts the visible notification Android requires for long-lived
/// background activity.
///
/// On Android 14+ we MUST declare the FGS type in the manifest AND
/// pass it to startForeground for the FGS launch to succeed.
class BridgeService : Service() {

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel(this)
        val pi = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth) // placeholder
            .setContentTitle(getString(R.string.bridge_notification_title))
            .setContentText(getString(R.string.bridge_notification_text))
            .setOngoing(true)
            .setContentIntent(pi)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // 30 (Q) had startForeground(int, Notification, int) — but the
            // FGS-type constant only became required on 14 (UDC=34).
            startForeground(NOTIFICATION_ID, notif,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notif)
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val CHANNEL_ID = "jarviscopilot_bridge"
        private const val NOTIFICATION_ID = 314159

        fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                ctx.getString(R.string.bridge_channel_name),
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = ctx.getString(R.string.bridge_notification_text)
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }
}
