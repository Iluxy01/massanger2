import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../theme/palette.dart';
import '../utils.dart';
import 'mock_data.dart';

/// Входящее сообщение — для всплывающего уведомления внутри приложения.
class Incoming {
  Incoming(this.contact, this.message);
  final Contact contact;
  final Message message;
}

/// Всё состояние приложения.
///
/// Сейчас это фронтенд-прототип: данные живут в памяти, а ответы друзей
/// симулируются. На следующем этапе здесь появится локальная зашифрованная
/// база и P2P-транспорт — интерфейс для экранов останется тем же.
class AppState extends ChangeNotifier {
  AppState() {
    _seed();
  }

  Profile? profile;
  bool get onboarded => profile != null;

  String? pin;
  bool locked = false;

  int accentIndex = 0;
  bool dark = true;
  bool haptics = true;
  bool readReceipts = true;
  bool typingIndicators = true;
  bool screenshotProtection = true;
  bool linkPreviews = false;

  final List<Contact> contacts = [];
  final Map<String, List<Message>> _messages = {};
  final Set<String> pinned = {'alice'};
  final Set<String> muted = {};
  final Set<String> typing = {};
  final Map<String, int> unread = {};
  final Map<String, String> drafts = {};

  /// Какой чат сейчас открыт (чтобы не считать в нём непрочитанные).
  String? openChat;

  final _incoming = StreamController<Incoming>.broadcast();
  Stream<Incoming> get incoming => _incoming.stream;

  final _rnd = Random();
  final List<Timer> _timers = [];
  int _ids = 0;
  bool _disposed = false;

  Accent get accent => accents[accentIndex];
  VeilColors get colors => dark ? VeilColors.darkColors : VeilColors.lightColors;

  void _seed() {
    contacts
      ..clear()
      ..addAll(demoContacts());
    _messages
      ..clear()
      ..addAll(demoMessages());
    unread
      ..clear()
      ..addAll({'alice': 2, 'kate': 1});
    pinned
      ..clear()
      ..add('alice');
    // Катя «печатает» при первом запуске — чтобы было видно индикатор.
    _later(2500, () => typing.add('kate'));
    _later(6000, () {
      typing.remove('kate');
      _receive('kate', 'Вот, держи 📸 скоро будет');
    });
  }

  // ───────────────────────── Чтение ─────────────────────────

  List<Message> messagesOf(String id) => _messages[id] ??= [];

  Message? lastMessage(String id) {
    final list = _messages[id];
    return (list == null || list.isEmpty) ? null : list.last;
  }

