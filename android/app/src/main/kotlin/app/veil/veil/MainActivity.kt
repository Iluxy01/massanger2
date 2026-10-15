package app.veil.veil

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.view.WindowManager
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private fun instant(): Boolean =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(INSTANT, false)

    // С «мгновенными уведомлениями» приложение (Flutter) переживает закрытие окна:
    // берём уже работающее из кэша и не уничтожаем его вместе с окном.
    override fun provideFlutterEngine(context: Context): FlutterEngine? =
        FlutterEngineCache.getInstance().get(ENGINE)

    override fun shouldDestroyEngineWithHost(): Boolean = !instant()

    override fun onDestroy() {
        val destroy = shouldDestroyEngineWithHost()
        super.onDestroy()
        if (destroy) FlutterEngineCache.getInstance().remove(ENGINE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (instant()) FlutterEngineCache.getInstance().put(ENGINE, flutterEngine)
        // Мгновенные уведомления: включить/выключить службу «на связи».
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veil/service")
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                when (call.method) {
                    "start" -> {
                        prefs.edit().putBoolean(INSTANT, true).apply()
                        FlutterEngineCache.getInstance().put(ENGINE, flutterEngine)
                        try {
                            ContextCompat.startForegroundService(
                                applicationContext,
                                Intent(applicationContext, VeilService::class.java),
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        prefs.edit().putBoolean(INSTANT, false).apply()
                        applicationContext.stopService(Intent(applicationContext, VeilService::class.java))
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        // Запрет скриншотов и превью в списке недавних приложений.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veil/secure")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        // Какая сеть сейчас: Wi-Fi или нет (для подсказки об отправке файлов).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veil/net")
            .setMethodCallHandler { call, result ->
                if (call.method == "wifi") {
                    try {
                        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                        val caps = cm.getNetworkCapabilities(cm.activeNetwork)
                        result.success(caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                } else {
                    result.notImplemented()
                }
            }
        // Открыть файл или точку на карте в другом приложении.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veil/open")
            .setMethodCallHandler { call, result ->
                try {
                    val intent = when (call.method) {
                        "file" -> {
                            val file = File(call.argument<String>("path")!!)
                            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
                            Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, call.argument<String>("mime") ?: "*/*")
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        "geo" -> {
                            val lat = call.argument<Double>("lat")!!
                            val lng = call.argument<Double>("lng")!!
                            Intent(Intent.ACTION_VIEW, Uri.parse("geo:$lat,$lng?q=$lat,$lng"))
                        }
                        else -> null
                    }
                    if (intent == null) {
                        result.notImplemented()
                    } else {
                        startActivity(intent)
                        result.success(true)
                    }
                } catch (e: ActivityNotFoundException) {
                    result.success(false)
                } catch (e: Exception) {
                    result.error("open", e.message, null)
                }
            }
    }

    companion object {
        const val ENGINE = "veil_main"
        const val PREFS = "veil_native"
        const val INSTANT = "instant"
    }
}
