import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/biometric.dart';
import '../core/media_tools.dart';
import '../core/nostr.dart';
import '../core/protocol.dart';
import '../core/recovery.dart';
import '../core/relay_pool.dart';
import '../core/transfer.dart';
import '../games/lots.dart';
import '../games/ttt.dart';
import '../models/models.dart';
import '../theme/palette.dart';
import '../theme/skin.dart';
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

  /// Идёт первая настройка (регистрация или вход): главный экран — только
  /// после последнего шага, даже если профиль уже создан.
  bool setupPending = false;

  void finishSetup() {
    setupPending = false;
    notifyChanged();
    syncInstantService();
  }

  /// Приложение работает без окна (подняла служба «на связи» или окно
  /// закрыли): следующему окну нужно заново передать оформление.
  bool windowless = false;

  Profile? profile;
  bool get onboarded => profile != null;

  bool hasPin = false;
  String? _demoPin;
  bool locked = false;

  /// Разблокировка по отпечатку / лицу (вместе с PIN-кодом, не вместо него).
  bool biometric = false;

  // ── Тайник ──

  /// Задан PIN тайника (скрытые чаты).
  bool vaultSet = false;

  /// Тайник открыт (вошли PIN-ом тайника) — скрытые чаты видны до блокировки.
  bool vaultOpen = false;

  /// Задан PIN «под принуждением»; [duressWipe] — он стирает всё, а не прячет.
  bool duressSet = false;
  bool duressWipe = false;

  /// Вошли PIN-ом «под принуждением»: тайника как будто нет.
  bool decoy = false;

  /// Маскировка значка: 0 — нет, 1 — «Калькулятор», 2 — «Заметки».
  int disguise = 0;

  /// Сейчас показана «обложка» (калькулятор / заметки) вместо Veil.
  bool covered = false;

  /// Заметки-обложка (в маскировке «Заметки»).
  final List<String> coverNotes = [];

  /// Демо: секреты в памяти.
  final Map<String, String> _demoSecrets = {};

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
  /// Без серверов и Google-пушей это единственный способ получать сообщения
  /// сразу — поэтому у нового аккаунта включено (выключить — в Приватности).
  bool instantNotify = true;

  /// Режим «Ультра» — максимальная экономия батареи: без анимаций и размытия,
  /// тёмная тема, 4 ретранслятора вместо 9, без «в сети» и «печатает»,
  /// видео — по нажатию, без постоянной связи в фоне.
  bool ultra = false;

  /// Что реально действует (с учётом «Ультра»).
  /// Включать «Ультра» самому при заряде не выше этого (0 — не включать).
  int ultraAuto = 0;

  /// «Ультра» включился сам (по заряду) — сам и выключится на зарядке.
  bool ultraByBattery = false;

  /// Что сэкономил «Ультра» с момента запуска (для карточки в настройках).
  int savedSignals = 0;
  int savedDownloads = 0;

  /// Стиль оформления (0 Veil · 1 Терминал · 2 Космос · 3 Лимонад) и его
  /// мелкие настройки, см. theme/skin.dart.
  int skinId = 0;
  final Map<String, int> skinOpts = {};
  Skin? _skin;

  /// Действующий стиль: «Ультра» всегда возвращает классический чёрный.
  Skin get skin => ultra ? Skin.classic : (_skin ??= Skin.of(skinId, Map.of(skinOpts)));

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
    // Свои стикеры маленькие — всегда сразу.
    MsgKind.sticker => true,
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

  Accent get accent => skin.accent ?? accents[accentIndex];

  /// Цвет текста на своих пузырях: на градиенте — свой у акцента, у
  /// «Терминала» пузыри контурные — обычный цвет текста.
  Color get mineFg => skin.outlineMine ? colors.text : accent.onAccent;
  VeilColors get colors => ultra
      ? VeilColors.amoledColors
      : skin.colors ?? (effDark ? VeilColors.darkColors : VeilColors.lightColors);

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

  /// Виден ли чат сейчас (скрытые — только при открытом тайнике).
  bool visible(Contact c) => !c.hidden || (vaultOpen && !decoy);

  /// Чаты в тайнике (при входе «под принуждением» — пусто).
  List<Contact> get hiddenChats {
    if (decoy) return const [];
    final list = contacts.where((c) => c.hidden).toList();
    list.sort((a, b) {
      final ta = lastMessage(a.id)?.time ?? DateTime(2000);
      final tb = lastMessage(b.id)?.time ?? DateTime(2000);
      return tb.compareTo(ta);
    });
    return list;
  }

  /// Чаты: закреплённые сверху, остальные по времени последнего сообщения.
  /// Архивные — отдельно ([archivedChats]).
  List<Contact> get chatList => _chats(archived: false);

  List<Contact> get archivedChats => _chats(archived: true);

  List<Contact> _chats({required bool archived}) {
    final list = contacts
        .where(
          (c) =>
              (lastMessage(c.id) != null || drafts.containsKey(c.id)) &&
              visible(c) &&
              this.archived.contains(c.id) == archived,
        )
        .toList();
    list.sort((a, b) {
      final pa = pinned.contains(a.id), pb = pinned.contains(b.id);
      if (pa != pb) return pa ? -1 : 1;
      return chatTime(b.id).compareTo(chatTime(a.id));
    });
    return list;
  }

  int get totalUnread => unread.entries
      .where((e) => contact(e.key) == null || visible(contact(e.key)!))
      .fold(0, (a, e) => a + e.value);

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

  /// Создать профиль. [priv] — вход по ключу восстановления (аккаунт уже
  /// был), иначе ключ новый.
  Future<void> createProfile({
    required String name,
    required String emoji,
    required int colorIndex,
    String? priv,
  }) async {
    final l = live;
    if (l != null) {
      await l.createIdentity(
        (pub) => Profile(name: name, emoji: emoji, colorIndex: colorIndex, fingerprint: pub),
        priv: priv,
      );
    } else {
      _demoPriv = priv ?? Keys.generate().priv;
      profile = Profile(
        name: name,
        emoji: emoji,
        colorIndex: colorIndex,
        fingerprint: Keys(_demoPriv!).pub,
      );
    }
    // Свой ключ знаем и так — записывать его не нужно.
    if (priv != null) recoverySaved = true;
    notifyChanged();
  }

  String? _demoPriv;

  /// Ключ восстановления — 24 слова (только после проверки PIN / отпечатка).
  Future<List<String>?> recoveryWords() async {
    final priv = live != null ? await live!.secretKey() : _demoPriv;
    return priv == null ? null : Recovery.toWords(priv);
  }

  /// Ключ восстановления записан (иначе в профиле висит напоминание).
  bool recoverySaved = false;

  void markRecoverySaved() {
    recoverySaved = true;
    _saveSettings();
  }

  /// Сохранить зашифрованную копию (ключ, переписка, по желанию — файлы).
  Future<void> exportBackup(String out, String password, {bool withMedia = true}) =>
      live!.exportBackup(out, password, withMedia: withMedia);

  /// Восстановить всё из копии (на новом телефоне, вместо создания профиля).
  Future<void> restoreBackup(String path, String password) async {
    await live!.restoreBackup(path, password);
    notifyChanged();
  }

  /// Перенос на новый телефон (здесь — старый): код для QR.
  Future<TransferTicket> prepareTransfer({ValueNotifier<double>? progress}) =>
      live!.prepareTransfer(progress: progress);

  /// Перенос закончен или отменён — убрать пакет с ретрансляторов.
  Future<void> finishTransfer() async => live?.finishTransfer();

  /// Новый телефон: забрать всё по коду со старого.
  Future<void> receiveTransfer(TransferTicket t, {ValueNotifier<double>? progress}) async {
    await live!.receiveTransfer(t, progress: progress);
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
    if (skinId > 0) 'skin': skinId,
    if (skinOpts.isNotEmpty) 'skinOpt': Map.of(skinOpts),
    'instant': instantNotify,
    if (_birthdayNoted.isNotEmpty) 'bdn': _birthdayNoted,
    if (recoverySaved) 'rk': true,
    if (ultra) 'ultra': true,
    if (ultraAuto > 0) 'ultraAuto': ultraAuto,
    if (ultraByBattery) 'ultraBat': true,
    if (disguise > 0) 'disguise': disguise,
    if (coverNotes.isNotEmpty) 'notes': coverNotes,
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
    if (biometric) 'bio': true,
    if (myStickers.isNotEmpty) 'stickers': myStickers,
    if (myGifs.isNotEmpty) 'gifs': myGifs,
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
    skinId = ((s['skin'] as num?)?.toInt() ?? 0).clamp(0, Skin.names.length - 1);
    skinOpts.clear();
    final so = s['skinOpt'];
    if (so is Map) {
      for (final e in so.entries) {
        if (e.key is String && e.value is num) skinOpts[e.key as String] = (e.value as num).toInt();
      }
    }
    _skin = null;
    instantNotify = s['instant'] == true;
    _birthdayNoted
      ..clear()
      ..addAll({
        if (s['bdn'] is Map)
          for (final e in (s['bdn'] as Map).entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
      });
    recoverySaved = s['rk'] == true;
    ultra = s['ultra'] == true;
    ultraAuto = ((s['ultraAuto'] as num?)?.toInt() ?? 0).clamp(0, 50);
    ultraByBattery = s['ultraBat'] == true;
    disguise = ((s['disguise'] as num?)?.toInt() ?? 0).clamp(0, 2);
    coverNotes
      ..clear()
      ..addAll((s['notes'] as List? ?? const []).whereType<String>());
    wifiHintShown = s['wifiHint'] == true;
    biometric = s['bio'] == true;
    myStickers
      ..clear()
      ..addAll((s['stickers'] as List? ?? const []).whereType<String>());
    myGifs
      ..clear()
      ..addAll((s['gifs'] as List? ?? const []).whereType<String>());
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

  void setSkin(int id) {
    skinId = id;
    _skin = null;
    themeTick.value++;
    _saveSettings();
  }

  /// Мелкая настройка стиля (ключи — [Skin.options]).
  void setSkinOpt(String key, int v) {
    skinOpts[key] = v;
    _skin = null;
    themeTick.value++;
    _saveSettings();
  }

  static const _service = MethodChannel('veil/service');

  /// Включить/выключить режим «Ультра» (вручную — автоматика его не трогает).
  Future<void> setUltra(bool v, {bool byBattery = false}) async {
    if (ultra == v) return;
    ultra = v;
    ultraByBattery = v && byBattery;
    themeTick.value++;
    _saveSettings();
    live?.applyPower();
    await syncInstantService();
  }

  void setUltraAuto(int percent) {
    ultraAuto = percent;
    _saveSettings();
    checkBattery();
  }

  static const _power = MethodChannel('veil/power');

  /// Проверить заряд: мало и не заряжается — включить «Ультра»; поставили на
  /// зарядку — выключить, если включали сами.
  Future<void> checkBattery({int? level, bool? charging}) async {
    if (demo && level == null) return;
    if (level == null || charging == null) {
      try {
        final st = await _power.invokeMapMethod<String, Object?>('state');
        level = (st?['level'] as num?)?.toInt();
        charging = st?['charging'] == true;
      } catch (_) {
        return;
      }
    }
    if (level == null || level <= 0) return;
    if (ultraAuto > 0 && !ultra && !charging && level <= ultraAuto) {
      await setUltra(true, byBattery: true);
    } else if (ultra && ultraByBattery && (charging || level > ultraAuto + 5)) {
      await setUltra(false);
    }
  }

  /// Включить/выключить «мгновенные уведомления».
  Future<void> setInstantNotify(bool v) async {
    instantNotify = v;
    _saveSettings();
    await syncInstantService();
  }

  /// Запустить или остановить службу «на связи» по текущей настройке.
  Future<void> syncInstantService() async {
    // До конца регистрации служба не нужна: аккаунта ещё нет.
    if (demo || live == null || !onboarded || setupPending) return;
    try {
      // В «Ультра» постоянную связь в фоне не держим — проверка по расписанию.
      // При маскировке тоже: значок «Veil на связи» в шторке выдал бы приложение.
      await _service.invokeMethod<bool>(
        instantNotify && !ultra && disguise == 0 ? 'start' : 'stop',
      );
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
    _secure
        .invokeMethod('setSecure', screenshotProtection || _secureScreens > 0)
        .catchError((_) => null);
  }

  int _secureScreens = 0;

  /// Экран с секретом (ключ восстановления, код переноса): пока он открыт —
  /// без скриншотов, даже если запрет в настройках выключен.
  void secureScreen(bool on) {
    _secureScreens = max(0, _secureScreens + (on ? 1 : -1));
    applyScreenshotProtection();
  }

  // ───────────────────────── Тайник ─────────────────────────

  Future<void> _setSecret(String key, String? pin) async {
    if (live != null) {
      await live!.setSecret(key, pin);
    } else {
      pin == null ? _demoSecrets.remove(key) : _demoSecrets[key] = pin;
    }
  }

  Future<bool> _checkSecret(String key, String pin) async =>
      live != null ? live!.checkSecret(key, pin) : _demoSecrets[key] == pin;

  /// Такой PIN уже занят (основной, тайника или «под принуждением») — нельзя.
  Future<bool> pinTaken(String pin) async =>
      (hasPin && await checkPin(pin)) ||
      (vaultSet && await _checkSecret('vault', pin)) ||
      (duressSet && await _checkSecret('duress', pin));

  /// Задать / убрать PIN тайника. Без PIN скрытые чаты возвращаются в список.
  Future<void> setVaultPin(String? pin) async {
    if (decoy) return; // «под принуждением» — делаем вид, что всё получилось
    await _setSecret('vault', pin);
    vaultSet = pin != null;
    if (pin == null) {
      for (final c in contacts.where((c) => c.hidden).toList()) {
        c.hidden = false;
        await live?.saveContact(c);
      }
    }
    notifyChanged();
  }

  /// Открыть тайник по PIN (для экрана скрытых чатов).
  Future<bool> checkVault(String pin) async =>
      !decoy && vaultSet && await _checkSecret('vault', pin);

  /// Спрятать чат в тайник / вернуть.
  void setHidden(String id, bool hidden) {
    final c = contact(id);
    if (c == null || (hidden && !vaultSet) || decoy) return;
    c.hidden = hidden;
    if (hidden) pinned.remove(id);
    live?.saveContact(c);
    _saveSettings();
  }

  /// PIN «под принуждением»: [wipe] — стирает всё, иначе открывает Veil без тайника.
  Future<void> setDuressPin(String? pin, {bool wipe = false}) async {
    if (decoy) return;
    await _setSecret('duress', pin);
    duressSet = pin != null;
    duressWipe = pin != null && wipe;
    if (live != null) await live!.secrets.write('duress_mode', duressWipe ? 'wipe' : 'hide');
    notifyChanged();
  }

  Future<void> setDuressWipe(bool wipe) async {
    if (decoy || !duressSet) return;
    duressWipe = wipe;
    if (live != null) await live!.secrets.write('duress_mode', wipe ? 'wipe' : 'hide');
    notifyChanged();
  }

  static const _disguiseChannel = MethodChannel('veil/disguise');

  /// Маскировка значка: 0 — Veil, 1 — «Калькулятор», 2 — «Заметки». [code] —
  /// код входа (вводится в калькуляторе перед «=» или в поиске заметок).
  Future<void> setDisguise(int mode, {String? code}) async {
    if (decoy) return;
    if (mode > 0 && code != null) await _setSecret('cover', code);
    if (mode == 0) await _setSecret('cover', null);
    disguise = mode;
    _saveSettings();
    await syncInstantService();
    if (!demo) {
      try {
        await _disguiseChannel.invokeMethod('set', mode);
      } catch (_) {}
    }
  }

  /// Ввели код на «обложке». Верный — открываем Veil (это же и разблокировка).
  Future<bool> tryCover(String code) async {
    if (code.length < 4 || !await _checkSecret('cover', code)) return false;
    covered = false;
    // Код маскировки — тоже вход: PIN после него не спрашиваем.
    locked = false;
    decoy = false;
    notifyChanged();
    return true;
  }

  /// Ввод PIN на экране блокировки: основной, тайника или «под принуждением».
  Future<bool> unlockWith(String pin) async {
    if (await checkPin(pin)) {
      decoy = false;
      unlocked();
      return true;
    }
    if (vaultSet && await _checkSecret('vault', pin)) {
      decoy = false;
      vaultOpen = true;
      unlocked();
      return true;
    }
    if (duressSet && await _checkSecret('duress', pin)) {
      if (duressWipe) {
        await wipeEverything();
      } else {
        decoy = true;
        vaultOpen = false;
        unlocked();
      }
      return true;
    }
    return false;
  }

  void saveCoverNotes() => _saveSettings();

  /// Включить вход по отпечатку — только подтвердив его прямо сейчас.
  Future<bool> setBiometric(bool v) async {
    if (v && !await Biometric.check('Подтверди, чтобы входить в Veil по отпечатку')) {
      return false;
    }
    biometric = v;
    _saveSettings();
    return true;
  }

  /// Разблокировать по отпечатку / лицу. Тайник так не открывается — только
  /// обычный вход (тайник — своим PIN).
  Future<bool> unlockWithBiometric() async {
    if (!biometric || !hasPin || !locked || covered) return false;
    if (!await Biometric.check('Войти в Veil')) return false;
    decoy = false;
    unlocked();
    return true;
  }

  Future<void> setPin(String? value) async {
    // Без PIN нет и входа по отпечатку.
    if (value == null && biometric) {
      biometric = false;
      _saveSettings();
    }
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

  /// Свернули приложение (или «Заблокировать сейчас»): тайник закрывается,
  /// включается обложка-маскировка и PIN.
  void lock() {
    vaultOpen = false;
    if (disguise > 0) covered = true;
    if (hasPin) locked = true;
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
      checkBattery();
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
    _dropDraft(id);
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
    // Ещё не ушло (например, запланированное) — убрать и из очереди.
    if (m.mine && m.status == MsgStatus.sending) live?.cancelQueued(chatId, m);
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

  /// Одноразовое открыли и закрыли: файл стирается, автор видит «просмотрено».
  Future<void> openedOnce(String chatId, Message m) async {
    if (m.mine || m.opened) return;
    if (live != null) {
      await live!.openedOnce(chatId, m);
    } else {
      m.opened = true;
      m.att?.path = null;
    }
    notifyChanged();
  }

  /// Показ одноразового: запрет скриншотов на время просмотра.
  void secureFor(bool on) {
    if (demo) return;
    _secure.invokeMethod('setSecure', on || screenshotProtection).catchError((_) => null);
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
      if (c == null || !visible(c)) continue;
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
      sticker: m.sticker,
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

  /// Когда начат черновик (для порядка в списке чатов).
  final Map<String, DateTime> draftAt = {};
  Timer? _draftTimer;

  /// Запомнить черновик (сохраняется и после перезапуска).
  void saveDraft(String chatId, String text) {
    final had = drafts[chatId];
    if (text.trim().isEmpty) {
      if (had == null) return;
      drafts.remove(chatId);
      draftAt.remove(chatId);
    } else {
      if (had == text) return;
      drafts[chatId] = text;
      draftAt[chatId] ??= DateTime.now();
    }
    // Пишем в базу не на каждую букву, а когда пауза.
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 800), _persistDrafts);
    // В списке чатов черновик появился или исчез.
    if ((had == null) != (drafts[chatId] == null)) notifyChanged();
  }

  void _dropDraft(String chatId) {
    if (drafts.remove(chatId) == null) return;
    draftAt.remove(chatId);
    _draftTimer?.cancel();
    _persistDrafts();
  }

  void _persistDrafts() => live?.saveDrafts({
    for (final e in drafts.entries)
      e.key: {'t': e.value, 'at': (draftAt[e.key] ?? DateTime.now()).millisecondsSinceEpoch},
  });

  /// Черновики из базы (при запуске).
  void loadDrafts(Map<String, dynamic> j) {
    drafts.clear();
    draftAt.clear();
    for (final e in j.entries) {
      final v = e.value;
      if (v is! Map || v['t'] is! String) continue;
      drafts[e.key] = v['t'] as String;
      draftAt[e.key] = DateTime.fromMillisecondsSinceEpoch((v['at'] as num?)?.toInt() ?? 0);
    }
  }

  /// Время для сортировки списка чатов: последнее сообщение или черновик.
  DateTime chatTime(String id) {
    final m = lastMessage(id)?.time;
    final d = draftAt[id];
    if (m == null) return d ?? DateTime(2000);
    if (d == null) return m;
    return d.isAfter(m) ? d : m;
  }

  /// Пользователь что-то набирает в чате.
  void userTyping(String chatId) {
    if (!typingIndicators) return;
    if (ultra) {
      savedSignals++;
      return;
    }
    live?.typing(chatId);
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
    bool once = false,
    DateTime? openAt,
    DateTime? sendAt,
    Todo? todo,
    String? sticker,
    Game? game,
    Drawing? drawing,
    String? fx,
    String? story,
  }) {
    final m = compose(
      chatId,
      text,
      sticker: sticker,
      game: game,
      drawing: drawing,
      fx: fx,
      story: story,
      replyTo: replyTo,
      secret: secret,
      kind: kind,
      voiceSeconds: voiceSeconds,
      att: att,
      geo: geo,
      poll: poll,
      id: id,
      fwd: fwd,
      once: once,
      openAt: openAt,
      todo: todo,
    );
    if (sendAt != null && sendAt.isAfter(DateTime.now())) m.sendAt = sendAt;
    _dropDraft(chatId);
    if (Contact.isLocalId(chatId)) {
      // «Заметки»: никуда не отправляем — сразу «готово».
      m
        ..status = MsgStatus.read
        ..sendAt = null;
      notifyChanged();
      live?.saveMessage(chatId, m);
      return m;
    }
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
    } else if (m.sendAt == null) {
      _simulateReply(chatId, m);
    }
    return m;
  }

  /// Создать общий список дел.
  Message sendTodo(String chatId, Todo todo) => send(chatId, '', kind: MsgKind.todo, todo: todo);

  // ───────────────────────── игры ─────────────────────────

  /// Новая игра или жребий (только в личном чате).
  Message sendGame(String chatId, Game game) {
    final m = send(chatId, '', kind: MsgKind.game, game: game);
    if (demo) _demoOpponent(m);
    return m;
  }

  /// Демо: «соперник» отвечает сам — жребий и крестики-нолики.
  void _demoOpponent(Message m) {
    final g = m.game;
    if (g == null) return;
    final other = m.mine ? 1 : 0;
    _later(900, () {
      final s = g.state;
      if (s is Lot && g.type == 'rps' && s.awaitingSecond) {
        g.moves.add('$other${'rps'[_rnd.nextInt(3)]}');
      } else if (s is Ttt && s.winner == null && s.turn == other) {
        final free = [
          for (var i = 0; i < 9; i++)
            if (s.cells[i] < 0) i,
        ];
        if (free.isNotEmpty) g.moves.add('$other${free[_rnd.nextInt(free.length)]}');
      }
      g.autoMoves(other);
      g.autoMoves(1 - other);
    });
  }

  /// Свой ход: [move] без роли — роль подставится. false — так нельзя.
  bool gameMove(String chatId, Message m, String move) {
    final g = m.game;
    if (g == null) return false;
    final full = '${m.mine ? 0 : 1}$move';
    if (!g.validList([...g.moves, full])) return false;
    g.moves.add(full);
    tick(HapticKind.light);
    notifyChanged();
    if (live != null) {
      live!.gameMoved(chatId, m).then((_) => notifyChanged());
    } else {
      // Демо: телефон «соперника» отвечает сам (жребий, выстрелы).
      g.autoMoves(m.mine ? 0 : 1);
      _demoOpponent(m);
    }
    return true;
  }

  /// Открыли чат — сверить ходы незаконченных игр.
  void gameCheck(String chatId) => live?.gameCheck(chatId);

  /// Сохранить свой секрет игры (расстановку кораблей) и сделать ход.
  bool gameSetup(String chatId, Message m, String secret, String move) {
    final g = m.game;
    if (g == null) return false;
    final old = g.secret;
    g.secret = secret;
    if (gameMove(chatId, m, move)) return true;
    g.secret = old;
    return false;
  }

  /// Соперник сходил — мой ход (если чат не на экране — уведомление).
  Future<void> onGameTurn(Contact c, Message m) async {
    final onScreen = foreground && openChat == c.id && !locked;
    if (onScreen || muted.contains(c.id) || !visible(c)) return;
    final turn = Message(
      id: 'turn-${m.id}',
      mine: false,
      text: 'Твой ход: ${m.game!.emoji} ${m.game!.title}',
      time: DateTime.now(),
    );
    if (foreground && !locked) {
      _incoming.add(Incoming(c, turn));
    } else {
      await live?.notify?.message(c, turn);
    }
  }

  // ───────────────────────── рисунок ─────────────────────────

  Message sendDrawing(String chatId) => send(chatId, '', kind: MsgKind.draw, drawing: Drawing());

  /// Меняется, когда в каком-то рисунке появился или исчез штрих.
  final drawUpdates = ValueNotifier<int>(0);

  void drawingChanged(String id) {
    drawUpdates.value++;
    notifyChanged();
  }

  String get myKey => profile?.fingerprint ?? 'me';

  void drawAdd(String chatId, Message m, Stroke st) {
    final d = m.drawing;
    if (d == null || d.strokes.length >= Drawing.maxStrokes) return;
    d.strokes.add(st);
    drawingChanged(m.id);
    live?.drawOp(chatId, m, {
      'op': 'a',
      's': {'i': st.id, 'c': st.color, 'w': st.width, 'p': st.pts},
    });
  }

  /// Отменить свой последний штрих.
  void drawUndo(String chatId, Message m) {
    final d = m.drawing;
    if (d == null) return;
    final i = d.strokes.lastIndexWhere((s) => s.by == myKey);
    if (i < 0) return;
    final st = d.strokes.removeAt(i);
    drawingChanged(m.id);
    live?.drawOp(chatId, m, {'op': 'u', 'i': st.id});
  }

  // ───────────────────────── эффекты ─────────────────────────

  /// Эффект сообщения показан — второй раз не показывать.
  void markFxSeen(String chatId, Message m) {
    if (m.fxSeen) return;
    m.fxSeen = true;
    live?.saveMessage(chatId, m);
  }

  /// Отметить / снять пункт общего списка — у всех в чате.
  void todoToggle(String chatId, Message m, String itemId) {
    final it = m.todo?.item(itemId);
    if (it == null) return;
    it
      ..done = !it.done
      ..by = it.done ? me : null;
    live?.todoOp(chatId, m, {'op': 't', 'i': itemId, 'on': it.done});
    notifyChanged();
  }

  /// Добавить пункт в общий список.
  void todoAdd(String chatId, Message m, String text) {
    final todo = m.todo;
    final t = text.trim();
    if (todo == null || t.isEmpty || todo.items.length >= Todo.maxItems) return;
    final id = randomHex(8).toLowerCase();
    todo.items.add(TodoItem(id: id, text: t.length > 200 ? t.substring(0, 200) : t));
    live?.todoOp(chatId, m, {'op': 'a', 'i': id, 'tx': t});
    notifyChanged();
  }

  /// Запланированное — отправить сейчас.
  void sendNow(String chatId, Message m) {
    if (m.sendAt == null) return;
    if (live != null) {
      live!.sendNow(chatId, m).then((_) => notifyChanged());
    } else {
      m.sendAt = null;
      _simulateReply(chatId, m);
    }
    notifyChanged();
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
    bool once = false,
    DateTime? openAt,
    Todo? todo,
    String? sticker,
    Game? game,
    Drawing? drawing,
    String? fx,
    String? story,
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
      once: once,
      openAt: openAt,
      todo: todo,
      sticker: sticker,
      game: game,
      drawing: drawing,
      fx: fx,
      // Свой эффект показываем сразу при отправке — второй раз не нужно.
      fxSeen: fx != null,
      story: story,
    );
    messagesOf(chatId).add(m);
    return m;
  }

  // ───────────────────────── Мои стикеры и GIF ─────────────────────────

  /// Свои стикеры (PNG с прозрачным фоном) и GIF — файлы в папке приложения.
  final List<String> myStickers = [];
  final List<String> myGifs = [];
  static const maxCollection = 60;

  Future<String> _collectionPath(String folder, String ext) async {
    final root = live == null ? Directory.systemTemp.path : await live!.media.root();
    final dir = Directory('$root/$folder');
    await dir.create(recursive: true);
    return '${dir.path}/${newMessageId()}.$ext';
  }

  /// Положить стикер / GIF в свою коллекцию (копией). Вернёт путь копии.
  Future<String?> addToCollection(String src, {required bool gif}) async {
    final list = gif ? myGifs : myStickers;
    try {
      final f = File(src);
      if (!f.existsSync()) return null;
      final dst = await _collectionPath(gif ? '_gifs' : '_stickers', gif ? 'gif' : 'png');
      await f.copy(dst);
      list.insert(0, dst);
      while (list.length > maxCollection) {
        final old = list.removeLast();
        try {
          File(old).deleteSync();
        } catch (_) {}
      }
      _saveSettings();
      return dst;
    } catch (_) {
      return null;
    }
  }

  void removeFromCollection(String path) {
    if (!myStickers.remove(path) && !myGifs.remove(path)) return;
    try {
      File(path).deleteSync();
    } catch (_) {}
    _saveSettings();
  }

  /// Отправить свой стикер (картинку из коллекции).
  Future<Message> sendMySticker(String chatId, String path, {Message? replyTo}) async {
    final meta = await imageMeta(path);
    return sendFile(
      chatId,
      kind: MsgKind.sticker,
      path: path,
      name: 'sticker.png',
      mime: 'image/png',
      size: await File(path).length(),
      width: meta.width,
      height: meta.height,
      replyTo: replyTo,
    );
  }

  /// Отправить GIF: как фото, но без пересжатия — чтобы двигался.
  Future<Message> sendGif(String chatId, String path, {Message? replyTo}) async {
    final meta = await imageMeta(path);
    return sendFile(
      chatId,
      kind: MsgKind.photo,
      path: path,
      name: 'gif_${DateTime.now().millisecondsSinceEpoch}.gif',
      mime: 'image/gif',
      size: await File(path).length(),
      width: meta.width,
      height: meta.height,
      thumb: meta.thumb,
      replyTo: replyTo,
    );
  }

  /// Стикер из набора Veil (по сети уходит только его код).
  Message sendSticker(String chatId, String id, {Message? replyTo}) =>
      send(chatId, '', kind: MsgKind.sticker, sticker: id, replyTo: replyTo);

  // ───────────────────────── Группы ─────────────────────────

  /// Друзья (без групп).
  List<Contact> get friends => [
    for (final c in contacts)
      if (!c.isGroup && !c.isNotes && visible(c)) c,
  ];

  // ───────────────────────── Заметки ─────────────────────────

  /// Чат «Заметки» (создаётся при первом открытии).
  Contact notes() {
    final have = contact(Contact.notesId);
    if (have != null) return have;
    final c = Contact(id: Contact.notesId, name: 'Заметки', emoji: '📝', colorIndex: 3);
    contacts.add(c);
    live?.saveContact(c);
    return c;
  }

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
    // В канале пишет один автор — его имя не нужно.
    final channel = contact(chatId)?.isChannel ?? false;
    if (!m.mine && m.from != null && !channel) return '${memberName(chatId, m.from!)}: $text';
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

  // ───────────────────────── Каналы ─────────────────────────

  /// Только читаю: я подписчик канала (писать и реагировать может лишь автор).
  bool readOnly(Contact c) => c.isChannel && c.group!.admin != me;

  /// Создать канал: пишу только я; [pubs] — друзья, которых сразу подписать.
  Future<Contact> createChannel({
    required String name,
    required String emoji,
    required int colorIndex,
    List<String> pubs = const [],
  }) async {
    final subs = [
      for (final pub in pubs.take(GroupInfo.maxSubscribers))
        if (contact(pub) case final c? when !c.isGroup && !c.isNotes) _asMember(c),
    ];
    final g =
        Contact(
            id: 'g_${randomHex(32).toLowerCase()}',
            name: name,
            emoji: emoji,
            colorIndex: colorIndex,
          )
          ..group = GroupInfo(
            members: [_meAsMember(), ...subs],
            admin: me,
            ver: DateTime.now().millisecondsSinceEpoch,
            channel: true,
            code: randomHex(16).toLowerCase(),
          );
    contacts.add(g);
    await live?.saveContact(g);
    if (subs.isNotEmpty) await welcomeToChannel(g, [for (final m in subs) m.pub]);
    notifyChanged();
    return g;
  }

  /// Пригласительная ссылка канала (только у автора).
  String? channelLink(String id) {
    final g = contact(id);
    final info = g?.group;
    if (g == null || info == null || !info.channel || info.admin != me || info.left) return null;
    info.code ??= randomHex(16).toLowerCase();
    return ChannelInvite(
      id: g.id,
      admin: me,
      code: info.code!,
      name: g.name,
      emoji: g.emoji,
    ).encode();
  }

  /// Новая ссылка: старая перестаёт работать (уже подписанные остаются).
  Future<void> resetChannelLink(String id) async {
    final g = contact(id);
    final info = g?.group;
    if (g == null || info == null || !info.channel || info.admin != me) return;
    info.code = randomHex(16).toLowerCase();
    await live?.saveContact(g);
    notifyChanged();
  }

  /// Попроситься в канал по ссылке. Канал появится, когда автор будет в сети.
  /// false — уже подписан (или это мой канал).
  bool joinChannel(ChannelInvite inv) {
    final have = contact(inv.id);
    if (have != null && !(have.group?.left ?? true)) return false;
    if (inv.admin == me) return false;
    live?.joinChannel(inv);
    return true;
  }

  /// Прислать канал новым подписчикам (только им, в моей ленте — без следа).
  Future<void> welcomeToChannel(Contact g, List<String> pubs) =>
      _groupEvent(g, 'add', 'подписал(а) тебя на канал «${g.name}»', only: pubs, hidden: true);

  /// Добавить друзей в группу (только администратор). В канал — подписать.
  Future<void> addMembers(String groupId, List<String> pubs) async {
    final g = contact(groupId);
    final info = g?.group;
    if (g == null || info == null || info.admin != me) return;
    final added = <GroupMember>[];
    for (final pub in pubs) {
      final c = contact(pub);
      if (c == null || c.isGroup || c.isNotes || info.has(pub)) continue;
      if (info.members.length + added.length >= info.limit) break;
      added.add(_asMember(c));
    }
    if (added.isEmpty) return;
    info.members.addAll(added);
    info.ver = DateTime.now().millisecondsSinceEpoch;
    await live?.saveContact(g);
    if (info.channel) {
      await welcomeToChannel(g, [for (final m in added) m.pub]);
      notifyChanged();
      return;
    }
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
    if (info.channel) {
      // Отписанному — тихое событие; остальные подписчики ничего не видят.
      await _groupEvent(g, 'remove', 'отписал(а) тебя от канала', only: [pub], hidden: true);
      notifyChanged();
      return;
    }
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
    if (info.channel) {
      // Автор закрывает канал для всех; подписчик — просто отписывается.
      final mine = info.admin == me;
      await _groupEvent(
        g,
        mine ? 'close' : 'leave',
        mine ? 'закрыл(а) канал' : 'отписался(-ась) от канала',
      );
      info.left = true;
      await live?.saveContact(g);
      notifyChanged();
      return;
    }
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

  /// [only] — только этим участникам; [hidden] — у себя в ленте не оставлять.
  Future<void> _groupEvent(
    Contact g,
    String ev,
    String text, {
    List<String> extra = const [],
    List<String>? only,
    bool hidden = false,
  }) async {
    if (hidden) {
      // Только в очередь отправки — в моей ленте его нет.
      final m = Message(
        id: newMessageId(),
        mine: true,
        text: text,
        time: DateTime.now(),
        status: MsgStatus.sending,
        kind: MsgKind.event,
        ev: ev,
      );
      await live?.queueMessage(g.id, m, only: only, detached: true);
      return;
    }
    final m = compose(g.id, text, kind: MsgKind.event, ev: ev);
    notifyChanged();
    await live?.sendMessage(g.id, m, extra: extra, only: only);
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
    bool once = false,
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
      once: once,
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

  /// Ответили из шторки, не открывая приложение.
  void replyFromNotification(String chatId, String text) {
    final c = contact(chatId);
    final t = text.trim();
    if (c == null || t.isEmpty || c.blocked || readOnly(c) || (c.group?.left ?? false)) return;
    unread.remove(chatId);
    live?.markRead(chatId, sendReceipt: readReceipts);
    send(chatId, t);
  }

  /// Открыть чат (нажали на уведомление). Слушает главный экран.
  final openRequest = ValueNotifier<String?>(null);

  /// Новое входящее сообщение (из сети). [silent] — отправитель попросил без звука.
  // ───────────────────────── истории ─────────────────────────

  /// Истории за сутки: автор (ключ) → по порядку.
  final Map<String, List<Story>> stories = {};

  /// Кому уходят мои истории: друзья (не группы, не заявки, не заблокированные).
  List<Contact> get storyAudience => [
    for (final c in contacts)
      if (!c.isGroup && !c.blocked && !c.request && !c.isNotes) c,
  ];

  List<Story> storiesOf(String author) => [
    for (final st in stories[author] ?? const <Story>[])
      if (!st.expired) st,
  ];

  List<Story> get myStories => storiesOf(myKey);

  /// Друзья с историями: сначала с непросмотренными, свежие — первыми.
  List<Contact> get storyContacts {
    final last = <String, DateTime>{};
    for (final c in contacts) {
      if (c.isGroup || c.blocked || c.request || !c.hasStory || !visible(c)) continue;
      final list = storiesOf(c.id);
      if (list.isNotEmpty) last[c.id] = list.last.time;
    }
    final out = [
      for (final c in contacts)
        if (last.containsKey(c.id)) c,
    ];
    out.sort((a, b) {
      if (a.storyUnseen != b.storyUnseen) return a.storyUnseen ? -1 : 1;
      return last[b.id]!.compareTo(last[a.id]!);
    });
    return out;
  }

  /// Обновить кольца историй у аватаров.
  void refreshStories() {
    _storyFlags();
    notifyChanged();
  }

  void _storyFlags() {
    for (final c in contacts) {
      final list = storiesOf(c.id);
      c.hasStory = list.isNotEmpty;
      c.storyUnseen = list.any((st) => !st.seen);
    }
  }

  /// Опубликовать историю (null — не получилось: нет связи).
  Future<Story?> postStory({
    required String kind,
    String text = '',
    int bg = 0,
    String? path,
    Attachment? meta,
    ValueNotifier<double>? progress,
  }) async {
    if (live != null) {
      return live!.publishStory(
        kind: kind,
        text: text,
        bg: bg,
        path: path,
        meta: meta,
        progress: progress,
      );
    }
    final st = Story(
      id: newMessageId(),
      author: myKey,
      kind: kind,
      time: DateTime.now(),
      text: text,
      bg: bg,
      att: meta?..path = path,
    );
    stories.putIfAbsent(myKey, () => []).add(st);
    refreshStories();
    return st;
  }

  Future<void> viewStory(Story st) async {
    if (st.author == myKey || st.seen) return;
    if (live != null) {
      await live!.storyViewed(st);
    } else {
      st.seen = true;
      refreshStories();
    }
  }

  Future<void> deleteStory(Story st) async {
    if (live != null) {
      await live!.deleteStory(st);
    } else {
      stories[st.author]?.remove(st);
      refreshStories();
    }
  }

  /// Файл фото / видео истории (скачать, если ещё нет).
  Future<String?> storyFile(Story st) async {
    if (live != null) return live!.storyFile(st);
    return st.att?.path;
  }

  // ───────────────────────── дни рождения ─────────────────────────

  /// Свой день рождения («ММ-ДД» или null) — друзья узнают из профиля.
  void setBirthday(String? v) {
    final p = profile;
    if (p == null) return;
    p.birthday = cleanBirthday(v);
    live?.saveProfile();
    notifyChanged();
  }

  static String _md(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// 0 — сегодня день рождения, 1 — завтра, null — нет. 29 февраля в
  /// невисокосный год отмечаем 28-го.
  static int? birthdayIn(String? bd, [DateTime? now]) {
    if (bd == null) return null;
    final today = now ?? DateTime.now();
    String norm(DateTime d) {
      final md = _md(d);
      final leap = DateTime(d.year, 2, 29).month == 2;
      return !leap && md == '02-28' && bd == '02-29' ? '02-29' : md;
    }

    if (norm(today) == bd) return 0;
    if (norm(today.add(const Duration(days: 1))) == bd) return 1;
    return null;
  }

  int? birthdayOf(Contact c) => c.isGroup || c.blocked ? null : birthdayIn(c.birthday);

  /// Кому уже напомнили (ключ → «год-ММ-ДД») — один раз в день.
  final Map<String, String> _birthdayNoted = {};

  /// Напомнить о днях рождения друзей: накануне и в сам день. Вызывается при
  /// запуске, возвращении в приложение и при фоновой проверке — без своих задач.
  Future<void> checkBirthdays() async {
    if (profile == null) return;
    final today = DateTime.now();
    final stamp = '${today.year}-${_md(today)}';
    var changed = false;
    for (final c in contacts) {
      final when = birthdayOf(c);
      if (when == null || c.request || !visible(c) || muted.contains(c.id)) continue;
      final key = '${c.id}:$when';
      if (_birthdayNoted[key] == stamp) continue;
      _birthdayNoted[key] = stamp;
      changed = true;
      final m = Message(
        id: 'bd-${c.id}',
        mine: false,
        text: when == 0
            ? 'Сегодня день рождения 🎂 — поздравь!'
            : 'Завтра день рождения 🎂 — не забудь поздравить',
        time: today,
      );
      await live?.notify?.message(c, m);
    }
    if (changed) {
      // Дождаться записи: в фоновой проверке база закрывается сразу после.
      await live?.saveSettings(_settings);
      notifyChanged();
    }
  }

  // ───────────────────────── оформление чата ─────────────────────────

  /// Фон и цвет чата (только у себя).
  void setChatLook(
    Contact c, {
    String? wallpaper,
    int? dim,
    int? accent,
    bool resetAccent = false,
  }) {
    if (wallpaper != null) {
      final old = c.wallpaper;
      c.wallpaper = wallpaper == 'auto' ? null : wallpaper;
      // Прежнее своё фото больше не нужно (в демо это файл из галереи — не трогаем).
      if (live != null && old != null && old.startsWith('f:') && old != c.wallpaper) {
        File(old.substring(2)).delete().ignore();
      }
    }
    if (dim != null) c.wallpaperDim = dim.clamp(0, 80);
    if (accent != null || resetAccent) c.chatAccent = resetAccent ? null : accent;
    live?.saveContact(c);
    notifyChanged();
  }

  /// Своё фото фоном чата: копия в папке приложения (оригинал могут удалить).
  /// Имя файла каждый раз новое — чтобы не показалась старая картинка из кеша.
  Future<void> setChatWallpaperPhoto(Contact c, String src) async {
    var path = src;
    final l = live;
    if (l != null) {
      final id = c.id.length > 16 ? c.id.substring(0, 16) : c.id;
      path = await l.media.pathFor(
        'wallpapers',
        '${id}_${DateTime.now().millisecondsSinceEpoch}',
        'jpg',
      );
      await File(src).copy(path);
    }
    setChatLook(c, wallpaper: 'f:$path');
  }

  Future<void> onIncoming(Contact c, Message m, {bool silent = false}) async {
    final onScreen = foreground && openChat == c.id && !locked;
    if (onScreen) {
      await live?.markRead(c.id, sendReceipt: readReceipts);
      return;
    }
    unread[c.id] = (unread[c.id] ?? 0) + 1;
    if (muted.contains(c.id) || silent) return;
    // Скрытый чат: никаких всплывашек; системное уведомление — без имени и текста.
    if (!visible(c)) {
      if (!foreground || locked) await live?.notify?.message(c, m);
      return;
    }
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
    myStickers.clear();
    myGifs.clear();
    stories.clear();
    _birthdayNoted.clear();
    drafts.clear();
    draftAt.clear();
    _draftTimer?.cancel();
    muted.clear();
    pinned.clear();
    unread.clear();
    contacts.clear();
    _messages.clear();
    profile = null;
    hasPin = false;
    _demoPin = null;
    locked = false;
    vaultSet = false;
    vaultOpen = false;
    duressSet = false;
    duressWipe = false;
    decoy = false;
    covered = false;
    coverNotes.clear();
    _demoSecrets.clear();
    if (disguise > 0) {
      disguise = 0;
      if (!demo) _disguiseChannel.invokeMethod('set', 0).catchError((_) => null);
    }
    final l = live;
    if (l != null) {
      final n = l.notify;
      final restart = l.restart;
      await l.wipe();
      live = null;
      // Начинаем с чистого листа: новая пустая база.
      await (restart?.call() ?? Live.boot(this));
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
    stories
      ..clear()
      ..addAll(demoStories());
    _storyFlags();
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
    // В канал подписчики не отвечают.
    if (c.isChannel) return;

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
    _draftTimer?.cancel();
    themeTick.dispose();
    openRequest.dispose();
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

/// Свой цвет чата: внутри экрана переписки акцент — его (у себя).
class ChatAccent extends InheritedWidget {
  const ChatAccent({super.key, required this.accent, required super.child});

  final Accent? accent;

  static Accent? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatAccent>()?.accent;

  @override
  bool updateShouldNotify(ChatAccent old) => old.accent != accent;
}

extension AppContext on BuildContext {
  /// Подписывается на изменения состояния.
  AppState get app => AppScope.of(this);

  /// Без подписки — для обработчиков нажатий.
  AppState get appRead => AppScope.read(this);

  VeilColors get vc => app.colors;

  /// Акцент: свой цвет чата (если задан), иначе — общий.
  Accent get accent => ChatAccent.of(this) ?? app.accent;

  /// Цвет текста на своих пузырях с учётом цвета чата.
  Color get mineFg {
    final a = app;
    final own = ChatAccent.of(this);
    return own == null || a.skin.outlineMine ? a.mineFg : own.onAccent;
  }
}
