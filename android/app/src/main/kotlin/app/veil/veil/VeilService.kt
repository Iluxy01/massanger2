package app.veil.veil

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * «Мгновенные уведомления»: держит приложение запущенным, пока оно свёрнуто,
 * чтобы соединения с ретрансляторами не обрывались и сообщения приходили сразу.
 * Сама служба ничего не делает — работу выполняет приложение (Flutter), которое
 * благодаря ей Android не выгружает. Видна как тихий значок в шторке.
 */
class VeilService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26 && manager != null) {
            val channel = NotificationChannel(
                CHANNEL,
                "Связь с друзьями",
                NotificationManager.IMPORTANCE_MIN,
            )
            channel.description = "Пока включено, сообщения приходят сразу"
            channel.setShowBadge(false)
            manager.createNotificationChannel(channel)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Veil на связи")
            .setContentText("Сообщения приходят сразу")
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setContentIntent(open)
            .build()
        try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else {
                startForeground(ID, notification)
            }
        } catch (e: Exception) {
            // Система не разрешила (например, запуск из фона) — просто не работаем.
            stopSelf()
        }
        // Если Android всё же выгрузит приложение, не перезапускаемся «пустыми».
        return START_NOT_STICKY
    }

    companion object {
        const val CHANNEL = "veil_link"
        const val ID = 7001
    }
}
