package com.example.livekit_flutter

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Foreground service whose only job is to satisfy Android 14+'s requirement
 * that MediaProjection (screen capture) be tied to a service of type
 * [ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION].
 *
 * The service must be running BEFORE flutter_webrtc calls
 * MediaProjectionManager.getMediaProjection(), otherwise Android throws
 * SecurityException("Media projections require a foreground service of type
 * ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION").
 */
class ScreenCaptureService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForegroundCompat()
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val channelId = "remote_desk_screen_capture"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(channelId) == null) {
                val ch = NotificationChannel(
                    channelId,
                    "Remote Desk screen sharing",
                    NotificationManager.IMPORTANCE_LOW
                )
                ch.description = "Active while your screen is being shared."
                nm.createNotificationChannel(ch)
            }
        }

        val notif: Notification =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, channelId)
                    .setContentTitle("Remote Desk")
                    .setContentText("Screen is being shared.")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .setOngoing(true)
                    .build()
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(this)
                    .setContentTitle("Remote Desk")
                    .setContentText("Screen is being shared.")
                    .setSmallIcon(android.R.drawable.ic_menu_view)
                    .setOngoing(true)
                    .build()
            }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notif)
        }
    }

    companion object {
        const val NOTIFICATION_ID = 0xC0DE
    }
}
