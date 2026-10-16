import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../state/app_state.dart';
import '../state/live.dart';
import 'nostr.dart';
import 'notifier.dart';

/// Фоновая проверка новых сообщений, когда приложение закрыто.
///
/// Android запускает её примерно раз в 15 минут (точнее не позволяет система —
/// это цена отказа от серверов и Google-пушей).
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    final app = AppState()..foreground = false;
    Live? live;
    try {
      // Отдельное соединение с базой: закрыв его, мы не закроем базу приложению.
      live = await Live.bootBackground(app);
      if (live == null || live.keys == null) return true;
      // Если приложение живо (открыто или свёрнуто, но не выгружено) —
      // оно само всё получает; не мешаем ему писать в базу.
      final alive = int.tryParse(await live.store.get('alive') ?? '') ?? 0;
      if (nowSec() - alive < 75) return true;
      live.notify = SystemNotify(() => app.notificationText, () => app.disguise);
      final got = await live.syncOnce();
      final t = DateTime.now();
      await live.store.set(
        'bg_last',
        '${t.hour}:${t.minute.toString().padLeft(2, '0')} — новых сообщений: $got',
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      await live?.close();
    }
  });
}

Future<void> scheduleBackgroundSync() async {
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    'veil-sync',
    'sync',
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}
