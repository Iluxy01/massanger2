import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/backup.dart';
import '../core/giftwrap.dart';
import '../core/link.dart';
import '../core/media_tools.dart';
import '../core/nostr.dart';
import '../core/protocol.dart';
import '../core/relay_pool.dart';
import '../core/store.dart';
import '../core/transfer.dart';
import '../models/models.dart';
import 'app_state.dart';
import 'media_engine.dart';

/// Показ системных уведомлений (реализация — в core/notifier.dart).
abstract class Notify {
  Future<void> message(Contact from, Message m);
}

/// «Живой» режим: настоящие ключи, база на телефоне и ретрансляторы.
///
/// Экраны работают только с [AppState]; этот класс подгружает в него данные,
/// сохраняет изменения и обменивается зашифрованными конвертами с друзьями.
class Live {
  Live._(this.app, this.store, this.secrets, this._connector, [String? mediaDir, String? tempDir]) {
    media = MediaEngine(
      this,
      () async => mediaDir ?? p.join((await getApplicationSupportDirectory()).path, 'media'),
      temp: tempDir == null ? null : () async => Directory(tempDir),
    );
  }

  /// Файлы: фото, видео, голосовые, документы.
  late final MediaEngine media;

  /// Запущены фоновой проверкой (без интерфейса): файлы не качаем.
  bool background = false;

  /// Запустить заново с теми же параметрами (после «стереть всё»).
  Future<Live> Function()? restart;

  final AppState app;
  final Store store;
  final SecretBox secrets;
  final Connector? _connector;
  Notify? notify;

  Keys? keys;
  RelayPool? pool;
  List<String> relays = List.of(defaultRelays);

  StreamSubscription<Event>? _events;
  StreamSubscription<void>? _changes;
  Timer? _presence;
  Timer? _expiry;
  Timer? _heartbeat;
  final Map<String, Timer> _typingTimers = {};
  final Map<String, Timer> _onlineTimers = {};
  Future<void> _queue = Future.value();
  Timer? _resend;
  Timer? _resub;
  final Map<String, RelayState> _relayStates = {};
  String _relaySig = '';

  /// Журнал для диагностики (Профиль → Сеть → Журнал). Только в памяти.
  final List<String> journal = [];

