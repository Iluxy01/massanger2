package app.veil.veil

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.view.WindowManager
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
}
