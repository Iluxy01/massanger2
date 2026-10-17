import 'package:flutter_local_notifications/flutter_local_notifications.dart' hide Message;

import '../models/models.dart';
import '../state/live.dart';
import '../widgets/rich_text.dart';
import 'background.dart';

/// Системные уведомления Android. Работают и в фоновой проверке.
class SystemNotify implements Notify {
  SystemNotify(this.showText, [this.disguise, this.readOnly]);

  /// Показывать ли текст сообщения (можно выключить в настройках).
  final bool Function() showText;

  /// Маскировка значка (0 — нет): уведомление тоже «под прикрытием».
  final int Function()? disguise;

  /// Только читаю этот чат (подписчик канала) — «Ответить» не показываем.
  final bool Function(Contact c)? readOnly;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// Кнопка «Ответить» с полем ввода прямо в шторке.
  static const replyAction = 'reply';

  /// Имя порта живого приложения: ответ из шторки передаётся ему.
  static const portName = 'veil.reply';

  /// Нажали на само уведомление — открыть этот чат.
  static void Function(String chat)? onOpen;

  static Future<void> init() async {
    if (_ready) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onResponse,
      onDidReceiveBackgroundNotificationResponse: notificationAction,
    );
    _ready = true;
  }

  static void _onResponse(NotificationResponse r) {
    if (r.actionId == replyAction) {
      notificationAction(r);
      return;
    }
    final chat = r.payload;
    if (chat != null && chat.isNotEmpty) onOpen?.call(chat);
  }

  /// Приложение открыли нажатием на уведомление — какой чат показать.
  static Future<String?> launchChat() async {
    await init();
    final d = await _plugin.getNotificationAppLaunchDetails();
    if (!(d?.didNotificationLaunchApp ?? false)) return null;
    final r = d!.notificationResponse;
    if (r == null || r.actionId != null) return null;
    final chat = r.payload;
    return chat == null || chat.isEmpty ? null : chat;
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
    final preview = Fmt.plain(m.preview);
    final text = who == null ? preview : '${who.name}: $preview';
    // Чат в тайнике: ни имени, ни текста — просто «Новое сообщение».
    final hidden = from.hidden;
    final body = hidden
        ? 'Новое сообщение'
        : m.secret
        ? '🔒 Секретное сообщение'
        : showText()
        ? text
        : 'Новое сообщение';
    // Маскировка: ни имени, ни текста, ни слова «Veil».
    final cover = disguise?.call() ?? 0;
    if (cover > 0) {
      await _plugin.show(
        id: 7,
        title: cover == 2 ? 'Заметки' : 'Калькулятор',
        body: 'Новое уведомление',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'messages',
            'Сообщения',
            icon: cover == 2 ? 'ic_notes_fg' : 'ic_calc_fg',
            importance: Importance.high,
            priority: Priority.high,
            visibility: NotificationVisibility.private,
          ),
        ),
      );
      return;
    }
    // «Ответить» — кроме тайника и каналов, где пишет только автор.
    final canReply =
        !hidden &&
        !from.blocked &&
        !(from.group?.left ?? false) &&
        !(readOnly?.call(from) ?? from.isChannel);
    await _plugin.show(
      id: from.id.hashCode & 0x7fffffff,
      title: hidden ? 'Veil' : '${from.emoji} ${from.name}',
      body: body,
      payload: hidden ? null : from.id,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          'messages',
          'Сообщения',
          channelDescription: 'Новые сообщения от друзей',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.message,
          visibility: NotificationVisibility.private,
          actions: canReply
              ? const [
                  AndroidNotificationAction(
                    replyAction,
                    'Ответить',
                    inputs: [AndroidNotificationActionInput(label: 'Сообщение')],
                    // Отвечаем, не открывая приложение.
                    showsUserInterface: false,
                    cancelNotification: true,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}