  void log(String line) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    journal.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)} $line');
    if (journal.length > 400) journal.removeAt(0);
  }

  static String short(String id) => id.length > 8 ? id.substring(0, 8) : id;

  String who(String pub) => app.contact(pub)?.name ?? short(pub);
  DateTime _lastTyping = DateTime(2000);
  int _lastOnline = 0;
  bool _closed = false;
  bool get closed => _closed;

  /// До какого момента (сек) мы точно забрали всё у ретрансляторов.
  int _syncedAt = 0;
  int _syncedSaved = 0;

  /// Запас на расхождение часов у телефонов.
  static const _clockSkew = 12 * 3600;

  /// Для фоновой проверки: отдельное соединение с базой, ничего не создаём.
  static Future<Live?> bootBackground(AppState app) async {
    final s = DeviceSecrets();
    final store = await Store.open(s, shared: false, createKey: false);
    if (store == null) return null;
    final live = Live._(app, store, s, null)..background = true;
    app.live = live;
    await live._load(network: false);
    return live;
  }

  static Future<Live> boot(
    AppState app, {
    SecretBox? secrets,
    DatabaseFactory? dbFactory,
    String? dbPath,
    Connector? connector,
    bool network = true,
    String? mediaDir,
    String? tempDir,
  }) async {
    final s = secrets ?? DeviceSecrets();
    final store = await Store.open(s, factory: dbFactory, path: dbPath);
    final live = Live._(app, store!, s, connector, mediaDir, tempDir);
    // После «стереть всё» — начать заново с теми же параметрами.
    live.restart = () => boot(
      app,
      secrets: s,
      dbFactory: dbFactory,
      dbPath: dbPath,
      connector: connector,
      network: network,
      mediaDir: mediaDir,
      tempDir: tempDir,
    );
    app.live = live;
    await live._load(network: network);
    return live;
  }

  // ───────────────────────── загрузка ─────────────────────────

  Future<void> _load({required bool network}) async {
    final settings = await store.getJson('settings');
    if (settings != null) app.applySettings(settings);
    final r = await store.get('relays');
    if (r != null) relays = (jsonDecode(r) as List).cast<String>();
    // Сохранён прежний стандартный список (нажимали «Сбросить») — обновляем
    // на новый. Свой, изменённый вручную, список не трогаем.
    if (r != null &&
        relays.length == previousDefaultRelays.length &&
        relays.toSet().containsAll(previousDefaultRelays)) {
      relays = List.of(defaultRelays);
      await store.set('relays', jsonEncode(relays));
    }
    app.hasPin = (await secrets.read('pin') ?? '').isNotEmpty;
    app.locked = app.hasPin;
    app.vaultSet = await hasSecret('vault');
    app.duressSet = await hasSecret('duress');
    app.duressWipe = await secrets.read('duress_mode') == 'wipe';
    // Маскировка: при запуске — сначала «калькулятор» / «заметки».
    app.covered = app.disguise > 0 && await hasSecret('cover');

    final drafts = await store.getJson('drafts');
    if (drafts != null) app.loadDrafts(drafts);

    final synced = int.tryParse(await store.get('synced') ?? '');
    final legacy = int.tryParse(await store.get('since') ?? '');
    // Переход со старой версии (конверты «задним числом» до 2 суток): один раз
    // забираем с запасом, дальше — только новое.
    _syncedAt = synced ?? (legacy != null ? legacy - 2 * 24 * 3600 : nowSec());

    final priv = await secrets.read('priv');
    final prof = await store.getJson('profile');
    if (priv != null && prof != null) {
      keys = Keys(priv);
      app.profile = Profile.fromJson(prof);
      await reload();
      await _requeueUnconfirmed();
      if (network) {
        startNetwork();
        resumeMedia();
        unawaited(app.checkBattery());
      }
    }
    _expiry = Timer.periodic(const Duration(seconds: 30), (_) => _expire());
    // «Приложение живо» (даже свёрнутое) — пока стучит этот пульс, фоновая
    // проверка не запускается и не пишет в базу одновременно с приложением.
    if (network) {
      await store.set('alive', '${nowSec()}');
      // Раз в 40 с (порог фоновой проверки — 75 с): реже пишем в базу.
      _heartbeat = Timer.periodic(const Duration(seconds: 40), (_) {
        store.set('alive', '${nowSec()}');
      });
      final bg = await store.get('bg_last');
      if (bg != null) log('фоновая проверка: $bg');
    }
    app.ready = true;
    app.notifyChanged();
  }

  /// Перечитать контакты и переписку из базы (например, после фоновой синхронизации).
  /// Через общую очередь — чтобы не затереть сообщение, которое как раз обрабатывается.
  Future<void> reload() => _queue = _queue.then((_) => _reload()).catchError((Object e) {
    log('ОШИБКА чтения базы: $e');
  });

  Future<void> _reload() async {
    final open = app.openChat;
    final contacts = [for (final j in await store.contacts()) Contact.fromJson(j)];
    // Сохраняем «живые» поля (в сети / печатает) у уже известных контактов.
    for (final c in contacts) {
      final old = app.contact(c.id);
      if (old != null) {
        c.online = old.online;
        c.lastSeen = old.lastSeen ?? c.lastSeen;
      }
    }
    app.contacts
      ..clear()
      ..addAll(contacts);
    app.unread.clear();
    for (final c in contacts) {
      final byId = <String, Message>{};
      final list = <Message>[];
      for (final j in await store.messages(c.id)) {
        final m = Message.fromJson(j, (id) => byId[id]);
        byId[m.id] = m;
        list.add(m);
      }
      app.setMessages(c.id, list);
      final n = list.where((m) => !m.mine && m.status == MsgStatus.delivered).length;
      if (n > 0 && c.id != open) app.unread[c.id] = n;
    }
    _expire();
    app.notifyChanged();
  }

  // ───────────────────────── личность ─────────────────────────

  /// Новый аккаунт — или вход по ключу восстановления [priv]: тогда заодно
  /// забираем с ретрансляторов то, что там ещё лежит за последний месяц
  /// (написавшие друзья появятся заявками — переписку хранит только копия).
  Future<void> createIdentity(Profile Function(String pub) build, {String? priv}) async {
    if (keys != null) throw StateError('профиль уже есть');
    final k = priv != null ? Keys(priv) : Keys.generate();
    await secrets.write('priv', k.priv);
    keys = k;
    final p = build(k.pub);
    app.profile = p;
    await store.setJson('profile', p.toJson());
    // Только что созданному ключу нечего забирать из прошлого.
    _syncedAt = priv != null ? nowSec() - 30 * 24 * 3600 : nowSec();
    await store.set('synced', '$_syncedAt');
    startNetwork();
  }

  /// Секретный ключ аккаунта (для ключа восстановления).
  Future<String?> secretKey() => secrets.read('priv');

  // ───────────────────────── резервная копия ─────────────────────────

  /// Сохранить зашифрованную копию в [out]. [withMedia] — вместе с фото и файлами.
  Future<void> exportBackup(String out, String password, {bool withMedia = true}) async {
    final (manifest, files) = await _collect(withMedia: withMedia);
    await Backup.write(out, password, manifest, files);
    log('сохранена резервная копия (файлов: ${files.length})');
  }

  /// Всё для восстановления (ключ, профиль, друзья, переписка, настройки) и
  /// файлы вложений (относительный путь → файл), если [withMedia].
  Future<(Map<String, dynamic>, Map<String, String>)> _collect({required bool withMedia}) async {
    final priv = await secrets.read('priv');
    final profile = await store.getJson('profile');
    if (priv == null || profile == null) throw StateError('нет профиля');
    final root = await media.root();
    final files = <String, String>{};
    final chats = <String, List<Map<String, dynamic>>>{};
    for (final c in await store.contacts()) {
      final id = c['id'] as String;
      final list = await store.messages(id, limit: 1 << 30);
      for (final j in list) {
        final att = j['att'];
        if (att is Map && att['p'] is String) {
          final abs = att['p'] as String;
          // В копии путь — относительный: на новом телефоне папка другая.
          if (withMedia && p.isWithin(root, abs) && File(abs).existsSync()) {
            final rel = p.relative(abs, from: root);
            files[rel] = abs;
            att['p'] = 'rel:$rel';
          } else {
            att.remove('p');
          }
        }
      }
      chats[id] = list;
    }
    return (
      <String, dynamic>{
        'v': 1,
        'created': nowSec(),
        'priv': priv,
        'profile': profile,
        'settings': await store.getJson('settings'),
        'relays': await store.get('relays'),
        'contacts': await store.contacts(),
        'messages': chats,
      },
      files,
    );
  }

  /// Восстановить из копии на «чистом» телефоне (до создания профиля).
  Future<void> restoreBackup(String path, String password) async {
    if (keys != null) throw StateError('профиль уже есть');
    final root = await media.root();
    final content = await Backup.read(path, password, root);
    await _restore(content.manifest, root);
    log(
      'восстановлено из копии: контактов ${(content.manifest['contacts'] as List?)?.length ?? 0}, '
      'файлов ${content.files.length}',
    );
  }

  /// Записать всё из копии (или пакета переноса) и выйти в сеть.
  Future<void> _restore(Map<String, dynamic> m, String root) async {
    final priv = m['priv'];
    final profile = m['profile'];
    if (priv is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(priv) || profile is! Map) {
      throw BackupError('Файл копии повреждён');
    }
    await secrets.write('priv', priv);
    await store.setJson('profile', Map<String, dynamic>.from(profile));
    if (m['settings'] is Map) {
      final st = Map<String, dynamic>.from(m['settings'] as Map);
      await store.setJson('settings', st);
      app.applySettings(st);
    }
    if (m['relays'] is String) {
      await store.set('relays', m['relays'] as String);
      relays = (jsonDecode(m['relays'] as String) as List).cast<String>();
    }
    for (final c in (m['contacts'] as List? ?? const [])) {
      final j = Map<String, dynamic>.from(c as Map);
      await store.saveContact(j['id'] as String, j);
    }
    final chats = m['messages'] is Map ? m['messages'] as Map : const {};
    for (final e in chats.entries) {
      for (final raw in e.value as List) {
        final j = Map<String, dynamic>.from(raw as Map);
        final att = j['att'];
        if (att is Map && att['p'] is String && (att['p'] as String).startsWith('rel:')) {
          att['p'] = p.join(root, (att['p'] as String).substring(4));
        }
        await store.saveMessage(e.key as String, j['id'] as String, (j['ts'] as num).toInt(), j);
      }
    }
    // Забрать с ретрансляторов то, что пришло после сохранения копии.
    final created = (m['created'] as num?)?.toInt() ?? nowSec();
    _syncedAt = created - 3600;
    await store.set('synced', '$_syncedAt');
    keys = Keys(priv);
    app.profile = Profile.fromJson(Map<String, dynamic>.from(profile));
    await reload();
    await _requeueUnconfirmed();
    startNetwork();
    resumeMedia();
  }

  // ───────────────────────── перенос на новый телефон ─────────────────────────

  /// Старый телефон: всё, кроме фото и файлов, — одним зашифрованным пакетом
  /// на ретрансляторы. Возвращает код для QR.
  Future<TransferTicket> prepareTransfer({ValueNotifier<double>? progress}) async {
    if (pool == null) throw TransferError('Нет связи с ретрансляторами');
    final (manifest, _) = await _collect(withMedia: false);
    // В отдельном потоке: длинная переписка — это мегабайты текста.
    final packed = await Isolate.run(() => gzip.encode(utf8.encode(jsonEncode(manifest))));
    if (packed.length > MediaEngine.maxBytes) {
      throw TransferError(
        'Переписки слишком много для переноса по коду — сохрани резервную копию в файл',
      );
    }
    final tmp = File(p.join((await media.tempDir()).path, 'veil-move-${nowSec()}'));
    await tmp.writeAsBytes(packed, flush: true);
    try {
      final att = await media.pushFile(tmp.path, progress: progress);
      if (att == null) {
        throw TransferError(
          'Ретрансляторы не приняли данные — проверь интернет и попробуй ещё раз',
        );
      }
      _moving = att;
      log('перенос: пакет ${(packed.length / 1024).round()} КБ, кусков ${att.chunks}');
      return TransferTicket.of(att);
    } finally {
      if (tmp.existsSync()) await tmp.delete();
    }
  }

  Attachment? _moving;

  /// Перенос закончили (или передумали) — попросить ретрансляторы убрать пакет.
  Future<void> finishTransfer() async {
    final att = _moving;
    _moving = null;
    if (att != null) await media.unpublish(att);
  }

  /// Новый телефон: забрать пакет по коду и восстановить всё.
  Future<void> receiveTransfer(TransferTicket t, {ValueNotifier<double>? progress}) async {
    if (keys != null) throw StateError('профиль уже есть');
    final urls = {...t.relays, ...relays}.toList();
    final pl = RelayPool(urls, connector: _connector)..start();
    final dst = File(p.join((await media.tempDir()).path, 'veil-move-in-${nowSec()}'));
    try {
      if (!await media.pullFile(pl, t.attachment, dst.path, progress: progress)) {
        throw TransferError(
          'Не получилось забрать данные. Проверь интернет на обоих телефонах и что '
          'на старом открыт экран с кодом — и попробуй ещё раз',
        );
      }
      final Map<String, dynamic> m;
      try {
        final bytes = await dst.readAsBytes();
        m = await Isolate.run(
          () => Map<String, dynamic>.from(jsonDecode(utf8.decode(gzip.decode(bytes))) as Map),
        );
      } catch (_) {
        throw TransferError('Данные повреждены — попробуй ещё раз');
      }
      await _restore(m, await media.root());
      log('перенесено со старого телефона: контактов ${(m['contacts'] as List?)?.length ?? 0}');
    } finally {
      await pl.close();
      if (dst.existsSync()) await dst.delete();
    }
  }

  VeilCard get myCard {
    final p = app.profile!;
    return VeilCard(name: p.name, emoji: p.emoji, color: p.colorIndex, bio: p.bio);
  }

  String get inviteLink => Invite(keys!.pub, myCard).encode();

  Future<void> saveProfile({bool broadcast = true}) async {
    await store.setJson('profile', app.profile!.toJson());
    if (!broadcast) return;
    for (final c in app.contacts) {
      if (!c.blocked && !c.isGroup) {
        _control(c.id, Payload(Payload.profile, {'p': myCard.toJson()}));
      }
    }
  }

  // ───────────────────────── сеть ─────────────────────────

  void startNetwork() {
    if (pool != null || keys == null || _closed) return;
    final p = pool = RelayPool(activeRelays, connector: _connector);
    p.onSynced = _synced;
    _events = p.events.listen((e) {
      // Свёрнуто, телефон спит: пришедшее разбудило его на миг — пусть не
      // засыпает, пока расшифруем, сохраним и покажем уведомление.
      if (_paused && !background) Link.hold(const Duration(seconds: 8));
      _queue = _queue.then((_) => _safely(e));
    });
    _changes = p.changes.listen((_) {
      // Перерисовываем экран, только если что-то видимое поменялось (состояние
      // или ошибка ретранслятора), а не на каждое служебное событие сети.
      final sig = StringBuffer();
      for (final url in p.urls) {
        sig
          ..write(p.stateOf(url).index)
          ..write(p.errorOf(url) ?? '')
          ..write('|');
      }
      for (final url in p.urls) {
        final st = p.stateOf(url);
        if (_relayStates[url] != st && st != RelayState.connecting) {
          final err = p.errorOf(url);
          log(
            '${url.replaceFirst('wss://', '')}: ${st == RelayState.online ? 'на связи' : 'нет связи${err != null ? ' ($err)' : ''}'}',
          );
        }
        _relayStates[url] = st;
      }
      final n = p.onlineCount;
      // Связь оборвалась, пока телефон спит: таймеры переподключения во сне
      // не срабатывают — просим Android подождать, пока подключимся снова.
      if (n < _lastOnline && _paused && !background) Link.hold(const Duration(seconds: 20));
      if (n > _lastOnline) {
        _flushOutbox();
        if (_lastOnline == 0) resumeMedia();
      }
      _lastOnline = n;
      final now = sig.toString();
      if (now != _relaySig) {
        _relaySig = now;
        app.notifyChanged();
      }
    });
    p.subscribe(_filters);
    p.start();
    _presence = Timer.periodic(const Duration(seconds: 60), (_) => _ping());
    // Переотправка неподтверждённых сообщений (по расписанию с паузами).
    var ticks = 0;
    _resend = Timer.periodic(const Duration(seconds: 30), (_) {
      final t = ticks++;
      // Заряд — раз в 5 минут (автоматический «Ультра»).
      if (t % 10 == 0 && app.foreground) app.checkBattery();
      // «Ультра»: раз в полторы минуты вместо 30 с.
      if (app.ultra && t % 3 != 0) return;
      _flushOutbox();
      // Недокачанные файлы — повторяем сами, с растущей паузой.
      if (app.foreground) resumeMedia();
    });
    // Подстраховка: изредка заново спросить новое (дёшево — окно маленькое).
    _resub = Timer.periodic(const Duration(minutes: 10), (_) {
      if (app.foreground && !app.ultra) p.subscribe(_filters);
    });
    store.pruneOutbox().catchError((_) {});
    Future<void>.delayed(const Duration(seconds: 3), _ping);
  }

  /// Фильтры подписки. Вызываются при каждом запросе (и после переподключения),
  /// поэтому «с какого момента» всегда свежее — без повторной выкачки старого.
  List<Map<String, dynamic>> _filters() {
    final me = keys?.pub;
    if (me == null) return const [];
    return [
      {
        'kinds': [GiftWrap.kindWrap],
        '#p': [me],
        'since': _syncedAt - _clockSkew,
      },
      {
        'kinds': [GiftWrap.kindWrapEphemeral],
        '#p': [me],
        'since': nowSec() - 60,
      },
    ];
  }

  /// Ретранслятор отдал всё, что было на момент запроса [reqAt].
  void _synced(String url, int reqAt) {
    if (reqAt <= _syncedAt) return;
    _syncedAt = reqAt;
    if (reqAt - _syncedSaved > 60) {
      _syncedSaved = reqAt;
      store.set('synced', '$reqAt').catchError((_) {});
    }
  }

  Future<void> setRelays(List<String> urls) async {
    relays = urls;
    await store.set('relays', jsonEncode(urls));
    pool?.setUrls(activeRelays);
    app.notifyChanged();
  }

  /// С какими ретрансляторами держать связь: в «Ультра» — только с первыми.
  List<String> get activeRelays =>
      app.ultra ? relays.take(AppState.ultraRelays).toList() : List.of(relays);

  /// Режим «Ультра» включили или выключили — меньше соединений и проверок.
  void applyPower() {
    pool?.setUrls(activeRelays);
    tuneProbe();
    log(app.ultra ? 'режим «Ультра»: ${activeRelays.length} ретранслятора' : 'обычный режим');
  }

  bool _paused = false;

  /// Как часто проверять молчащие соединения: в фоне и в «Ультра» — реже.
  void tuneProbe() {
    pool?.healthEvery = Duration(seconds: _paused ? 15 : 5);
    pool?.idleProbe = switch ((_paused, app.ultra)) {
      (true, true) => const Duration(minutes: 8),
      (true, false) => const Duration(minutes: 4),
      (false, true) => const Duration(minutes: 3),
      (false, false) => const Duration(seconds: 45),
    };
  }

  /// Приложение вернулось на экран.
  Future<void> resumed() async {
    await store.set('alive', '${nowSec()}');
    await reload();
    // Проверить соединения (мобильная сеть могла их тихо оборвать) и
    // заново спросить накопившееся.
    _paused = false;
    tuneProbe();
    pool?.wake();
    pool?.subscribe(_filters);
    unawaited(_flushOutbox());
    resumeMedia();
    _ping();
    // Чат был открыт, пока приложение было свёрнуто — теперь его видно.
    final open = app.openChat;
    if (open != null && !app.locked) {
      await markRead(open, sendReceipt: app.readReceipts);
      app.notifyChanged();
    }
  }

  /// Приложение свернули — сразу сообщаем друзьям «не в сети».
  void paused() {
    // В фоне (с «мгновенными уведомлениями») проверяем соединения реже — батарея.
    _paused = true;
    tuneProbe();
    _ping(online: false);
  }

  /// Будильник службы «на связи» или смена сети: проверить соединения,
  /// переподключиться, забрать и отправить накопившееся — и отпустить
  /// процессор спать.
  Future<void> keepAlive() async {
    final p = pool;
    try {
      if (p == null || _closed) return;
      Link.hold(const Duration(seconds: 20));
      await p.verify(timeout: const Duration(seconds: 12));
      await _flushOutbox();
      // Ответы на только что отправленный запрос и пришедшие сообщения.
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await _queue;
    } catch (e) {
      log('проверка связи: $e');
    } finally {
      Link.release();
    }
  }

  /// Фоновая проверка: подключиться, забрать накопившееся, выйти.
  Future<int> syncOnce({Duration timeout = const Duration(seconds: 25)}) async {
    if (keys == null) return 0;
    final before = app.totalMessages;
    startNetwork();
    await Future<void>.delayed(const Duration(seconds: 2));
    await pool!.waitEose(timeout);
    await Future<void>.delayed(const Duration(seconds: 1));
    await _queue;
    await _flushOutbox();
    // Дать отчётам о доставке уйти.
    await Future<void>.delayed(const Duration(seconds: 3));
    await _queue;
    return app.totalMessages - before;
  }

  Future<void> _safely(Event e) async {
    if (_closed) return;
    try {
      await _onEvent(e);
    } catch (err) {
      // Не помечен как обработанный — придёт ещё раз при следующем запросе.
      if (!_closed) log('ОШИБКА обработки ${short(e.id)}: $err');
    }
  }

  Future<void> _onEvent(Event e) async {
    final k = keys;
    if (k == null || _closed) return;
    final ephemeral = e.kind == GiftWrap.kindWrapEphemeral;
    if (!ephemeral && await store.isSeen(e.id)) return;
    final opened = await GiftWrap.unwrapAsync(k, e);
    if (opened == null) {
      if (!ephemeral) {
        log('конверт ${short(e.id)} не открылся (не нам или повреждён)');
        await store.markSeen(e.id);
      }
      return;
    }
    final (sender, rumor) = opened;
    final p = Payload.decode(rumor.content);
    if (sender == k.pub || p == null) {
      if (!ephemeral) await store.markSeen(e.id);
      return;
    }
    if (!ephemeral && p.type != Payload.receipt) {
      log('← ${p.type} от ${who(sender)} (${short(e.id)})');
    }
    final sentAt = DateTime.fromMillisecondsSinceEpoch(rumor.createdAt * 1000);
    await _handle(sender, p, sentAt.isAfter(DateTime.now()) ? DateTime.now() : sentAt);
    // Только после успешной обработки: при ошибке конверт придёт снова.
    if (!ephemeral) await store.markSeen(e.id);
    app.notifyChanged();
  }

  Future<void> _handle(String sender, Payload p, DateTime sentAt) async {
    final gid = p.str('g');
    if (gid != null) return _handleGroup(sender, gid, p, sentAt);
    var c = app.contact(sender);
    if (c != null && c.blocked) return;
    final card = VeilCard.fromJson(p.data['p']);

    if (c == null) {
      // Незнакомец может только поздороваться или написать — тогда он станет «заявкой».
      if (p.type != Payload.msg && p.type != Payload.hello) return;
      c = Contact(
        id: sender,
        name: card?.name ?? 'Новый контакт',
        emoji: card?.emoji ?? '🙂',
        colorIndex: card?.color ?? 0,
        bio: card?.bio ?? '',
        request: true,
      );
      app.contacts.add(c);
      await saveContact(c);
    } else if (card != null && (p.type == Payload.hello || p.type == Payload.profile)) {
      c
        ..name = card.name
        ..emoji = card.emoji
        ..colorIndex = card.color
        ..bio = card.bio;
      await saveContact(c);
    }
    // «В сети» — только по живым сигналам, а не по отчётам из фоновой проверки
    // или старым сообщениям, пролежавшим на ретрансляторе.
    final fresh = DateTime.now().difference(sentAt).inSeconds.abs() < 120;
    // Где друг сейчас на связи — туда и кладём ему файлы.
    if (p.data['r'] is List && (fresh || p.type == Payload.ping)) {
      final r = Contact.cleanRelays(p.data['r']);
      if (r.isNotEmpty && r.join() != c.reach.join()) {
        c.reach = r;
        await saveContact(c);
      }
    }
    if (p.type == Payload.ping) {
      p.data['on'] == false ? _seenOffline(c) : _seenOnline(c);
    } else if (fresh && (p.type == Payload.typing || p.type == Payload.msg)) {
      _seenOnline(c);
    }
    await _apply(sender, sender, c, p, sentAt);
  }

  static String _clip(Object? v, String fallback, [int max = 40]) {
    if (v is! String || v.trim().isEmpty) return fallback;
    final t = v.trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  /// Сведения о группе для сообщения: название, значок, состав.
  Map<String, dynamic> _groupWire(Contact g) {
    final info = g.group!;
    final j = info.toJson()
      ..remove('left')
      ..remove('ic');
    // Канал: подписчики не видят друг друга — в сведениях только автор.
    if (info.channel) {
      j['m'] = [
        for (final m in info.members)
          if (m.pub == info.admin) m.toJson(),
      ];
    }
    return {'n': g.name, 'e': g.emoji, 'c': g.colorIndex, ...j};
  }

  /// Вступающие в каналы по ссылке: id канала → когда попросились.
  final Map<String, DateTime> _joining = {};

  /// Попросить автора канала добавить нас (по пригласительной ссылке).
  void joinChannel(ChannelInvite inv) {
    _joining[inv.id] = DateTime.now();
    _control(inv.admin, Payload(Payload.join, {'g': inv.id, 'i': inv.code, 'p': myCard.toJson()}));
    log('прошу вступить в канал «${inv.name}»');
  }

  /// Сообщение или служебный сигнал внутри группы.
  Future<void> _handleGroup(String sender, String gid, Payload p, DateTime sentAt) async {
    final me = keys!.pub;
    if (!Contact.isGroupId(gid) || gid.length > 40) return;
    final sc = app.contact(sender);
    if (sc != null && sc.blocked) return;
    var g = app.contact(gid);
    final wire = p.data['gi'] is Map ? p.data['gi'] as Map : null;
    final info = GroupInfo.fromJson(wire);
    if (g == null) {
      // О группе узнаём из её сообщения — если в составе и мы, и отправитель.
      // О канале — из сообщения его автора (подписчиков в сведениях нет).
      if (p.type != Payload.msg || info == null || !info.has(sender)) return;
      if (info.channel ? info.admin != sender : !info.has(me)) return;
      // Сами просились в канал по ссылке — спрашивать «принять?» не нужно.
      final asked = _joining.remove(gid) != null;
      g = Contact(
        id: gid,
        name: _clip(wire!['n'], info.channel ? 'Канал' : 'Группа'),
        emoji: _clip(wire['e'], info.channel ? '📢' : '👥', 16),
        colorIndex: wire['c'] is num ? (wire['c'] as num).toInt() : 0,
        // Позвал не друг — сначала спросим, хочешь ли в эту группу.
        request: !asked && (sc == null || sc.request),
      )..group = info;
      app.contacts.add(g);
      await saveContact(g);
      log('${info.channel ? 'новый канал' : 'новая группа'} «${g.name}» от ${who(sender)}');
    } else if (g.group == null) {
      return;
    } else if (info != null &&
        sender == g.group!.admin &&
        info.ver > g.group!.ver &&
        info.channel == g.group!.channel) {
      // Администратор изменил группу: состав, название, значок.
      final was = g.group!.left;
      g
        ..name = _clip(wire!['n'], g.name)
        ..emoji = _clip(wire['e'], g.emoji, 16)
        ..colorIndex = wire['c'] is num ? (wire['c'] as num).toInt() : g.colorIndex
        // В канале подписчиков в сведениях нет: «отписан ли я» — по событиям.
        ..group = (info..left = info.channel ? was : !info.has(me));
      if (was != info.left) {
        log('группа «${g.name}»: ${info.left ? 'меня удалили' : 'я снова в ней'}');
      }
      await saveContact(g);
    }
    final group = g.group!;
    // Просьба вступить в мой канал по ссылке.
    if (p.type == Payload.join) return _joinRequest(g, sender, p);
    final member = group.member(sender);
    if (member == null) return; // не участник (или уже вышел)
    // В канале пишет только автор. От подписчиков принимаем лишь служебное:
    // отчёты, голоса, «не могу скачать» и «я отписался».
    if (group.channel && sender != group.admin) {
      final ok = switch (p.type) {
        Payload.receipt || Payload.vote || Payload.need => true,
        Payload.msg => p.str('ev') == 'leave',
        _ => false,
      };
      if (!ok) return;
    }
    // Свежая визитка отправителя — имя в группе обновится.
    final card = VeilCard.fromJson(p.data['p']);
    if (card != null &&
        (card.name != member.name || card.emoji != member.emoji || card.color != member.color)) {
      member
        ..name = card.name
        ..emoji = card.emoji
        ..color = card.color;
      await saveContact(g);
    }
    final fresh = DateTime.now().difference(sentAt).inSeconds.abs() < 120;
    if (sc != null && fresh && (p.type == Payload.typing || p.type == Payload.msg)) {
      _seenOnline(sc);
    }
    if (group.left && p.type != Payload.msg) return;
    await _apply(gid, sender, g, p, sentAt);
  }

  /// Просьба вступить в мой канал по пригласительной ссылке. Код верный —
  /// добавляю в подписчики и присылаю ему канал (он появится у него сразу).
  Future<void> _joinRequest(Contact g, String sender, Payload p) async {
    final info = g.group!;
    if (!info.channel || info.admin != keys?.pub || info.left) return;
    final code = info.code;
    if (code == null || p.str('i') != code) {
      log('просьба вступить в «${g.name}» по старой ссылке — отклонена');
      return;
    }
    if (!info.has(sender)) {
      if (info.subscribers >= GroupInfo.maxSubscribers) {
        log('канал «${g.name}» полон — ${short(sender)} не добавлен');
        return;
      }
      final card = VeilCard.fromJson(p.data['p']);
      info.members.add(
        GroupMember(
          pub: sender,
          name: card?.name ?? 'Подписчик',
          emoji: card?.emoji ?? '🙂',
          color: card?.color ?? 0,
        ),
      );
      info.ver = DateTime.now().millisecondsSinceEpoch;
      await saveContact(g);
      log('новый подписчик «${g.name}»: ${card?.name ?? short(sender)}');
    }
    await app.welcomeToChannel(g, [sender]);
  }

  /// Участник вышел из группы (по своему сообщению).
  Future<void> _memberLeft(Contact g, String pub) async {
    final group = g.group!;
    group.members.removeWhere((m) => m.pub == pub);
    if (group.admin == pub && group.members.isNotEmpty) group.admin = group.members.first.pub;
    // Администратор фиксирует новый состав — следующее сообщение разнесёт его всем.
    if (group.admin == keys?.pub) group.ver = DateTime.now().millisecondsSinceEpoch;
    await saveContact(g);
  }

  /// Ответ отправителю (отчёт, «положил туда»): в группе — с пометкой группы.
  void _reply(String to, String chat, Payload p) {
    if (Contact.isGroupId(chat)) p.data['g'] = chat;
    _control(to, p);
  }

  /// Общая обработка: [chat] — куда (собеседник или группа), [sender] — кто прислал.
  Future<void> _apply(String chat, String sender, Contact c, Payload p, DateTime sentAt) async {
    final group = c.isGroup;
    switch (p.type) {
      case Payload.msg:
        final id = p.str('id'), text = p.str('text') ?? '';
        if (id == null || id.length > 64) return;
        final kind = Message.kindOf(p.data['k']);
        final att = Attachment.fromJson(p.data['att'])?..path = null;
        final geo = GeoPoint.fromJson(p.data['geo']);
        final poll = Poll.fromJson(p.data['poll'])?..votes.clear();
        final todo = Todo.fromJson(p.data['todo']);
        final oa = p.integer('oa');
        // Стикер из набора — короткий код; свой — небольшая картинка.
        final stk = p.str('stk');
        final sticker = stk != null && stk.length <= 24 ? stk : null;
        final valid = switch (kind) {
          MsgKind.text => true,
          MsgKind.voice ||
          MsgKind.photo ||
          MsgKind.video ||
          MsgKind.note ||
          MsgKind.file => att != null && att.uploaded && att.size <= MediaEngine.maxBytes,
          MsgKind.geo => geo != null,
          MsgKind.poll => poll != null,
          MsgKind.event => group,
          MsgKind.todo => todo != null && todo.items.isNotEmpty,
          MsgKind.sticker =>
            sticker != null ||
                (att != null && att.uploaded && att.size <= MediaEngine.maxStickerBytes),
        };
        if (!valid) {
          log('  непонятное сообщение ${short(id)} (${p.data['k']}) — пропущено');
          return;
        }
        final list = app.messagesOf(chat);
        if (list.any((m) => m.id == id)) {
          // Повтор (отправитель не получил наш отчёт) — подтверждаем ещё раз.
          _reply(
            sender,
            chat,
            Payload(Payload.receipt, {
              'ids': [id],
              's': 'd',
            }),
          );
          return;
        }
        // Вышли из группы — её переписку больше не принимаем (кроме событий о составе).
        if (group && c.group!.left && kind != MsgKind.event) return;
        final ev = kind == MsgKind.event ? _clip(p.data['ev'], 'info', 12) : null;
        if (group && ev == 'leave') await _memberLeft(c, sender);
        if (c.isChannel) {
          final info = c.group!;
          // Подписчик отписался — автору в ленту канала это не пишем.
          if (ev == 'leave' && sender != info.admin) {
            _reply(
              sender,
              chat,
              Payload(Payload.receipt, {
                'ids': [id],
                's': 'd',
              }),
            );
            return;
          }
          // Автор подписал / отписал меня, закрыл канал.
          if (sender == info.admin && (ev == 'add' || ev == 'remove' || ev == 'close')) {
            final was = info.left;
            info.left = ev != 'add';
            if (was != info.left) await saveContact(c);
          }
        }
        final replyId = p.str('reply');
        Message? reply;
        if (replyId != null) {
          for (final m in list) {
            if (m.id == replyId) reply = m;
          }
        }
        // Точное время из сообщения, если оно правдоподобно (rumor — с точностью до секунды).
        final ts = p.integer('ts');
        final exact = ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
        final time =
            exact != null &&
                exact.difference(sentAt).inSeconds.abs() < 5 &&
                !exact.isAfter(DateTime.now())
            ? exact
            : sentAt;
        final fwd = p.str('fw');
        final m = Message(
          id: id,
          mine: false,
          text: text.length > 20000 ? text.substring(0, 20000) : text,
          time: time,
          status: kind == MsgKind.event ? MsgStatus.read : MsgStatus.delivered,
          replyTo: reply,
          secret: kind == MsgKind.text && p.flag('secret'),
          kind: kind,
          att: att,
          geo: geo,
          poll: poll,
          from: group ? sender : null,
          fwd: fwd == null ? null : _clip(fwd, 'Кто-то', 60),
          ev: ev,
          once: p.flag('once') && att != null,
          todo: todo,
          sticker: kind == MsgKind.sticker ? sticker : null,
          // Капсула времени — не дальше, чем на 10 лет вперёд.
          openAt: oa == null || oa > DateTime.now().millisecondsSinceEpoch + 315360000000
              ? null
              : DateTime.fromMillisecondsSinceEpoch(oa),
        );
        var at = list.length;
        while (at > 0 && list[at - 1].time.isAfter(m.time)) {
          at--;
        }
        list.insert(at, m);
        app.typing.remove(chat);
        await saveMessage(chat, m);
        _reply(
          sender,
          chat,
          Payload(Payload.receipt, {
            'ids': [id],
            's': 'd',
          }),
        );
        // События группы — тихо, без уведомления.
        if (kind != MsgKind.event) await app.onIncoming(c, m, silent: p.flag('sl'));
        if (!background && !c.request && app.autoDownload(m)) {
          unawaited(_autoDownload(chat, m));
        } else if (app.ultra && !c.request && (m.kind == MsgKind.video || m.kind == MsgKind.note)) {
          app.savedDownloads++;
        }
      case Payload.vote:
        final id = p.str('id');
        final raw = p.data['o'];
        if (id == null || raw is! List) return;
        for (final m in [...app.messagesOf(chat)]) {
          final poll = m.poll;
          if (m.id == id && poll != null) {
            poll.votes[sender] = Poll.cleanVote(raw, poll.options.length);
            if (!poll.multi && poll.votes[sender]!.length > 1) {
              poll.votes[sender] = [poll.votes[sender]!.first];
            }
            await saveMessage(chat, m);
          }
        }
      case Payload.need:
        // Друг не может забрать наш файл — положим куски туда, где он на связи.
        final id = p.str('id');
        final where = Contact.cleanRelays(p.data['r']);
        if (id == null || where.isEmpty) return;
        for (final m in [...app.messagesOf(chat)]) {
          if (m.id == id && m.mine && m.att != null) {
            log('  друг не может скачать ${m.att!.name} — делаю копию');
            unawaited(
              media.mirror(chat, m, where).then((got) {
                if (got.isNotEmpty) {
                  _reply(sender, chat, Payload(Payload.have, {'id': id, 'r': got}));
                }
              }),
            );
          }
        }
      case Payload.have:
        final id = p.str('id');
        final where = Contact.cleanRelays(p.data['r']);
        if (id == null || where.isEmpty) return;
        for (final m in [...app.messagesOf(chat)]) {
          if (m.id == id && !m.mine && m.att != null && !background) {
            log('  друг положил копию ${m.att!.name} — качаю');
            unawaited(media.gotMirror(chat, m, where));
          }
        }
      case Payload.receipt:
        final ids = (p.data['ids'] as List?)?.whereType<String>().toSet() ?? {};
        final st = p.str('s') == 'r' ? MsgStatus.read : MsgStatus.delivered;
        // Друг получил — больше не переотправляем (в группе — именно ему).
        await store.dequeueMessages(group ? ids.map((i) => '$i@$sender') : ids);
        for (final m in [...app.messagesOf(chat)]) {
          if (m.mine && ids.contains(m.id) && m.status.index < st.index) {
            m.status = st;
            m.sendAt = null;
            await saveMessage(chat, m);
          }
        }
      case Payload.react:
        final id = p.str('id');
        for (final m in [...app.messagesOf(chat)]) {
          if (m.id == id) {
            m.reaction = p.str('e');
            await saveMessage(chat, m);
          }
        }
      case Payload.ttl:
        c.disappearing = (p.integer('m') ?? 0).clamp(0, 60 * 24 * 30);
        await saveContact(c);
      case Payload.edit:
        // Править можно только своё: в группе — автор, в личном — собеседник.
        final id = p.str('id'), text = p.str('text');
        if (id == null || text == null) return;
        for (final m in [...app.messagesOf(chat)]) {
          if (m.id == id && !m.mine && (!group || m.from == sender)) {
            m
              ..text = text.length > 20000 ? text.substring(0, 20000) : text
              ..edited = true;
            await saveMessage(chat, m);
          }
        }
      case Payload.delete:
        final id = p.str('id');
        final list = app.messagesOf(chat);
        for (final m in [...list]) {
          if (m.id == id && !m.mine && (!group || m.from == sender)) {
            list.remove(m);
            await store.deleteMessage(m.id);
            await media.deleteFile(m);
            if (c.pinnedMsg == m.id) {
              c.pinnedMsg = null;
              await saveContact(c);
            }
          }
        }
      case Payload.todo:
        // Общий список: отметить пункт или добавить новый — может любой в чате.
        final id = p.str('id'), op = p.str('op'), item = p.str('i');
        if (id == null || item == null || item.length > 16) return;
        for (final m in [...app.messagesOf(chat)]) {
          final todo = m.todo;
          if (m.id != id || todo == null) continue;
          if (op == 't') {
            final it = todo.item(item);
            if (it == null) continue;
            it
              ..done = p.flag('on')
              ..by = p.flag('on') ? sender : null;
          } else if (op == 'a') {
            final text = p.str('tx')?.trim() ?? '';
            if (text.isEmpty || todo.item(item) != null) continue;
            if (todo.items.length >= Todo.maxItems) continue;
            todo.items.add(
              TodoItem(id: item, text: text.length > 200 ? text.substring(0, 200) : text),
            );
          }
          await saveMessage(chat, m);
        }
      case Payload.opened:
        // Друг открыл наше одноразовое — отмечаем «просмотрено».
        final id = p.str('id');
        for (final m in [...app.messagesOf(chat)]) {
          if (m.id == id && m.mine && m.once && !m.opened) {
            m.opened = true;
            await saveMessage(chat, m);
          }
        }
      case Payload.pin:
        final id = p.str('id');
        if (id != null && !app.messagesOf(chat).any((m) => m.id == id)) return;
        c.pinnedMsg = id;
        await saveContact(c);
      case Payload.typing:
        // «Ультра»: чужое «печатает» не показываем — анимация точек тоже ест батарею.
        if (app.ultra) return;
        app.typing.add(chat);
        if (group) app.typingBy[chat] = sender;
        _typingTimers[chat]?.cancel();
        _typingTimers[chat] = Timer(const Duration(seconds: 6), () {
          app.typing.remove(chat);
          app.typingBy.remove(chat);
          app.notifyChanged();
        });
    }
  }

  void _seenOnline(Contact c) {
    c.online = true;
    c.lastSeen = DateTime.now();
    _onlineTimers[c.id]?.cancel();
    // Пинг идёт раз в 45 с; два пропущенных подряд — уже не в сети.
    _onlineTimers[c.id] = Timer(const Duration(seconds: 100), () => _seenOffline(c));
  }

  void _seenOffline(Contact c) {
    _onlineTimers[c.id]?.cancel();
    if (c.online) c.lastSeen = DateTime.now();
    c.online = false;
    app.notifyChanged();
  }

  static final _pubHex = RegExp(r'^[0-9a-f]{64}$');

  /// Черновики (зашифрованная база, как и переписка).
  Future<void> saveDrafts(Map<String, dynamic> j) => store.setJson('drafts', j);

  /// Служебное сообщение (отчёт, реакция, «печатает»). Не хранится в outbox.
  void _control(String to, Payload p, {bool ephemeral = false}) {
    final k = keys, pl = pool;
    // Только настоящим собеседникам («Заметки» никуда не отправляются).
    if (k == null || pl == null || to == k.pub || !_pubHex.hasMatch(to)) return;
    GiftWrap.wrapAsync(
          sender: k,
          recipientPub: to,
          content: p.encode(),
          ephemeral: ephemeral,
          ttl: const Duration(days: 3),
        )
        .then((wrap) {
          if (!_closed) pl.publish(wrap, queue: !ephemeral);
        })
        .catchError((Object e) => log('ОШИБКА отправки ${p.type}: $e'));
  }

  /// Кому уходит сообщение чата: собеседнику или каждому участнику группы.
  List<String> targets(String chat) {
    if (Contact.isLocalId(chat)) return const [];
    final g = app.contact(chat)?.group;
    if (g == null) return Contact.isGroupId(chat) ? const [] : [chat];
    if (g.left) return const [];
    final me = keys?.pub;
    return [
      for (final m in g.members)
        if (m.pub != me) m.pub,
    ];
  }

  /// Служебное сообщение в чат: в группе — каждому участнику, с пометкой группы.
  void _toChat(String chat, Payload p, {bool ephemeral = false}) {
    if (Contact.isGroupId(chat)) p.data['g'] = chat;
    for (final to in targets(chat)) {
      _control(to, p, ephemeral: ephemeral);
    }
  }

  /// «Я в сети» — только тем, с кем переписывались за неделю (до 8 человек),
  /// чтобы не тратить батарею на шифрование для всех контактов.
  void _ping({bool online = true}) {
    if (online && !app.foreground) return;
    // «Ультра»: статус «в сети» не рассылаем — меньше шифрования и трафика.
    if (app.ultra) {
      app.savedSignals++;
      return;
    }
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final targets =
        app.contacts.where((c) {
          if (c.blocked || c.request || c.isGroup) return false;
          final last = app.lastMessage(c.id);
          return c.id == app.openChat || (last != null && last.time.isAfter(cutoff));
        }).toList()..sort((a, b) {
          final ta = app.lastMessage(a.id)?.time ?? DateTime(2000);
          final tb = app.lastMessage(b.id)?.time ?? DateTime(2000);
          return tb.compareTo(ta);
        });
    for (final c in targets.take(8)) {
      _control(
        c.id,
        Payload(Payload.ping, {'on': online, if (online) 'r': _reach()}),
        ephemeral: true,
      );
    }
  }

  // ───────────────────────── действия из интерфейса ─────────────────────────

  Map<String, dynamic> _msgPayload(String chat, Message m) => Payload(Payload.msg, {
    if (app.contact(chat) case final g? when g.isGroup) ...{'g': chat, 'gi': _groupWire(g)},
    if (m.ev != null) 'ev': m.ev,
    if (m.fwd != null) 'fw': m.fwd,
    if (m.edited) 'ed': true,
    if (_silent.contains(m.id)) 'sl': true,
    if (m.once) 'once': true,
    if (m.openAt != null) 'oa': m.openAt!.millisecondsSinceEpoch,
    if (m.todo != null) 'todo': m.todo!.toJson(wire: true),
    if (m.sticker != null) 'stk': m.sticker,
    'id': m.id,
    'ts': m.time.millisecondsSinceEpoch,
    'text': m.text,
    if (m.replyTo != null) 'reply': m.replyTo!.id,
    if (m.secret) 'secret': true,
    if (m.kind != MsgKind.text) 'k': m.kind.name,
    if (m.att != null) 'att': m.att!.toJson(wire: true),
    if (m.geo != null) 'geo': m.geo!.toJson(),
    if (m.poll != null) 'poll': m.poll!.toJson(wire: true),
    'r': _reach(),
    'p': myCard.toJson(),
  }).toMap();

  /// [silent] — без звука у получателя; [extra] — ещё кому (см. [queueMessage]).
  Future<void> sendMessage(
    String chat,
    Message m, {
    bool silent = false,
    List<String> extra = const [],
    List<String>? only,
  }) async {
    await saveMessage(chat, m);
    if (silent) _silent.add(m.id);
    // С вложением: сначала файл, потом само сообщение (см. MediaEngine.send).
    // В «Заметках» файл остаётся только на телефоне.
    if (m.att != null && !m.att!.uploaded && !Contact.isLocalId(chat)) {
      unawaited(media.send(chat, m));
      return;
    }
    await queueMessage(chat, m, extra: extra, only: only);
  }

  /// Сообщения, отправленные «без звука» (до ухода из очереди).
  final Set<String> _silent = {};

  /// Сообщение лежит в очереди, пока друг не пришлёт «доставлено» (до 3 дней).
  /// В группе — отдельная запись для каждого участника (`id@ключ`).
  /// [extra] — ещё кому (например, удалённому из группы — чтобы он узнал).
  /// [only] — только им (например, новым подписчикам канала).
  Future<void> queueMessage(
    String chat,
    Message m, {
    List<String> extra = const [],
    List<String>? only,
    bool detached = false,
  }) async {
    // Успели удалить (например, запланированное) — не отправляем.
    // [detached] — служебное, которого и не должно быть в ленте.
    if (!detached && !app.messagesOf(chat).any((x) => x.id == m.id)) return;
    // «Заметки» никуда не уходят.
    if (Contact.isLocalId(chat)) {
      m.status = MsgStatus.read;
      await saveMessage(chat, m);
      return;
    }
    final payload = _msgPayload(chat, m);
    // Одноразовое: куски уже на ретрансляторах — своя копия больше не нужна.
    if (m.once && m.mine && (m.att?.local ?? false)) {
      await media.deleteFile(m);
      m.att!.path = null;
      await saveMessage(chat, m);
    }
    // Отложенная отправка: в очереди, но не раньше назначенного времени.
    final next = m.sendAt == null ? 0 : m.sendAt!.millisecondsSinceEpoch ~/ 1000;
    if (Contact.isGroupId(chat)) {
      final to = only?.toSet() ?? {...targets(chat), ...extra};
      for (final pub in to) {
        await store.queue('${m.id}@$pub', pub, payload, next: next);
      }
      if (to.isEmpty && m.status == MsgStatus.sending && !detached) {
        // В группе больше никого — отправлять некому.
        m.status = MsgStatus.sent;
        await saveMessage(chat, m);
      }
    } else {
      await store.queue(m.id, chat, payload, next: next);
    }
    await _flushOutbox();
  }

  /// Ключи очереди сообщения (в группе — по каждому участнику).
  List<String> _queueKeys(String chat, Message m) => [
    m.id,
    for (final to in targets(chat)) '${m.id}@$to',
  ];

  /// Запланированное — отправить прямо сейчас.
  Future<void> sendNow(String chat, Message m) async {
    m.sendAt = null;
    await saveMessage(chat, m);
    await store.dequeueMessages(_queueKeys(chat, m));
    await queueMessage(chat, m);
  }

  /// Убрать из очереди (удалили неотправленное).
  Future<void> cancelQueued(String chat, Message m) => store.dequeueMessages(_queueKeys(chat, m));

  /// Общий список: отметить пункт / добавить — у всех в чате.
  void todoOp(String chat, Message m, Map<String, dynamic> op) {
    saveMessage(chat, m);
    _toChat(chat, Payload(Payload.todo, {'id': m.id, ...op}));
  }

  /// Продолжить прерванное: незалитые файлы и недокачанные фото/голосовые.
  void resumeMedia() {
    if (background || _closed) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    for (final c in app.contacts) {
      for (final m in [...app.messagesOf(c.id)]) {
        final att = m.att;
        if (att == null || media.busy(m.id) || m.time.isBefore(cutoff)) continue;
        if (m.mine && !att.uploaded && m.status == MsgStatus.sending) {
          unawaited(media.send(c.id, m));
        } else if (!m.mine &&
            !att.local &&
            !c.request &&
            app.autoDownload(m) &&
            media.retryDue(m.id)) {
          unawaited(_autoDownload(c.id, m));
        }
      }
    }
  }

  /// Скачать само. В «Ультра» — только по Wi-Fi (мобильная связь тратит больше).
  Future<void> _autoDownload(String chat, Message m) async {
    if (app.ultra && !await onWifi()) {
      app.savedDownloads++;
      return;
    }
    await media.download(chat, m);
  }

  /// Ретрансляторы, через которые мы сейчас на связи.
  List<String> _reach() => pool?.onlineUrls.take(12).toList() ?? const [];

  /// Попросить отправителя положить куски файла туда, где мы на связи.
  void askMirror(String chat, Message m) {
    final r = _reach();
    final to = m.from ?? chat;
    if (r.isEmpty || Contact.isGroupId(to)) return;
    log('  прошу ${who(to)} положить ${m.att?.name ?? 'файл'} поближе');
    _reply(to, chat, Payload(Payload.need, {'id': m.id, 'r': r}));
  }

  /// Проголосовать (или изменить голос).
  Future<void> vote(String chat, Message m, List<int> options) async {
    final poll = m.poll;
    final me = keys?.pub;
    if (poll == null || me == null) return;
    poll.votes[me] = Poll.cleanVote(options, poll.options.length);
    await saveMessage(chat, m);
    _toChat(chat, Payload(Payload.vote, {'id': m.id, 'o': poll.votes[me]}));
  }

  /// После перезапуска: всё, что друг ещё не подтвердил, — снова в очередь.
  Future<void> _requeueUnconfirmed() async {
    final queued = await store.outboxIds();
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    for (final c in [...app.contacts]) {
      for (final m in [...app.messagesOf(c.id)]) {
        if (!m.mine ||
            m.status.index >= MsgStatus.delivered.index ||
            !m.time.isAfter(cutoff) ||
            (m.att != null && !m.att!.uploaded)) {
          continue;
        }
        final next = m.sendAt == null ? 0 : m.sendAt!.millisecondsSinceEpoch ~/ 1000;
        if (c.isGroup) {
          for (final pub in targets(c.id)) {
            if (!queued.contains('${m.id}@$pub')) {
              await store.queue('${m.id}@$pub', pub, _msgPayload(c.id, m), next: next);
            }
          }
        } else if (!queued.contains(m.id)) {
          await store.queue(m.id, c.id, _msgPayload(c.id, m), next: next);
        }
      }
    }
  }

  /// Паузы между повторами: 1 мин, 3, 10, 30, 1 ч, дальше раз в 2 ч.
  static const _backoff = [60, 180, 600, 1800, 3600, 7200];

  bool _flushing = false;
  bool _flushAgain = false;

  /// Отправить то, что пора. Каждый раз — новый конверт со свежим временем:
  /// так его увидят и живые подписки, и запросы после переподключения.
  Future<void> _flushOutbox({bool all = false}) async {
    final k = keys, pl = pool;
    if (k == null || pl == null) return;
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      do {
        _flushAgain = false;
        for (final item in await store.outboxDue(all: all)) {
          if (_closed) return;
          await _deliver(k, pl, item);
        }
      } while (_flushAgain && !_closed);
    } catch (e) {
      log('ОШИБКА очереди отправки: $e');
    } finally {
      _flushing = false;
    }
  }

  Future<void> _deliver(Keys k, RelayPool pl, OutboxItem item) async {
    if (pl.onlineCount == 0) return; // уйдёт при подключении
    final wrap = await GiftWrap.wrapAsync(
      sender: k,
      recipientPub: item.chat,
      content: Payload.fromMap(item.payload).encode(),
    );
    final n = item.attempts + 1;
    log(
      '→ ${item.attempts == 0 ? 'сообщение' : 'повтор №${item.attempts}'} для ${who(item.chat)} '
      '(${short(item.msgId)}), на связи: ${pl.onlineCount}',
    );
    final ok = await pl.publish(wrap, queue: false);
    if (_closed) return;
    final accepted = pl.acceptedBy(wrap.id).map((u) => u.replaceFirst('wss://', ''));
    log(ok ? '  принято: ${accepted.join(', ')}' : '  никто не принял — повторю через 30 с');
    await store.scheduleRetry(
      item.msgId,
      ok ? n : item.attempts,
      nowSec() + (ok ? _backoff[(n - 1).clamp(0, _backoff.length - 1)] : 30),
    );
    if (ok) {
      // В группе запись очереди — «id@участник», а сообщение лежит в чате группы.
      final g = item.payload['g'];
      await _sent(g is String ? g : item.chat, item.msgId.split('@').first);
    }
  }

  Future<void> _sent(String chat, String msgId) async {
    for (final m in [...app.messagesOf(chat)]) {
      if (m.id != msgId) continue;
      // Отложенное ушло (отчёт о доставке мог прийти даже раньше этой отметки).
      final wasScheduled = m.sendAt != null;
      m.sendAt = null;
      if (m.status == MsgStatus.sending) m.status = MsgStatus.sent;
      if (wasScheduled || m.status == MsgStatus.sent) {
        await saveMessage(chat, m);
        app.notifyChanged();
      }
    }
  }

  /// Проверка связи: письмо самому себе через каждый ретранслятор.
  /// Возвращает url → (принял, вернул).
  Future<Map<String, (bool, bool)>> diagnose() async {
    final k = keys, pl = pool;
    if (k == null || pl == null) return {};
    // Сначала убедиться, что соединения действительно живы.
    await pl.verify();
    final wrap = await GiftWrap.wrapAsync(
      sender: k,
      recipientPub: k.pub,
      content: Payload('diag').encode(),
      ttl: const Duration(hours: 1),
    );
    await store.markSeen(wrap.id); // не обрабатывать как сообщение
    unawaited(pl.publish(wrap));
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      if (pl.deliveredBy(wrap.id).length == pl.urls.length) break;
    }
    return {
      for (final url in pl.urls)
        url: (pl.acceptedBy(wrap.id).contains(url), pl.deliveredBy(wrap.id).contains(url)),
    };
  }

  void typing(String chat) {
    final now = DateTime.now();
    if (now.difference(_lastTyping).inSeconds < 4) return;
    _lastTyping = now;
    // В большой группе и в канале «печатает» не рассылаем — лишняя работа.
    if (targets(chat).length > 8 || (app.contact(chat)?.isChannel ?? false)) return;
    _toChat(chat, Payload(Payload.typing), ephemeral: true);
  }

  /// Изменить своё сообщение. Ещё не доставленное — перезаписываем в очереди,
  /// чтобы друг сразу получил новый текст.
  Future<void> editMessage(String chat, Message m) async {
    await saveMessage(chat, m);
    if (m.status.index < MsgStatus.delivered.index && (m.att == null || m.att!.uploaded)) {
      await store.dequeueMessages([m.id, for (final to in targets(chat)) '${m.id}@$to']);
      await queueMessage(chat, m);
    }
    _toChat(chat, Payload(Payload.edit, {'id': m.id, 'text': m.text}));
  }

  /// Одноразовое открыли: стираем файл и сообщаем автору.
  Future<void> openedOnce(String chat, Message m) async {
    await media.deleteFile(m);
    m.att?.path = null;
    m.opened = true;
    await saveMessage(chat, m);
    final to = m.from ?? chat;
    if (!Contact.isGroupId(to)) _reply(to, chat, Payload(Payload.opened, {'id': m.id}));
  }

  /// Удалить своё сообщение у всех.
  Future<void> deleteForAll(String chat, Message m) async {
    await store.dequeueMessages([m.id, for (final to in targets(chat)) '${m.id}@$to']);
    _toChat(chat, Payload(Payload.delete, {'id': m.id}));
  }

  /// Закрепить сообщение в чате (null — открепить) — у всех.
  Future<void> pinMessage(Contact c) async {
    await saveContact(c);
    _toChat(c.id, Payload(Payload.pin, {if (c.pinnedMsg != null) 'id': c.pinnedMsg}));
  }

  Future<void> react(String chat, Message m) async {
    await saveMessage(chat, m);
    _toChat(chat, Payload(Payload.react, {'id': m.id, 'e': m.reaction}));
  }

  /// Отправить «прочитано» для всех непрочитанных входящих.
  Future<void> markRead(String chat, {required bool sendReceipt}) async {
    // Кому что прочитано: в группе у каждого сообщения свой автор.
    final ids = <String, List<String>>{};
    for (final m in [...app.messagesOf(chat)]) {
      if (!m.mine && m.status == MsgStatus.delivered) {
        m.status = MsgStatus.read;
        (ids[m.from ?? chat] ??= []).add(m.id);
        await saveMessage(chat, m);
      }
    }
    if (!sendReceipt) return;
    for (final e in ids.entries) {
      if (Contact.isGroupId(e.key)) continue;
      _reply(e.key, chat, Payload(Payload.receipt, {'ids': e.value, 's': 'r'}));
    }
  }

  Future<Contact> addContact(Invite inv) async {
    var c = app.contact(inv.pubkey);
    if (c == null) {
      c = Contact(
        id: inv.pubkey,
        name: inv.card.name,
        emoji: inv.card.emoji,
        colorIndex: inv.card.color,
        bio: inv.card.bio,
        verified: true,
      );
      app.contacts.add(c);
    } else {
      c.request = false;
      c.blocked = false;
    }
    await saveContact(c);
    _control(c.id, Payload(Payload.hello, {'p': myCard.toJson()}));
    app.notifyChanged();
    return c;
  }

  Future<void> setTtl(Contact c) async {
    await saveContact(c);
    _toChat(c.id, Payload(Payload.ttl, {'m': c.disappearing}));
  }

  /// Удалить друга полностью: контакт, переписку, очередь отправки.
  Future<void> deleteContact(String id) async {
    app.contacts.removeWhere((c) => c.id == id);
    app.setMessages(id, []);
    await store.deleteContact(id);
    await media.deleteChat(id);
    log('удалён контакт ${short(id)}');
  }

  Future<void> saveContact(Contact c) => store.saveContact(c.id, c.toJson());

  Future<void> saveMessage(String chat, Message m) =>
      store.saveMessage(chat, m.id, m.time.millisecondsSinceEpoch, m.toJson());

  Future<void> saveSettings(Map<String, dynamic> s) => store.setJson('settings', s);

  // ── PIN: храним только соль и хэш ──

  Future<void> setPin(String? pin) async {
    if (pin == null) {
      await secrets.write('pin', '');
      app.hasPin = false;
      return;
    }
    final salt = hexEncode(randomBytes(16));
    await secrets.write('pin', '$salt:${_hash(salt, pin)}');
    app.hasPin = true;
  }

  Future<bool> checkPin(String pin) async {
    final v = await secrets.read('pin');
    if (v == null || !v.contains(':')) return false;
    final [salt, hash] = v.split(':');
    return _hash(salt, pin) == hash;
  }

  // ── Тайник: PIN тайника, PIN «под принуждением», код входа маскировки ──
  // Ключи: 'vault', 'duress', 'cover'. Тоже только соль и хэш, в Keystore.

  Future<void> setSecret(String key, String? pin) async {
    if (pin == null) {
      await secrets.write(key, '');
      return;
    }
    final salt = hexEncode(randomBytes(16));
    await secrets.write(key, '$salt:${_hash(salt, pin)}');
  }

  Future<bool> checkSecret(String key, String pin) async {
    final v = await secrets.read(key);
    if (v == null || !v.contains(':')) return false;
    final [salt, hash] = v.split(':');
    return _hash(salt, pin) == hash;
  }

  Future<bool> hasSecret(String key) async => (await secrets.read(key) ?? '').contains(':');

  static String _hash(String salt, String pin) {
    List<int> h = utf8.encode('$salt$pin');
    for (var i = 0; i < 20000; i++) {
      h = sha256.convert(h).bytes;
    }
    return hexEncode(h);
  }

  void _expire() {
    final now = DateTime.now();
    var changed = false;
    for (final c in app.contacts) {
      if (c.disappearing <= 0) continue;
      final cutoff = now.subtract(Duration(minutes: c.disappearing));
      final list = app.messagesOf(c.id);
      final before = list.length;
      for (final m in list) {
        if (m.time.isBefore(cutoff)) media.deleteFile(m);
      }
      list.removeWhere((m) => m.time.isBefore(cutoff));
      if (list.length != before) {
        changed = true;
        store.expire(c.id, cutoff.millisecondsSinceEpoch);
      }
    }
    if (changed) app.notifyChanged();
  }

  /// «Красная кнопка».
  Future<void> wipe() async {
    await close();
    await secrets.deleteAll();
    await store.destroy();
    await media.wipe();
  }

  Future<void> close() async {
    _closed = true;
    await _events?.cancel();
    await _queue.timeout(const Duration(seconds: 5), onTimeout: () {});
    _presence?.cancel();
    _expiry?.cancel();
    _heartbeat?.cancel();
    _resend?.cancel();
    _resub?.cancel();
    if (_syncedAt > _syncedSaved && store.db.isOpen) {
      await store.set('synced', '$_syncedAt').catchError((_) {});
    }
    for (final t in [..._typingTimers.values, ..._onlineTimers.values]) {
      t.cancel();
    }
    await _events?.cancel();
    await _changes?.cancel();
    await pool?.close();
    if (store.db.isOpen) await store.close();
  }
}
