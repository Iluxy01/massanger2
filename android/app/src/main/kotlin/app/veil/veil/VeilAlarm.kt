package app.veil.veil

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock

/**
 * Редкий «будильник» службы «на связи». Во сне телефон не выполняет таймеры
 * приложения, и оборвавшееся соединение могло ждать переподключения часами.
 * Раз в ~10 минут (во сне Android сам растягивает интервал) — проснуться на
 * несколько секунд: проверить связь, забрать новое. Если служба пропала —
 * поднять её снова.
 */
class VeilAlarm : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val app = context.applicationContext
        if (!VeilLink.instant(app)) return
        // Приложение само отпустит раньше, как только проверит связь.
        VeilLink.hold(app, 20_000L)
        if (VeilService.running) {
            VeilLink.tick("alarm")
        } else {
            VeilLink.startService(app)
        }
        schedule(app)
    }

    companion object {
        private const val EVERY = 10 * 60 * 1000L

        private fun intent(ctx: Context): PendingIntent = PendingIntent.getBroadcast(
            ctx,
            0,
            Intent(ctx, VeilAlarm::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        fun schedule(ctx: Context) {
            try {
                val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                am.setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + EVERY,
                    intent(ctx),
                )
            } catch (_: Exception) {
            }
        }

        fun cancel(ctx: Context) {
            try {
                (ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(intent(ctx))
            } catch (_: Exception) {
            }
        }
    }
}
