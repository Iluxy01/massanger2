import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/background.dart';
import 'core/link.dart';
import 'core/notifier.dart';
import 'state/app_state.dart';
import 'state/live.dart';
import 'widgets/slow_clock.dart';

/// `flutter run --dart-define=DEMO=true` — демо-режим с выдуманными друзьями.
const demoMode = bool.fromEnvironment('DEMO');

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  if (demoMode || kIsWeb) {
    final state = AppState.demo()..createProfile(name: 'Демо', emoji: '🐼', colorIndex: 1);
    runApp(VeilApp(state: state));
    return;
  }

  final state = AppState();
  runApp(VeilApp(state: state));
  _boot(state);
}

Future<void> _boot(AppState state) async {
  final live = await Live.boot(state);
  live.notify = SystemNotify(() => state.notificationText, () => state.disguise, state.readOnly);
  // Запущены службой «на связи» без окна (после перезагрузки, обновления или
  // выгрузки системой): ведём себя как свёрнутое приложение — без анимаций,
  // с уведомлениями. Окно откроют — придёт «resumed», и всё оживёт.
  if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
    Activity.setResumed(false);
    state.windowless = true;
    state.lock();
    state.setForeground(false);
  }
  // Будильник службы и смена сети — проверить связь.
  Link.onTick((_) => live.keepAlive());
  state.applyScreenshotProtection();
  // Повторный запуск того же приложения (окно закрывали, а служба держала его
  // живым) сюда не попадает; при обычном запуске — включаем службу, если надо.
  await state.syncInstantService();
  try {
    // Нажатие на уведомление — открыть чат; «Ответить» в шторке — отправить.
    SystemNotify.onOpen = (chat) => state.openRequest.value = chat;
    listenNotificationReplies(state);
    await SystemNotify.init();
    final launched = await SystemNotify.launchChat();
    if (launched != null) state.openRequest.value = launched;
    await scheduleBackgroundSync();
  } catch (e) {
    debugPrint('background sync: $e');
  }
}