  Contact? contact(String id) {
    for (final c in contacts) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Чаты: закреплённые сверху, остальные по времени последнего сообщения.
  List<Contact> get chatList {
    final list = contacts.where((c) => lastMessage(c.id) != null).toList();
    list.sort((a, b) {
      final pa = pinned.contains(a.id), pb = pinned.contains(b.id);
      if (pa != pb) return pa ? -1 : 1;
      return lastMessage(b.id)!.time.compareTo(lastMessage(a.id)!.time);
    });
    return list;
  }

  int get totalUnread => unread.values.fold(0, (a, b) => a + b);

  int get totalMessages => _messages.values.fold(0, (a, b) => a + b.length);

  /// Примерный объём локального хранилища (для экрана «Хранилище»).
  int get storageBytes {
    var bytes = 0;
    for (final list in _messages.values) {
      for (final m in list) {
        bytes += 96 + m.text.length * 2 + m.voiceSeconds * 2000;
      }
    }
    return bytes;
  }

  // ───────────────────────── Профиль и настройки ─────────────────────────

  void createProfile({required String name, required String emoji, required List<Color> colors}) {
    final fp = randomHex(64);
    profile = Profile(
      name: name,
      emoji: emoji,
      colors: colors,
      fingerprint: fp,
      veilId: 'VEIL-${fp.substring(0, 4)}-${fp.substring(4, 8)}-${fp.substring(8, 12)}',
    );
    notifyListeners();
  }

  void updateProfile({String? name, String? emoji, List<Color>? colors}) {
    final p = profile;
    if (p == null) return;
    if (name != null) p.name = name;
    if (emoji != null) p.emoji = emoji;
    if (colors != null) p.colors = colors;
    notifyListeners();
  }

  void setAccent(int i) {
    accentIndex = i;
    notifyListeners();
  }

  void setDark(bool v) {
    dark = v;
    notifyListeners();
  }

  void setFlag(void Function() change) {
    change();
    notifyListeners();
  }

  void setPin(String? value) {
    pin = value;
    notifyListeners();
  }

  void lock() {
    if (pin == null) return;
    locked = true;
    notifyListeners();
  }

  bool unlock(String attempt) {
    if (attempt != pin) return false;
    locked = false;
    notifyListeners();
    return true;
  }

  void tick([HapticKind kind = HapticKind.light]) {
    if (!haptics) return;
    switch (kind) {
      case HapticKind.selection:
        HapticFeedback.selectionClick();
      case HapticKind.light:
        HapticFeedback.lightImpact();
      case HapticKind.medium:
        HapticFeedback.mediumImpact();
      case HapticKind.heavy:
        HapticFeedback.heavyImpact();
    }
  }

  // ───────────────────────── Чаты ─────────────────────────

  void togglePin(String id) {
    pinned.contains(id) ? pinned.remove(id) : pinned.add(id);
    notifyListeners();
  }

  void toggleMute(String id) {
    muted.contains(id) ? muted.remove(id) : muted.add(id);
    notifyListeners();
  }

  void clearChat(String id) {
    _messages.remove(id);
    unread.remove(id);
    pinned.remove(id);
    notifyListeners();
  }

  void markRead(String id) {
    if (unread.remove(id) != null) notifyListeners();
  }

  void setDisappearing(String id, int minutes) {
    contact(id)?.disappearing = minutes;
    notifyListeners();
  }

  void toggleVerified(String id) {
    final c = contact(id);
    if (c == null) return;
    c.verified = !c.verified;
    notifyListeners();
  }

  void toggleBlocked(String id) {
    final c = contact(id);
    if (c == null) return;
    c.blocked = !c.blocked;
    notifyListeners();
  }

  void deleteMessage(String chatId, Message m) {
    messagesOf(chatId).remove(m);
    notifyListeners();
  }

  void react(Message m, String? emoji) {
    m.reaction = m.reaction == emoji ? null : emoji;
    notifyListeners();
  }

  void reveal(Message m, bool value) {
    m.revealed = value;
    notifyListeners();
  }

  void saveDraft(String chatId, String text) {
    text.trim().isEmpty ? drafts.remove(chatId) : drafts[chatId] = text;
  }

  /// Новый друг (после сканирования QR-кода).
  Contact addRandomFriend() {
    const names = ['Ника', 'Артём', 'Вера', 'Глеб', 'Ева', 'Марк', 'Злата', 'Рома'];
    final name = names[_rnd.nextInt(names.length)];
    final c = Contact(
      id: 'c${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      emoji: avatarEmojis[_rnd.nextInt(avatarEmojis.length)],
      colors: avatarGradients[_rnd.nextInt(avatarGradients.length)],
      fingerprint: randomHex(64),
      online: true,
      verified: true,
      bio: 'новый друг в Veil',
    );
    contacts.add(c);
    notifyListeners();
    _later(1500, () => _receive(c.id, 'Привет! Это $name, добавил(а) тебя по QR 👋'));
    return c;
  }

  /// Отправка. Статусы и ответ друга пока симулируются.
  void send(
    String chatId,
    String text, {
    Message? replyTo,
    bool secret = false,
    MsgKind kind = MsgKind.text,
    int voiceSeconds = 0,
  }) {
    final m = Message(
      id: 'm${_ids++}',
      mine: true,
      text: text,
      time: DateTime.now(),
      status: MsgStatus.sending,
      replyTo: replyTo,
      secret: secret,
      kind: kind,
      voiceSeconds: voiceSeconds,
    );
    messagesOf(chatId).add(m);
    drafts.remove(chatId);
    notifyListeners();

    final c = contact(chatId);
    _later(350, () => m.status = MsgStatus.sent);
    _later(900, () => m.status = MsgStatus.delivered);
    if (c == null || c.blocked) return;
    final online = c.online;
    _later(online ? 1700 : 3800, () => m.status = MsgStatus.read);

    if (_rnd.nextDouble() < 0.3) {
      _later(online ? 2100 : 4200, () => m.reaction = reactionEmojis[_rnd.nextInt(4)]);
    }
    if (_rnd.nextDouble() < 0.85) {
      final start = online ? 2400 : 4600;
      _later(start, () => typing.add(chatId));
      _later(start + 1300 + _rnd.nextInt(1800), () {
        typing.remove(chatId);
        _receive(chatId, replyPhrases[_rnd.nextInt(replyPhrases.length)]);
      });
    }
  }

  void _receive(String chatId, String text) {
    final c = contact(chatId);
    if (c == null) return;
    final m = Message(id: 'm${_ids++}', mine: false, text: text, time: DateTime.now());
    messagesOf(chatId).add(m);
    if (openChat != chatId) {
      unread[chatId] = (unread[chatId] ?? 0) + 1;
      if (!muted.contains(chatId)) _incoming.add(Incoming(c, m));
    }
  }

  void _later(int ms, VoidCallback f) {
    late final Timer t;
    t = Timer(Duration(milliseconds: ms), () {
      _timers.remove(t);
      if (_disposed) return;
      f();
      notifyListeners();
    });
    _timers.add(t);
  }

  /// «Красная кнопка»: стереть всё с устройства.
  void wipeEverything() {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    typing.clear();
    drafts.clear();
    muted.clear();
    profile = null;
    pin = null;
    locked = false;
    _seed();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers) {
      t.cancel();
    }
    _incoming.close();
    super.dispose();
  }
}

enum HapticKind { selection, light, medium, heavy }

/// Доступ к состоянию из любого виджета: `context.app`.
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppState read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

extension AppContext on BuildContext {
  /// Подписывается на изменения состояния.
  AppState get app => AppScope.of(this);

  /// Без подписки — для обработчиков нажатий.
  AppState get appRead => AppScope.read(this);

  VeilColors get vc => app.colors;
  Accent get accent => app.accent;
}
