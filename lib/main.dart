import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'core/background.dart';
import 'core/notifier.dart';
import 'state/app_state.dart';
import 'state/live.dart';

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
  live.notify = SystemNotify(() => state.notificationText);
  state.applyScreenshotProtection();
  // Повторный запуск того же приложения (окно закрывали, а служба держала его
  // живым) сюда не попадает; при обычном запуске — включаем службу, если надо.
  await state.syncInstantService();
  try {
    await SystemNotify.init();
    await scheduleBackgroundSync();
  } catch (e) {
    debugPrint('background sync: $e');
  }
}
