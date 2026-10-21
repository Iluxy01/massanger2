import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
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
      live.notify = SystemNotify(() => app.notificationText, () => app.disguise, app.readOnly);
      final got = await live.syncOnce();
      // Напомнить о днях рождения — в ту же проверку, без своих задач.
      await app.checkBirthdays();
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

/// Ответ из шторки («Ответить» в уведомлении). Android запускает этот код в
/// отдельном фоновом потоке. Если Veil живо — передаём ответ ему (и ждём
/// подтверждения). Если выгружено — ненадолго поднимаем Veil в фоне сами:
/// кладём сообщение в очередь, подключаемся, отправляем и выходим.
@pragma('vm:entry-point')
void notificationAction(NotificationResponse r) => unawaited(_reply(r));

Future<void> _reply(NotificationResponse r) async {
  final chat = r.payload;
  final text = r.input?.trim() ?? '';
  if (r.actionId != SystemNotify.replyAction || chat == null || chat.isEmpty || text.isEmpty) {
    return;
  }
  final main = IsolateNameServer.lookupPortByName(SystemNotify.portName);
  if (main != null) {
    // Порт мог остаться от уже закрытого приложения — ждём «принято».
    final ack = ReceivePort();
    main.send({'c': chat, 't': text, 'ack': ack.sendPort});
    final ok = await ack.first.timeout(const Duration(seconds: 2), onTimeout: () => false);
    ack.close();
    if (ok == true) return;
    IsolateNameServer.removePortNameMapping(SystemNotify.portName);
  }
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final app = AppState()..foreground = false;
  Live? live;
  try {
    live = await Live.bootBackground(app);
    if (live == null || live.keys == null) return;
    final c = app.contact(chat);
    if (c == null || c.blocked || app.readOnly(c) || (c.group?.left ?? false)) return;
    await live.markRead(chat, sendReceipt: app.readReceipts);
    final m = app.compose(chat, text);
    await live.sendMessage(chat, m);
    // Подключиться, отправить очередь (и заодно забрать новое).
    await live.syncOnce(timeout: const Duration(seconds: 15));
  } catch (_) {
    // Не вышло — сообщение осталось в очереди и уйдёт при следующем запуске.
  } finally {
    await live?.close();
  }
}

/// Живое приложение принимает ответы из шторки.
void listenNotificationReplies(AppState app) {
  final port = ReceivePort();
  IsolateNameServer.removePortNameMapping(SystemNotify.portName);
  IsolateNameServer.registerPortWithName(port.sendPort, SystemNotify.portName);
  port.listen((msg) {
    if (msg is! Map) return;
    final chat = msg['c'], text = msg['t'], ack = msg['ack'];
    if (chat is String && text is String) app.replyFromNotification(chat, text);
    if (ack is SendPort) ack.send(true);
  });
}
