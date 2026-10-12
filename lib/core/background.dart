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
      live = await Live.boot(app, network: false);
      // Если приложение сейчас открыто — оно само всё получает.
      final fg = int.tryParse(await live.store.get('fg') ?? '') ?? 0;
      if (nowSec() - fg < 60 || live.keys == null) return true;
      live.notify = SystemNotify(() => app.notificationText);
      await live.syncOnce();
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
