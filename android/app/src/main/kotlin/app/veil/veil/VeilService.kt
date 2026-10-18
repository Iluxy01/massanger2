package app.veil.veil

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * «Мгновенные уведомления»: держит приложение запущенным, пока оно свёрнуто или
 * закрыто, чтобы соединения с ретрансляторами не обрывались и сообщения
 * приходили сразу. Видна как тихий значок «Veil на связи» в шторке.
 *
 * Если приложения нет (телефон перезагрузили, Veil обновили, Android выгрузил
 * его ради памяти) — служба сама поднимает его без окна. Окно, открытое потом,
 * подключается к нему же.
 */
class VeilService : Service() {
    private var network: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        VeilLink.installCrashLog(this)
        running = true
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        VeilLink.note(this, if (intent == null) "служба: перезапущена системой" else "служба: запуск")
        if (!foreground()) {
            // Система не разрешила (например, запуск из фона) — не работаем.
            running = false
            stopSelf()
            return START_NOT_STICKY
        }
        if (!VeilLink.instant(this)) {
            // Выключили, пока служба перезапускалась.
            stopSelf()
            return START_NOT_STICKY
        }
        ensureApp()
        watchNetwork()
        VeilAlarm.schedule(this)
        // Выгрузили ради памяти — Android перезапустит службу, а она — приложение.
        return START_STICKY
    }

    private fun foreground(): Boolean {
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
        return try {
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING)
            } else {
                startForeground(ID, notification)
            }
            true
        } catch (e: Exception) {
            VeilLink.note(this, "служба: Android не дал работать на виду (${e.javaClass.simpleName})")
            false
        }
    }

    /** Приложения нет в памяти — поднять его без окна. */
    private fun ensureApp() {
        if (FlutterEngineCache.getInstance().get(MainActivity.ENGINE) != null) return
        try {
            VeilLink.hold(this, 20_000L)
            VeilLink.engine(this, run = true)
        } catch (_: Exception) {
        }
    }

    /** Сменилась сеть (Wi-Fi ⇄ мобильная) — сразу переподключиться. */
    private fun watchNetwork() {
        if (network != null) return
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val app = applicationContext
            val cb = object : ConnectivityManager.NetworkCallback() {
                // Сразу при подписке Android сообщает текущую сеть — это не смена.
                private var last: Network? = cm.activeNetwork

                override fun onAvailable(n: Network) {
                    if (n == last) return
                    last = n
                    VeilLink.hold(app, 15_000L)
                    VeilLink.tick("net")
                }
            }
            cm.registerDefaultNetworkCallback(cb)
            network = cb
        } catch (_: Exception) {
        }
    }

    /** Окно смахнули из недавних: служба остаётся, но через пару секунд проверим, жива ли. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        VeilLink.note(this, "окно смахнули из недавних")
        VeilAlarm.schedule(this, 5_000L)
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        VeilLink.note(this, "служба: остановлена")
        running = false
        network?.let {
            try {
                (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
                    .unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        network = null
        if (!VeilLink.instant(this)) VeilAlarm.cancel(this)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL = "veil_link"
        const val ID = 7001

        @Volatile
        var running = false
    }
}
