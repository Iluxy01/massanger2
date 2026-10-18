package app.veil.veil

import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.pm.PackageManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File

// FragmentActivity — для системного окна входа по отпечатку / лицу (local_auth).
class MainActivity : FlutterFragmentActivity() {
    private fun instant(): Boolean =
        getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(INSTANT, false)

    // Приложение (Flutter) создаём сами и отдаём окну: уже работающее (его
    // держит служба «на связи») или новое. Окно его не уничтожает — это решаем
    // мы в onDestroy.
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        VeilLink.engine(this, run = false)

    override fun onCreate(savedInstanceState: Bundle?) {
        VeilLink.installCrashLog(this)
        super.onCreate(savedInstanceState)
        // Запрет скриншотов — сразу для нового окна, в том числе когда оно
        // подключается к уже работающему приложению (служба «на связи»).
        if (getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(SECURE, false)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        // Без «мгновенных уведомлений» приложение живёт, пока открыто окно (как
        // обычно); с ними — остаётся работать в фоне.
        if (!instant() && !isChangingConfigurations) {
            FlutterEngineCache.getInstance().get(ENGINE)?.destroy()
        } else {
            VeilLink.note(this, "окно закрыто, Veil работает дальше")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Служба «на связи», заряд, сеть — то, что работает и без окна.
        VeilLink.register(flutterEngine, this)
        // Запрет скриншотов и превью в списке недавних приложений.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veil/secure")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                        .putBoolean(SECURE, call.arguments == true).apply()
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
        // Маскировка значка: включить один из трёх «входов» (Veil / Калькулятор / Заметки).
        showDisguiseLabel()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "veil/disguise")
            .setMethodCallHandler { call, result ->
                if (call.method == "set") {
                    val mode = ((call.arguments as? Int) ?: 0).coerceIn(0, 2)
                    try {
                        LAUNCHERS.forEachIndexed { i, name ->
                            packageManager.setComponentEnabledSetting(
                                ComponentName(this, "$PKG.$name"),
                                if (i == mode) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
                                else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                                PackageManager.DONT_KILL_APP,
                            )
                        }
                        showDisguiseLabel()
                        result.success(true)
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

    /** В списке недавних приложений — то же имя, что и на значке. */
    private fun showDisguiseLabel() {
        try {
            val mode = LAUNCHERS.indexOfFirst {
                packageManager.getComponentEnabledSetting(ComponentName(this, "$PKG.$it")) ==
                    PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            }
            if (mode > 0) setTaskDescription(ActivityManager.TaskDescription(LABELS[mode]))
            else setTaskDescription(ActivityManager.TaskDescription("Veil"))
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val PKG = "app.veil.veil"
        private val LAUNCHERS = listOf("LauncherVeil", "LauncherCalc", "LauncherNotes")
        private val LABELS = listOf("Veil", "Калькулятор", "Заметки")
        const val ENGINE = "veil_main"
        const val PREFS = "veil_native"
        const val INSTANT = "instant"
        const val SECURE = "secure"
    }
}
