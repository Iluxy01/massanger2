package app.veil.veil

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Телефон включили (или Veil обновили) — с «мгновенными уведомлениями»
 * сразу снова на связи, не дожидаясь, пока Veil откроют.
 */
class VeilBoot : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {
                val app = context.applicationContext
                if (!VeilLink.instant(app)) return
                VeilLink.startService(app)
                VeilAlarm.schedule(app)
            }
        }
    }
}
