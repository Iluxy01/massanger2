import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/relay_pool.dart';
import '../models/models.dart';
import '../theme/palette.dart';
import '../utils.dart';
import 'live.dart';
import 'mock_data.dart';

/// Входящее сообщение — для всплывающего уведомления внутри приложения.
class Incoming {
  Incoming(this.contact, this.message);
  final Contact contact;
  final Message message;
}

/// Всё состояние приложения, которое видят экраны.
///
/// Два режима:
/// * обычный — данные из базы на телефоне, сообщения идут через [Live];
/// * демо ([AppState.demo]) — выдуманные друзья, ответы симулируются
///   (для скриншотов, тестов и `--dart-define=DEMO=true`).
class AppState extends ChangeNotifier {
  AppState() : demo = false;

  AppState.demo() : demo = true {
    _seed();
    ready = true;
  }

  final bool demo;

  /// Подключается в обычном режиме (см. [Live.boot]).
  Live? live;

  /// База загружена — можно показывать интерфейс.
  bool ready = false;

  /// Приложение на экране (а не свёрнуто).
  bool foreground = true;

  Profile? profile;
  bool get onboarded => profile != null;

  bool hasPin = false;
  String? _demoPin;
  bool locked = false;

  int accentIndex = 0;
  bool dark = true;
  bool haptics = true;
  bool readReceipts = true;
  bool typingIndicators = true;
  bool screenshotProtection = true;
  bool notificationText = true;

  final List<Contact> contacts = [];
  final Map<String, List<Message>> _messages = {};
  final Set<String> pinned = {};
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
  bool _disposed = false;

  Accent get accent => accents[accentIndex];
  VeilColors get colors => dark ? VeilColors.darkColors : VeilColors.lightColors;

  void notifyChanged() {
    if (!_disposed) notifyListeners();
  }

  // ───────────────────────── Чтение ─────────────────────────

  List<Message> messagesOf(String id) => _messages[id] ??= [];

