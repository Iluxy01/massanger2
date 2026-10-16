import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/protocol.dart';
import '../core/relay_pool.dart';
import '../models/models.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/rich_text.dart';
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

  /// Показывать всплывающее окошко о новом сообщении, когда приложение открыто.
  bool inAppBanner = true;

  /// Уровень оформления (0 минимум · 1 баланс · 2 максимум), см. widgets/visual.dart.
  int look = 1;

  /// Уровень анимаций (0 выкл · 1 быстрые · 2 обычные · 3 плавные).
  int motion = 2;

  /// «Мгновенные уведомления»: приложение остаётся на связи и в свёрнутом виде
  /// (служба с тихим значком в шторке). Выключено — проверка раз в ~15 минут.
  bool instantNotify = false;

  /// Режим «Ультра» — максимальная экономия батареи: без анимаций и размытия,
  /// тёмная тема, 4 ретранслятора вместо 9, без «в сети» и «печатает»,
  /// видео — по нажатию, без постоянной связи в фоне.
  bool ultra = false;

  /// Что реально действует (с учётом «Ультра»).
  int get effLook => ultra ? 0 : look;
  int get effMotion => ultra ? 0 : motion;
  bool get effDark => ultra || dark;

  /// Сколько ретрансляторов держать на связи в «Ультра».
  static const ultraRelays = 4;

  /// С какой камеры начинается запись видеосообщения: 0 — фронтальная, 1 — основная.
  int noteCamera = 0;

  /// Подсказку «отправляй файлы через мобильный интернет» уже показывали.
  bool wifiHintShown = false;

  // ── Тонкие настройки ──

  /// Размер текста сообщений: 0 мелкий · 1 обычный · 2 крупный.
  int msgFont = 1;
  double get msgFontSize => const [14.0, 16.0, 18.5][msgFont.clamp(0, 2)];

  /// Enter на клавиатуре отправляет (иначе — новая строка).
  bool enterSends = false;

  /// Сообщение из одних эмодзи — крупно и без пузыря.
  bool bigEmoji = true;

  /// Реакция на двойное касание ('' — выключено).
  String quickReaction = '❤️';

  /// Свайп по сообщению вправо — ответить.
  bool swipeReply = true;

  /// Видеосообщения сами крутятся без звука.
  bool notesAutoplay = true;

  /// Что скачивать само.
  bool autoPhoto = true;
  bool autoVideo = true;
  bool autoVoice = true;

  /// Не показывать текст сообщений в списке чатов (от посторонних глаз).
  bool hidePreviews = false;

  /// Спрашивать перед удалением сообщения.
  bool confirmDelete = false;

  /// Скачивать ли файл из сообщения сам (по тонким настройкам).
  bool autoDownload(Message m) => switch (m.kind) {
    MsgKind.photo => autoPhoto,
    // В «Ультра» тяжёлое (видео, видеосообщения) — только по нажатию.
    MsgKind.video => autoVideo && !ultra,
    MsgKind.note => autoVoice && !ultra,
    MsgKind.voice => autoVoice,
    _ => false,
  };

  /// Видеосообщения крутятся сами (не в «Ультра» и не без анимаций).
  bool get notesPlayThemselves => notesAutoplay && effMotion > 0;

  /// Меняется только при смене темы/акцента — от него перестраивается всё
  /// приложение. Остальные изменения перерисовывают лишь нужные экраны.
  final themeTick = ValueNotifier<int>(0);

  final List<Contact> contacts = [];
  final Map<String, List<Message>> _messages = {};
  final Set<String> pinned = {};
  final Set<String> muted = {};

  /// Чаты в архиве (не показываются в общем списке).
  final Set<String> archived = {};

  /// Избранные сообщения: «чат|id».
  final Set<String> starred = {};
  final Set<String> typing = {};

  /// Кто именно печатает в группе (id группы → ключ участника).
  final Map<String, String> typingBy = {};
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
  VeilColors get colors => effDark ? VeilColors.darkColors : VeilColors.lightColors;

  Timer? _notifyTimer;

  /// Изменения данных. Пачка событий подряд (сеть, отчёты, пинги) даёт одну
  /// перерисовку, а не десяток — меньше нагрузки и нагрева.
  void notifyChanged() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 30), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
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
  /// Архивные — отдельно ([archivedChats]).
  List<Contact> get chatList => _chats(archived: false);

  List<Contact> get archivedChats => _chats(archived: true);

  List<Contact> _chats({required bool archived}) {
    final list = contacts
        .where((c) => lastMessage(c.id) != null && this.archived.contains(c.id) == archived)
        .toList();
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
        if (m.att?.local ?? false) bytes += m.att!.size;
      }
    }
    return bytes;
  }

  // ── сеть ──

  List<String> get relays => live?.relays ?? defaultRelays;
  RelayState relayState(String url) =>
      demo ? RelayState.online : live?.pool?.stateOf(url) ?? RelayState.offline;

  /// Ретранслятор отключён режимом «Ультра» (не ошибка).
  bool relayResting(String url) => ultra && !relays.take(ultraRelays).contains(url);
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

  /// Сохранить зашифрованную копию (ключ, переписка, по желанию — файлы).
  Future<void> exportBackup(String out, String password, {bool withMedia = true}) =>
      live!.exportBackup(out, password, withMedia: withMedia);

  /// Восстановить всё из копии (на новом телефоне, вместо создания профиля).
  Future<void> restoreBackup(String path, String password) async {
    await live!.restoreBackup(path, password);
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
    'banner': inAppBanner,
    'look': look,
    'motion': motion,
    'instant': instantNotify,
    if (ultra) 'ultra': true,
    'noteCam': noteCamera,
    'font': msgFont,
    'enter': enterSends,
    'bigEmoji': bigEmoji,
    'qr': quickReaction,
    'swipe': swipeReply,
    'notesAuto': notesAutoplay,
    'autoPh': autoPhoto,
    'autoVid': autoVideo,
    'autoVo': autoVoice,
    'hidePrev': hidePreviews,
    'confirmDel': confirmDelete,
    if (wifiHintShown) 'wifiHint': true,
    'pinned': pinned.toList(),
    'muted': muted.toList(),
    if (archived.isNotEmpty) 'archived': archived.toList(),
    if (starred.isNotEmpty) 'starred': starred.toList(),
  };

  @visibleForTesting
  Map<String, dynamic> get settingsForTest => _settings;

  void applySettings(Map<String, dynamic> s) {
    accentIndex = ((s['accent'] as num?)?.toInt() ?? 0).clamp(0, accents.length - 1);
    dark = s['dark'] as bool? ?? true;
    haptics = s['haptics'] as bool? ?? true;
    readReceipts = s['receipts'] as bool? ?? true;
    typingIndicators = s['typing'] as bool? ?? true;
    screenshotProtection = s['secure'] as bool? ?? true;
    notificationText = s['notifText'] as bool? ?? true;
    inAppBanner = s['banner'] as bool? ?? true;
    look = ((s['look'] as num?)?.toInt() ?? 1).clamp(0, 2);
    motion = ((s['motion'] as num?)?.toInt() ?? 2).clamp(0, 3);
    instantNotify = s['instant'] == true;
    ultra = s['ultra'] == true;
    wifiHintShown = s['wifiHint'] == true;
    noteCamera = ((s['noteCam'] as num?)?.toInt() ?? 0).clamp(0, 1);
    msgFont = ((s['font'] as num?)?.toInt() ?? 1).clamp(0, 2);
    enterSends = s['enter'] == true;
    bigEmoji = s['bigEmoji'] as bool? ?? true;
    quickReaction = s['qr'] is String ? s['qr'] as String : '❤️';
    swipeReply = s['swipe'] as bool? ?? true;
    notesAutoplay = s['notesAuto'] as bool? ?? true;
    autoPhoto = s['autoPh'] as bool? ?? true;
    autoVideo = s['autoVid'] as bool? ?? true;
    autoVoice = s['autoVo'] as bool? ?? true;
    hidePreviews = s['hidePrev'] == true;
    confirmDelete = s['confirmDel'] == true;
    themeTick.value++;
    pinned
      ..clear()
      ..addAll((s['pinned'] as List? ?? []).cast<String>());
    muted
      ..clear()
      ..addAll((s['muted'] as List? ?? []).cast<String>());
    archived
      ..clear()
      ..addAll((s['archived'] as List? ?? []).cast<String>());
    starred
      ..clear()
      ..addAll((s['starred'] as List? ?? []).cast<String>());
    applyScreenshotProtection();
  }

  void _saveSettings() {
    live?.saveSettings(_settings);
    notifyChanged();
  }

  void setAccent(int i) {
    accentIndex = i;
    themeTick.value++;
    _saveSettings();
  }

  void setDark(bool v) {
    dark = v;
    themeTick.value++;
    _saveSettings();
  }

  void setLook(int v) {
    look = v;
    themeTick.value++;
    _saveSettings();
  }

  void setMotion(int v) {
    motion = v;
    themeTick.value++;
    _saveSettings();
  }

  static const _service = MethodChannel('veil/service');

  /// Включить/выключить режим «Ультра».
  Future<void> setUltra(bool v) async {
    if (ultra == v) return;
    ultra = v;
    themeTick.value++;
    _saveSettings();
    live?.applyPower();
    await syncInstantService();
  }

  /// Включить/выключить «мгновенные уведомления».
  Future<void> setInstantNotify(bool v) async {
    instantNotify = v;
    _saveSettings();
    await syncInstantService();
  }

  /// Запустить или остановить службу «на связи» по текущей настройке.
  Future<void> syncInstantService() async {
    if (demo || live == null) return;
    try {
      // В «Ультра» постоянную связь в фоне не держим — проверка по расписанию.
      await _service.invokeMethod<bool>(instantNotify && !ultra ? 'start' : 'stop');
    } catch (e) {
      debugPrint('service: $e');
    }
  }

  void setNoteCamera(int v) {
    noteCamera = v;
    _saveSettings();
  }

  void markWifiHintShown() {
    wifiHintShown = true;
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
    if (!haptics || ultra) return;
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
    live?.media.deleteChat(id);
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

  /// Удалить друга (или группу) полностью — вместе с перепиской.
  Future<void> deleteContact(String id) async {
    // Из группы сначала выходим — чтобы остальные знали.
    if (contact(id)?.group case final g? when !g.left && !(contact(id)?.request ?? false)) {
      await leaveGroup(id);
    }
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
    // Теперь это друг — его фото и голосовые скачиваются сами.
    live?.resumeMedia();
    notifyChanged();
  }

  void deleteMessage(String chatId, Message m) {
    messagesOf(chatId).remove(m);
    live?.store.deleteMessage(m.id);
    live?.media.deleteFile(m);
    notifyChanged();
  }

  /// Изменить текст своего сообщения (подпись к вложению — тоже).
  void editMessage(String chatId, Message m, String text) {
    if (!m.mine || text.trim().isEmpty || text == m.text) return;
    m
      ..text = text
      ..edited = true;
    live?.editMessage(chatId, m);
    notifyChanged();
  }

  /// Удалить своё сообщение у всех (у собеседника или у всей группы).
  void deleteForAll(String chatId, Message m) {
    if (!m.mine) return;
    live?.deleteForAll(chatId, m);
    final c = contact(chatId);
    if (c?.pinnedMsg == m.id) pinMessage(chatId, null);
    deleteMessage(chatId, m);
  }

  /// Закрепить сообщение вверху чата (null — открепить) — у всех.
  void pinMessage(String chatId, Message? m) {
    final c = contact(chatId);
    if (c == null) return;
    c.pinnedMsg = m?.id;
    live?.pinMessage(c);
    notifyChanged();
  }

  /// Закреплённое сообщение чата.
  Message? pinnedOf(String chatId) {
    final id = contact(chatId)?.pinnedMsg;
    if (id == null) return null;
    for (final m in messagesOf(chatId)) {
      if (m.id == id) return m;
    }
    return null;
  }

  bool isStarred(String chatId, Message m) => starred.contains('$chatId|${m.id}');

  void toggleStar(String chatId, Message m) {
    final k = '$chatId|${m.id}';
    starred.contains(k) ? starred.remove(k) : starred.add(k);
    _saveSettings();
  }

  /// Избранное: (чат, сообщение), новые сверху.
  List<(Contact, Message)> get starredMessages {
    final out = <(Contact, Message)>[];
    for (final k in starred) {
      final i = k.indexOf('|');
      if (i < 0) continue;
      final c = contact(k.substring(0, i));
      if (c == null) continue;
      final id = k.substring(i + 1);
      for (final m in messagesOf(c.id)) {
        if (m.id == id) out.add((c, m));
      }
    }
    out.sort((a, b) => b.$2.time.compareTo(a.$2.time));
    return out;
  }

  void toggleArchive(String id) {
    archived.contains(id) ? archived.remove(id) : archived.add(id);
    pinned.remove(id);
    _saveSettings();
  }

  /// Пометить чат непрочитанным (напоминание себе).
  void markUnread(String id) {
    if ((unread[id] ?? 0) > 0) return;
    unread[id] = 1;
    notifyChanged();
  }

  /// Переслать сообщение в другой чат. Файл отправляется заново (свежая копия
  /// на ретрансляторах). null — файла на телефоне нет (сначала скачать).
  Future<Message?> forward(String fromChat, Message m, String toChat) async {
    final origin = m.fwd ?? (m.mine ? (profile?.name ?? 'Я') : _authorName(fromChat, m));
    final att = m.att;
    if (att != null) {
      final path = att.path;
      if (path != null && (demo || File(path).existsSync())) {
        final copy = await sendFile(
          toChat,
          kind: m.kind,
          path: path,
          name: att.name,
          mime: att.mime,
          size: att.size,
          caption: m.text,
          width: att.width,
          height: att.height,
          duration: att.duration,
          thumb: att.thumb,
          wave: att.wave,
          fwd: origin,
        );
        return copy;
      }
      // Файла на телефоне нет (ещё не скачан) — пересылать нечего.
      return null;
    }
    final poll = m.poll;
    return send(
      toChat,
      m.text,
      kind: m.kind,
      geo: m.geo,
      poll: poll == null
          ? null
          : Poll(question: poll.question, options: [...poll.options], multi: poll.multi),
      voiceSeconds: m.voiceSeconds,
      fwd: origin,
    );
  }

  String _authorName(String chatId, Message m) {
    final from = m.from;
    if (from != null) return memberName(chatId, from);
    return contact(chatId)?.name ?? 'Кто-то';
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
    if (typingIndicators && !ultra) live?.typing(chatId);
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

  Message send(
    String chatId,
    String text, {
    Message? replyTo,
    bool secret = false,
    MsgKind kind = MsgKind.text,
    int voiceSeconds = 0,
    Attachment? att,
    GeoPoint? geo,
    Poll? poll,
    String? id,
    String? fwd,
    bool silent = false,
  }) {
    final m = compose(
      chatId,
      text,
      replyTo: replyTo,
      secret: secret,
      kind: kind,
      voiceSeconds: voiceSeconds,
      att: att,
      geo: geo,
      poll: poll,
      id: id,
      fwd: fwd,
    );
    drafts.remove(chatId);
    final c = contact(chatId);
    if (c != null && c.request) {
      // Ответили незнакомцу — значит, приняли его.
      c.request = false;
      live?.saveContact(c);
      live?.resumeMedia();
    }
    notifyChanged();
    if (live != null) {
      live!.sendMessage(chatId, m, silent: silent).then((_) => notifyChanged());
    } else {
      _simulateReply(chatId, m);
    }
    return m;
  }

  /// Новое исходящее сообщение в ленте чата (ещё не отправлено).
  Message compose(
    String chatId,
    String text, {
    Message? replyTo,
    bool secret = false,
    MsgKind kind = MsgKind.text,
    int voiceSeconds = 0,
    Attachment? att,
    GeoPoint? geo,
    Poll? poll,
    String? id,
    String? fwd,
    String? ev,
  }) {
    // Время строго больше предыдущего — чтобы порядок не «прыгал» после перезапуска.
    // (в базе время хранится с точностью до миллисекунды).
    var ms = DateTime.now().millisecondsSinceEpoch;
    final last = lastMessage(chatId);
    if (last != null && ms <= last.time.millisecondsSinceEpoch) {
      ms = last.time.millisecondsSinceEpoch + 1;
    }
    final m = Message(
      id: id ?? newMessageId(),
      mine: true,
      text: text,
      time: DateTime.fromMillisecondsSinceEpoch(ms),
      status: kind == MsgKind.event && live == null ? MsgStatus.read : MsgStatus.sending,
      replyTo: replyTo,
      secret: secret,
      kind: kind,
      voiceSeconds: voiceSeconds,
      att: att,
      geo: geo,
      poll: poll,
      fwd: fwd,
      ev: ev,
    );
    messagesOf(chatId).add(m);
    return m;
  }

  // ───────────────────────── Группы ─────────────────────────

  /// Друзья (без групп).
  List<Contact> get friends => [
    for (final c in contacts)
      if (!c.isGroup) c,
  ];

  /// Имя участника группы: как он записан у меня в друзьях, иначе — как назвался.
  String memberName(String chatId, String pub) {
    if (pub == me) return profile?.name ?? 'Я';
    final c = contact(pub);
    if (c != null && !c.isGroup) return c.name;
    return contact(chatId)?.group?.member(pub)?.name ?? 'Участник';
  }

  /// Текст события группы с именем того, кто его сделал.
  String eventText(String chatId, Message m) =>
      '${m.mine ? 'Ты' : memberName(chatId, m.from ?? '')} ${m.text}';

  /// Строка для списка чатов: в группе — с именем автора.
  String previewOf(String chatId, Message m) {
    if (m.kind == MsgKind.event) return eventText(chatId, m);
    final text = Fmt.plain(m.preview);
    if (!m.mine && m.from != null) return '${memberName(chatId, m.from!)}: $text';
    return text;
  }

  GroupMember _meAsMember() => GroupMember(
    pub: me,
    name: profile?.name ?? 'Я',
    emoji: profile?.emoji ?? '🙂',
    color: profile?.colorIndex ?? 0,
  );

  static GroupMember _asMember(Contact c) =>
      GroupMember(pub: c.id, name: c.name, emoji: c.emoji, color: c.colorIndex);

  /// Создать группу из друзей [pubs].
  Future<Contact> createGroup({
    required String name,
    required String emoji,
    required int colorIndex,
    required List<String> pubs,
  }) async {
    final members = [
      _meAsMember(),
      for (final pub in pubs.take(GroupInfo.maxMembers - 1))
        if (contact(pub) case final c? when !c.isGroup) _asMember(c),
    ];
    final g = Contact(
      id: 'g_${randomHex(32).toLowerCase()}',
      name: name,
      emoji: emoji,
      colorIndex: colorIndex,
    )..group = GroupInfo(members: members, admin: me, ver: DateTime.now().millisecondsSinceEpoch);
    contacts.add(g);
    await live?.saveContact(g);
    await _groupEvent(g, 'create', 'создал(а) группу «$name»');
    return g;
  }

  /// Добавить друзей в группу (только администратор).
  Future<void> addMembers(String groupId, List<String> pubs) async {
    final g = contact(groupId);
    final info = g?.group;
    if (g == null || info == null || info.admin != me) return;
    final added = <GroupMember>[];
    for (final pub in pubs) {
      final c = contact(pub);
      if (c == null || c.isGroup || info.has(pub)) continue;
      if (info.members.length >= GroupInfo.maxMembers) break;
      added.add(_asMember(c));
    }
    if (added.isEmpty) return;
    info.members.addAll(added);
    info.ver = DateTime.now().millisecondsSinceEpoch;
    await live?.saveContact(g);
    await _groupEvent(g, 'add', 'добавил(а): ${added.map((m) => m.name).join(', ')}');
  }

  /// Удалить участника (только администратор). Он узнает об этом последним сообщением.
  Future<void> removeMember(String groupId, String pub) async {
    final g = contact(groupId);
    final info = g?.group;
    if (g == null || info == null || info.admin != me || pub == me) return;
    final m = info.member(pub);
    if (m == null) return;
    info.members.remove(m);
    info.ver = DateTime.now().millisecondsSinceEpoch;
    await live?.saveContact(g);
    await _groupEvent(g, 'remove', 'удалил(а): ${memberName(groupId, pub)}', extra: [pub]);
  }

  /// Переименовать группу / сменить значок (только администратор).
  Future<void> editGroup(String groupId, {required String name, required String emoji}) async {
    final g = contact(groupId);
    final info = g?.group;
    if (g == null || info == null || info.admin != me) return;
    if (g.name == name && g.emoji == emoji) return;
    g
      ..name = name
      ..emoji = emoji;
    info.ver = DateTime.now().millisecondsSinceEpoch;
    await live?.saveContact(g);
    await _groupEvent(g, 'rename', 'изменил(а) группу: $emoji $name');
  }

  /// Выйти из группы. Администратор передаёт права следующему участнику.
  Future<void> leaveGroup(String groupId) async {
    final g = contact(groupId);
    final info = g?.group;
    if (g == null || info == null || info.left) return;
    if (info.admin == me) {
      final next = info.members.where((m) => m.pub != me).firstOrNull;
      if (next != null) {
        info.admin = next.pub;
        info.ver = DateTime.now().millisecondsSinceEpoch;
      }
    }
    // Сначала отправить «вышел» всем, потом отметить выход.
    await _groupEvent(g, 'leave', 'вышел(а) из группы');
    info.left = true;
    info.members.removeWhere((m) => m.pub == me);
    await live?.saveContact(g);
    notifyChanged();
  }

  Future<void> _groupEvent(
    Contact g,
    String ev,
    String text, {
    List<String> extra = const [],
  }) async {
    final m = compose(g.id, text, kind: MsgKind.event, ev: ev);
    notifyChanged();
    await live?.sendMessage(g.id, m, extra: extra);
    notifyChanged();
  }

  String newMessageId() => randomHex(16).toLowerCase();

  /// Мой идентификатор в голосах опросов.
  String get me => live?.keys?.pub ?? 'me';

  /// Ход передачи файлов: id сообщения → доля 0..1. Слушается каждым
  /// пузырём отдельно — прогресс не перерисовывает весь чат.
  final Map<String, ValueNotifier<double>> transfers = {};

  /// Передачи, которые не удались (показываем «повторить»).
  final Set<String> failedTransfers = {};

  /// Отправить файл (фото, видео, голосовое, документ). [path] — исходный файл;
  /// он копируется в папку приложения.
  Future<Message> sendFile(
    String chatId, {
    required MsgKind kind,
    required String path,
    required String name,
    required String mime,
    required int size,
    String caption = '',
    int width = 0,
    int height = 0,
    int duration = 0,
    String? thumb,
    List<int>? wave,
    Message? replyTo,
    String? fwd,
  }) async {
    final id = newMessageId();
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final local = live == null ? path : await live!.media.import(chatId, id, path, ext);
    // Временную копию (запись голоса, снимок, копия из галереи) больше не храним.
    if (live != null && local != path) await live!.media.dropTemp(path);
    return send(
      chatId,
      caption,
      id: id,
      kind: kind,
      replyTo: replyTo,
      fwd: fwd,
      att: Attachment(
        name: name,
        mime: mime,
        size: size,
        width: width,
        height: height,
        duration: duration,
        thumb: thumb,
        wave: wave,
        path: local,
      ),
    );
  }

  Message sendLocation(String chatId, GeoPoint point, {Message? replyTo}) =>
      send(chatId, '', kind: MsgKind.geo, geo: point, replyTo: replyTo);

  Message sendPoll(String chatId, Poll poll) => send(chatId, '', kind: MsgKind.poll, poll: poll);

  /// Проголосовать в опросе (повторно — изменить голос; пустой список — отозвать).
  void vote(String chatId, Message m, List<int> options) {
    final poll = m.poll;
    if (poll == null) return;
    if (live != null) {
      live!.vote(chatId, m, options);
    } else {
      poll.votes[me] = Poll.cleanVote(options, poll.options.length);
      // Демо: друг тоже голосует.
      if (!poll.votes.containsKey(chatId)) {
        _later(1200, () => poll.votes[chatId] = [_rnd.nextInt(poll.options.length)]);
      }
    }
    notifyChanged();
  }

  /// Скачать файл из сообщения (документы — по нажатию; повтор после ошибки).
  void download(String chatId, Message m) => live?.media.download(chatId, m);

  /// Повторить отправку файла после ошибки.
  void retrySend(String chatId, Message m) => live?.media.send(chatId, m);

  /// Новое входящее сообщение (из сети). [silent] — отправитель попросил без звука.
  Future<void> onIncoming(Contact c, Message m, {bool silent = false}) async {
    final visible = foreground && openChat == c.id && !locked;
    if (visible) {
      await live?.markRead(c.id, sendReceipt: readReceipts);
      return;
    }
    unread[c.id] = (unread[c.id] ?? 0) + 1;
    if (muted.contains(c.id) || silent) return;
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
    _notifyTimer?.cancel();
    themeTick.dispose();
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
