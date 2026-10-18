package app.veil.veil

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.BatteryManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Связь Android-части с приложением (Flutter) — то, что нужно и без окна:
 * служба «на связи», короткое удержание процессора от сна, заряд, сеть.
 */
object VeilLink {
    private const val LINK = "veil/link"
    private var wake: PowerManager.WakeLock? = null
    private val main = Handler(Looper.getMainLooper())

    fun prefs(ctx: Context) =
        ctx.getSharedPreferences(MainActivity.PREFS, Context.MODE_PRIVATE)

    fun instant(ctx: Context): Boolean = prefs(ctx).getBoolean(MainActivity.INSTANT, false)

    /**
     * Приложение (Flutter) — одно на процесс, и создаём его всегда мы сами, а
     * не окно: окно со входом по отпечатку уничтожало его вместе с собой, даже
     * когда служба «на связи» должна была держать его живым (и потом, открываясь,
     * цеплялось к уже уничтоженному — вылет). Уничтоженное сразу убирается из кэша.
     *
     * [run] — запустить сразу (служба, без окна); окно запускает его само.
     */
    @Synchronized
    fun engine(ctx: Context, run: Boolean): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(MainActivity.ENGINE)?.let { return it }
        val app = ctx.applicationContext
        val engine = FlutterEngine(app)
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() {}

            override fun onEngineWillDestroy() {
                if (cache.get(MainActivity.ENGINE) === engine) cache.remove(MainActivity.ENGINE)
            }
        })
        register(engine, app)
        cache.put(MainActivity.ENGINE, engine)
        if (run) {
            engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
            // Окна нет: приложение «свёрнуто» — без кадров и анимаций, с уведомлениями.
            engine.lifecycleChannel.appIsPaused()
        }
        return engine
    }

    // ───────────── журнал вылетов ─────────────

    private var crashLog = false

    /** Если Veil всё же упадёт — записать причину; покажем в журнале при запуске. */
    @Synchronized
    fun installCrashLog(ctx: Context) {
        if (crashLog) return
        crashLog = true
        val file = File(ctx.applicationContext.filesDir, "last_crash.txt")
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val sw = StringWriter()
                error.printStackTrace(PrintWriter(sw))
                val time = SimpleDateFormat("dd.MM HH:mm:ss", Locale.US).format(Date())
                file.writeText("$time [${thread.name}] ${sw.toString().take(6000)}")
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, error)
        }
    }

    private fun takeCrash(ctx: Context): String? = try {
        val file = File(ctx.applicationContext.filesDir, "last_crash.txt")
        if (file.exists()) file.readText().also { file.delete() } else null
    } catch (_: Exception) {
        null
    }

    /**
     * Не дать процессору уснуть [ms] миллисекунд (сам отпустится по сроку):
     * пока переподключаемся и забираем новые сообщения.
     */
    @Synchronized
    fun hold(ctx: Context, ms: Long) {
        try {
            val w = wake ?: (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "veil:link")
                .also {
                    it.setReferenceCounted(false)
                    wake = it
                }
            w.acquire(ms.coerceIn(1_000L, 30_000L))
        } catch (_: Exception) {
        }
    }

    @Synchronized
    fun release() {
        try {
            wake?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
    }

    /** Разбудить приложение: проверить соединения и забрать новое. */
    fun tick(reason: String) {
        main.post {
            val engine = FlutterEngineCache.getInstance().get(MainActivity.ENGINE) ?: return@post
            try {
                MethodChannel(engine.dartExecutor.binaryMessenger, LINK).invokeMethod("tick", reason)
            } catch (_: Exception) {
            }
        }
    }

    fun unrestricted(ctx: Context): Boolean = try {
        (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(ctx.packageName)
    } catch (_: Exception) {
        false
    }

    /** Попросить «без ограничений батареи» (системное окно «Разрешить?»). */
    private fun askUnrestricted(ctx: Context): Boolean {
        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${ctx.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val list = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val details = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${ctx.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        for (intent in listOf(direct, list, details)) {
            try {
                ctx.startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
            } catch (_: SecurityException) {
            }
        }
        return false
    }

    /** Настройки уведомлений Veil (если их выключили — разрешения уже не спросить). */
    private fun openNotificationSettings(ctx: Context): Boolean {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, ctx.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            ctx.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun startService(ctx: Context): Boolean = try {
        ContextCompat.startForegroundService(ctx, Intent(ctx, VeilService::class.java))
        true
    } catch (_: Exception) {
        // Android не разрешил запуск из фона — попробуем при следующем случае.
        false
    }

    /** Каналы, которые работают и в приложении без окна (запущенном службой). */
    fun register(engine: FlutterEngine, context: Context) {
        val app = context.applicationContext
        val messenger = engine.dartExecutor.binaryMessenger
        // Мгновенные уведомления: включить/выключить службу «на связи».
        MethodChannel(messenger, "veil/service").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    // Окно закроют — приложение останется жить вместе со службой
                    // (см. MainActivity.onDestroy).
                    prefs(app).edit().putBoolean(MainActivity.INSTANT, true).apply()
                    result.success(startService(app))
                }
                "stop" -> {
                    prefs(app).edit().putBoolean(MainActivity.INSTANT, false).apply()
                    app.stopService(Intent(app, VeilService::class.java))
                    VeilAlarm.cancel(app)
                    release()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, LINK).setMethodCallHandler { call, result ->
            when (call.method) {
                "hold" -> {
                    hold(app, (call.arguments as? Number)?.toLong() ?: 10_000L)
                    result.success(null)
                }
                "release" -> {
                    release()
                    result.success(null)
                }
                "status" -> result.success(
                    mapOf(
                        "unrestricted" to unrestricted(app),
                        "running" to VeilService.running,
                    ),
                )
                "askUnrestricted" -> result.success(askUnrestricted(app))
                "notificationSettings" -> result.success(openNotificationSettings(app))
                "lastCrash" -> result.success(takeCrash(app))
                else -> result.notImplemented()
            }
        }
        // Заряд батареи и зарядка — для автоматического режима «Ультра».
        MethodChannel(messenger, "veil/power").setMethodCallHandler { call, result ->
            if (call.method == "state") {
                try {
                    val bm = app.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    result.success(
                        mapOf(
                            "level" to bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY),
                            "charging" to bm.isCharging,
                        ),
                    )
                } catch (_: Exception) {
                    result.success(null)
                }
            } else {
                result.notImplemented()
            }
        }
        // Какая сеть сейчас: Wi-Fi или нет (для подсказки об отправке файлов).
        MethodChannel(messenger, "veil/net").setMethodCallHandler { call, result ->
            if (call.method == "wifi") {
                try {
                    val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                    result.success(caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true)
                } catch (_: Exception) {
                    result.success(false)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