  void setMessages(String id, List<Message> list) => _messages[id] = list;

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
        bytes += 120 + m.text.length * 2 + m.voiceSeconds * 2000;
      }
    }
    return bytes;
  }

  // ── сеть ──

  List<String> get relays => live?.relays ?? defaultRelays;
  RelayState relayState(String url) =>
      demo ? RelayState.online : live?.pool?.stateOf(url) ?? RelayState.offline;
  String? relayError(String url) => live?.pool?.errorOf(url);
  int get onlineRelays => demo ? relays.length : live?.pool?.onlineCount ?? 0;

  Future<void> setRelays(List<String> urls) async => live?.setRelays(urls);

  /// url → (принял, вернул). В демо — всё хорошо.
  Future<Map<String, (bool, bool)>> diagnose() async {
    if (live == null) {
      await Future<void>.delayed(const Duration(seconds: 1));
      return {for (final u in relays) u: (true, true)};
    }
    return live!.diagnose();
  }

  /// Ссылка-приглашение (её же содержит QR-код).
  String get inviteLink {
    final l = live;
    if (l != null && l.keys != null) return l.inviteLink;
    final p = profile!;
    return Invite(
      p.fingerprint.toLowerCase().padRight(64, '0').substring(0, 64),
      VeilCard(name: p.name, emoji: p.emoji, color: p.colorIndex),
    ).encode();
  }

  // ───────────────────────── Профиль и настройки ─────────────────────────

  Future<void> createProfile({
    required String name,
    required String emoji,
    required int colorIndex,
  }) async {
    final l = live;
    if (l != null) {
      await l.createIdentity(
        (pub) => Profile(name: name, emoji: emoji, colorIndex: colorIndex, fingerprint: pub),
      );
    } else {
      profile = Profile(
        name: name,
        emoji: emoji,
        colorIndex: colorIndex,
        fingerprint: randomHex(64).toLowerCase(),
      );
    }
    notifyChanged();
  }

  void updateProfile({String? name, String? emoji, int? colorIndex, String? bio}) {
    final p = profile;
    if (p == null) return;
    if (name != null) p.name = name;
    if (emoji != null) p.emoji = emoji;
    if (colorIndex != null) p.colorIndex = colorIndex;
    if (bio != null) p.bio = bio;
    live?.saveProfile();
    notifyChanged();
  }

  Map<String, dynamic> get _settings => {
    'accent': accentIndex,
    'dark': dark,
    'haptics': haptics,
    'receipts': readReceipts,
    'typing': typingIndicators,
    'secure': screenshotProtection,
    'notifText': notificationText,
    'pinned': pinned.toList(),
    'muted': muted.toList(),
  };

  void applySettings(Map<String, dynamic> s) {
    accentIndex = ((s['accent'] as num?)?.toInt() ?? 0).clamp(0, accents.length - 1);
    dark = s['dark'] as bool? ?? true;
    haptics = s['haptics'] as bool? ?? true;
    readReceipts = s['receipts'] as bool? ?? true;
    typingIndicators = s['typing'] as bool? ?? true;
    screenshotProtection = s['secure'] as bool? ?? true;
    notificationText = s['notifText'] as bool? ?? true;
    pinned
      ..clear()
      ..addAll((s['pinned'] as List? ?? []).cast<String>());
    muted
      ..clear()
      ..addAll((s['muted'] as List? ?? []).cast<String>());
    applyScreenshotProtection();
  }

  void _saveSettings() {
    live?.saveSettings(_settings);
    notifyChanged();
  }

  void setAccent(int i) {
    accentIndex = i;
    _saveSettings();
  }

  void setDark(bool v) {
    dark = v;
    _saveSettings();
  }

  void setFlag(void Function() change) {
    change();
    applyScreenshotProtection();
    _saveSettings();
  }

  static const _secure = MethodChannel('veil/secure');

  /// Запрет скриншотов и превью в списке приложений (FLAG_SECURE на Android).
  void applyScreenshotProtection() {
    if (demo) return;
    _secure.invokeMethod('setSecure', screenshotProtection).catchError((_) => null);
  }

  Future<void> setPin(String? value) async {
    if (live != null) {
      await live!.setPin(value);
    } else {
      _demoPin = value;
      hasPin = value != null;
    }
    notifyChanged();
  }

  Future<bool> checkPin(String attempt) async =>
      live != null ? live!.checkPin(attempt) : attempt == _demoPin;

  void lock() {
    if (!hasPin) return;
    locked = true;
    notifyChanged();
  }

  void unlocked() {
    locked = false;
    notifyChanged();
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

  /// Жизненный цикл приложения (из app.dart).
  void setForeground(bool v) {
    if (foreground == v) return;
    foreground = v;
    if (v) {
      live?.resumed();
    } else {
      live?.paused();
    }
  }

  // ───────────────────────── Чаты ─────────────────────────

  void togglePin(String id) {
    pinned.contains(id) ? pinned.remove(id) : pinned.add(id);
    _saveSettings();
  }

  void toggleMute(String id) {
    muted.contains(id) ? muted.remove(id) : muted.add(id);
    _saveSettings();
  }

  void clearChat(String id) {
    _messages.remove(id);
    unread.remove(id);
    pinned.remove(id);
    live?.store.deleteChat(id);
    _saveSettings();
  }

  void markRead(String id) {
    final had = unread.remove(id) != null;
    if (live != null) {
      live!.markRead(id, sendReceipt: readReceipts);
    }
    if (had) notifyChanged();
  }

  void setDisappearing(String id, int minutes) {
    final c = contact(id);
    if (c == null) return;
    c.disappearing = minutes;
    live?.setTtl(c);
    notifyChanged();
  }

  void toggleVerified(String id) {
    final c = contact(id);
    if (c == null) return;
    c.verified = !c.verified;
    live?.saveContact(c);
    notifyChanged();
  }

  void toggleBlocked(String id) {
    final c = contact(id);
    if (c == null) return;
    c.blocked = !c.blocked;
    if (c.blocked) c.request = false;
    live?.saveContact(c);
    notifyChanged();
  }

  /// Удалить друга полностью — вместе с перепиской.
  Future<void> deleteContact(String id) async {
    pinned.remove(id);
    muted.remove(id);
    unread.remove(id);
    typing.remove(id);
    drafts.remove(id);
    if (live != null) {
      await live!.deleteContact(id);
    } else {
      contacts.removeWhere((c) => c.id == id);
      _messages.remove(id);
    }
    _saveSettings();
  }

  /// Журнал сети для диагностики.
  List<String> get journal => live?.journal ?? const ['демо-режим: сети нет'];

  /// Принять незнакомца, который нам написал.
  void acceptRequest(String id) {
    final c = contact(id);
    if (c == null) return;
    c.request = false;
    live?.saveContact(c);
    notifyChanged();
  }

  void deleteMessage(String chatId, Message m) {
    messagesOf(chatId).remove(m);
    live?.store.deleteMessage(m.id);
    notifyChanged();
  }

  void react(String chatId, Message m, String? emoji) {
    m.reaction = m.reaction == emoji ? null : emoji;
    live?.react(chatId, m);
    notifyChanged();
  }

  void reveal(Message m, bool value) {
    m.revealed = value;
    notifyChanged();
  }

  void saveDraft(String chatId, String text) {
    text.trim().isEmpty ? drafts.remove(chatId) : drafts[chatId] = text;
  }

  /// Пользователь что-то набирает в чате.
  void userTyping(String chatId) {
    if (typingIndicators) live?.typing(chatId);
  }

  /// Добавить друга по QR-коду или ссылке.
  Future<Contact> addContact(Invite inv) async {
    final l = live;
    if (l != null) return l.addContact(inv);
    final c =
        contact(inv.pubkey) ??
        Contact(
          id: inv.pubkey,
          name: inv.card.name,
          emoji: inv.card.emoji,
          colorIndex: inv.card.color,
          verified: true,
        );
    if (!contacts.contains(c)) contacts.add(c);
    notifyChanged();
    return c;
  }

  /// Демо: «отсканировали» случайного друга.
  Contact addRandomFriend() {
    const names = ['Ника', 'Артём', 'Вера', 'Глеб', 'Ева', 'Марк', 'Злата', 'Рома'];
    final name = names[_rnd.nextInt(names.length)];
    final c = Contact(
      id: 'c${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      emoji: avatarEmojis[_rnd.nextInt(avatarEmojis.length)],
      colorIndex: _rnd.nextInt(avatarGradients.length),
      fingerprint: randomHex(64),
      online: true,
      verified: true,
      bio: 'новый друг в Veil',
    );
    contacts.add(c);
    notifyChanged();
    _later(1500, () => _receive(c.id, 'Привет! Это $name, добавил(а) тебя по QR 👋'));
    return c;
  }

  void send(
    String chatId,
    String text, {
    Message? replyTo,
    bool secret = false,
    MsgKind kind = MsgKind.text,
    int voiceSeconds = 0,
  }) {
    // Время строго больше предыдущего — чтобы порядок не «прыгал» после перезапуска.
    // (в базе время хранится с точностью до миллисекунды).
    var ms = DateTime.now().millisecondsSinceEpoch;
    final last = lastMessage(chatId);
    if (last != null && ms <= last.time.millisecondsSinceEpoch) {
      ms = last.time.millisecondsSinceEpoch + 1;
    }
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    final m = Message(
      id: randomHex(16).toLowerCase(),
      mine: true,
      text: text,
      time: time,
      status: MsgStatus.sending,
      replyTo: replyTo,
      secret: secret,
      kind: kind,
      voiceSeconds: voiceSeconds,
    );
    messagesOf(chatId).add(m);
    drafts.remove(chatId);
    final c = contact(chatId);
    if (c != null && c.request) {
      // Ответили незнакомцу — значит, приняли его.
      c.request = false;
      live?.saveContact(c);
    }
    notifyChanged();
    if (live != null) {
      live!.sendMessage(chatId, m).then((_) => notifyChanged());
    } else {
      _simulateReply(chatId, m);
    }
  }

  /// Новое входящее сообщение (из сети).
  Future<void> onIncoming(Contact c, Message m) async {
    final visible = foreground && openChat == c.id && !locked;
    if (visible) {
      await live?.markRead(c.id, sendReceipt: readReceipts);
      return;
    }
    unread[c.id] = (unread[c.id] ?? 0) + 1;
    if (muted.contains(c.id)) return;
    if (foreground && !locked) {
      _incoming.add(Incoming(c, m));
    } else {
      await live?.notify?.message(c, m);
    }
  }

  /// «Красная кнопка»: стереть всё с устройства.
  Future<void> wipeEverything() async {
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    typing.clear();
    drafts.clear();
    muted.clear();
    pinned.clear();
    unread.clear();
    contacts.clear();
    _messages.clear();
    profile = null;
    hasPin = false;
    _demoPin = null;
    locked = false;
    final l = live;
    if (l != null) {
      final n = l.notify;
      await l.wipe();
      live = null;
      // Начинаем с чистого листа: новая пустая база.
      await Live.boot(this);
      live?.notify = n;
    } else if (demo) {
      _seed();
    }
    notifyChanged();
  }

  // ───────────────────────── Демо-режим ─────────────────────────

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

  void _simulateReply(String chatId, Message m) {
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
    final m = Message(
      id: randomHex(16).toLowerCase(),
      mine: false,
      text: text,
      time: DateTime.now(),
    );
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

  @override
  void dispose() {
    _disposed = true;
    for (final t in _timers) {
      t.cancel();
    }
    _incoming.close();
    live?.close();
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
