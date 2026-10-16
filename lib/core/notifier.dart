import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;

import '../models/models.dart';
import '../state/live.dart';

/// Системные уведомления Android. Работают и в фоновой проверке.
class SystemNotify implements Notify {
  SystemNotify(this.showText);

  /// Показывать ли текст сообщения (можно выключить в настройках).
  final bool Function() showText;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _ready = true;
  }

  /// Android 13+ спрашивает разрешение на уведомления.
  static Future<void> requestPermission() async {
    await init();
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  @override
  Future<void> message(Contact from, Message m) async {
    await init();
    // В группе — с именем автора.
    final who = from.group?.member(m.from ?? '');
    final text = who == null ? m.preview : '${who.name}: ${m.preview}';
    final body = m.secret
        ? '🔒 Секретное сообщение'
        : showText()
        ? text
        : 'Новое сообщение';
    await _plugin.show(
      id: from.id.hashCode & 0x7fffffff,
      title: '${from.emoji} ${from.name}',
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Сообщения',
          channelDescription: 'Новые сообщения от друзей',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
        ),
      ),
    );
  }
}
