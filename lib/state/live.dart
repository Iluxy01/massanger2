import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../core/giftwrap.dart';
import '../core/nostr.dart';
import '../core/protocol.dart';
import '../core/relay_pool.dart';
import '../core/store.dart';
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
    app.hasPin = (await secrets.read('pin') ?? '').isNotEmpty;
    app.locked = app.hasPin;

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
      }
    }
    _expiry = Timer.periodic(const Duration(seconds: 30), (_) => _expire());
    // «Приложение живо» (даже свёрнутое) — пока стучит этот пульс, фоновая
    // проверка не запускается и не пишет в базу одновременно с приложением.
    if (network) {
      await store.set('alive', '${nowSec()}');
      _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) {
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

  Future<void> createIdentity(Profile Function(String pub) build) async {
    final k = Keys.generate();
    await secrets.write('priv', k.priv);
    keys = k;
    final p = build(k.pub);
    app.profile = p;
    await store.setJson('profile', p.toJson());
    // Только что созданному ключу нечего забирать из прошлого.
    _syncedAt = nowSec();
    await store.set('synced', '$_syncedAt');
    startNetwork();
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
      if (!c.blocked) _control(c.id, Payload(Payload.profile, {'p': myCard.toJson()}));
    }
  }

  // ───────────────────────── сеть ─────────────────────────

  void startNetwork() {
    if (pool != null || keys == null || _closed) return;
    final p = pool = RelayPool(relays, connector: _connector);
    p.onSynced = _synced;
    _events = p.events.listen((e) => _queue = _queue.then((_) => _safely(e)));
    _changes = p.changes.listen((_) {
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
      if (n > _lastOnline) {
        _flushOutbox();
        if (_lastOnline == 0) resumeMedia();
      }
      _lastOnline = n;
      app.notifyChanged();
    });
    p.subscribe(_filters);
    p.start();
    _presence = Timer.periodic(const Duration(seconds: 60), (_) => _ping());
    // Переотправка неподтверждённых сообщений (по расписанию с паузами).
    _resend = Timer.periodic(const Duration(seconds: 30), (_) {
      _flushOutbox();
      // Недокачанные файлы — повторяем сами, с растущей паузой.
      if (app.foreground) resumeMedia();
    });
    // Подстраховка: изредка заново спросить новое (дёшево — окно маленькое).
    _resub = Timer.periodic(const Duration(minutes: 10), (_) {
      if (app.foreground) p.subscribe(_filters);
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
    pool?.setUrls(urls);
    app.notifyChanged();
  }

  /// Приложение вернулось на экран.
  Future<void> resumed() async {
    await store.set('alive', '${nowSec()}');
    await reload();
    // Проверить соединения (мобильная сеть могла их тихо оборвать) и
    // заново спросить накопившееся.
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
    _ping(online: false);
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
    if (p.type == Payload.ping) {
      p.data['on'] == false ? _seenOffline(c) : _seenOnline(c);
    } else if (fresh && (p.type == Payload.typing || p.type == Payload.msg)) {
      _seenOnline(c);
    }

    switch (p.type) {
      case Payload.msg:
        final id = p.str('id'), text = p.str('text') ?? '';
        if (id == null || id.length > 64) return;
        final kind = Message.kindOf(p.data['k']);
        final att = Attachment.fromJson(p.data['att'])?..path = null;
        final geo = GeoPoint.fromJson(p.data['geo']);
        final poll = Poll.fromJson(p.data['poll'])?..votes.clear();
        final valid = switch (kind) {
          MsgKind.text => true,
          MsgKind.voice ||
          MsgKind.photo ||
          MsgKind.video ||
          MsgKind.file => att != null && att.uploaded && att.size <= MediaEngine.maxBytes,
          MsgKind.geo => geo != null,
          MsgKind.poll => poll != null,
        };
        if (!valid) {
          log('  непонятное сообщение ${short(id)} (${p.data['k']}) — пропущено');
          return;
        }
        final list = app.messagesOf(sender);
        if (list.any((m) => m.id == id)) {
          // Повтор (отправитель не получил наш отчёт) — подтверждаем ещё раз.
          _control(
            sender,
            Payload(Payload.receipt, {
              'ids': [id],
              's': 'd',
            }),
          );
          return;
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
        final m = Message(
          id: id,
          mine: false,
          text: text.length > 20000 ? text.substring(0, 20000) : text,
          time: time,
          status: MsgStatus.delivered,
          replyTo: reply,
          secret: kind == MsgKind.text && p.flag('secret'),
          kind: kind,
          att: att,
          geo: geo,
          poll: poll,
        );
        var at = list.length;
        while (at > 0 && list[at - 1].time.isAfter(m.time)) {
          at--;
        }
        list.insert(at, m);
        app.typing.remove(sender);
        await saveMessage(sender, m);
        _control(
          sender,
          Payload(Payload.receipt, {
            'ids': [id],
            's': 'd',
          }),
        );
        await app.onIncoming(c, m);
        if (!background && !c.request && MediaEngine.autoKind(m)) {
          unawaited(media.download(sender, m));
        }
      case Payload.vote:
        final id = p.str('id');
        final raw = p.data['o'];
        if (id == null || raw is! List) return;
        for (final m in app.messagesOf(sender)) {
          final poll = m.poll;
          if (m.id == id && poll != null) {
            poll.votes[sender] = Poll.cleanVote(raw, poll.options.length);
            if (!poll.multi && poll.votes[sender]!.length > 1) {
              poll.votes[sender] = [poll.votes[sender]!.first];
            }
            await saveMessage(sender, m);
          }
        }
      case Payload.receipt:
        final ids = (p.data['ids'] as List?)?.whereType<String>().toSet() ?? {};
        final st = p.str('s') == 'r' ? MsgStatus.read : MsgStatus.delivered;
        // Друг получил — больше не переотправляем.
        await store.dequeueMessages(ids);
        for (final m in app.messagesOf(sender)) {
          if (m.mine && ids.contains(m.id) && m.status.index < st.index) {
            m.status = st;
            await saveMessage(sender, m);
          }
        }
      case Payload.react:
        final id = p.str('id');
        for (final m in app.messagesOf(sender)) {
          if (m.id == id) {
            m.reaction = p.str('e');
            await saveMessage(sender, m);
          }
        }
      case Payload.ttl:
        c.disappearing = (p.integer('m') ?? 0).clamp(0, 60 * 24 * 30);
        await saveContact(c);
      case Payload.typing:
        app.typing.add(sender);
        _typingTimers[sender]?.cancel();
        _typingTimers[sender] = Timer(const Duration(seconds: 6), () {
          app.typing.remove(sender);
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

  /// Служебное сообщение (отчёт, реакция, «печатает»). Не хранится в outbox.
  void _control(String to, Payload p, {bool ephemeral = false}) {
    final k = keys, pl = pool;
    if (k == null || pl == null || to == k.pub) return;
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

  /// «Я в сети» — только тем, с кем переписывались за неделю (до 8 человек),
  /// чтобы не тратить батарею на шифрование для всех контактов.
  void _ping({bool online = true}) {
    if (online && !app.foreground) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    final targets =
        app.contacts.where((c) {
          if (c.blocked || c.request) return false;
          final last = app.lastMessage(c.id);
          return c.id == app.openChat || (last != null && last.time.isAfter(cutoff));
        }).toList()..sort((a, b) {
          final ta = app.lastMessage(a.id)?.time ?? DateTime(2000);
          final tb = app.lastMessage(b.id)?.time ?? DateTime(2000);
          return tb.compareTo(ta);
        });
    for (final c in targets.take(8)) {
      _control(c.id, Payload(Payload.ping, {'on': online}), ephemeral: true);
    }
  }

  // ───────────────────────── действия из интерфейса ─────────────────────────

  Map<String, dynamic> _msgPayload(Message m) => Payload(Payload.msg, {
    'id': m.id,
    'ts': m.time.millisecondsSinceEpoch,
    'text': m.text,
    if (m.replyTo != null) 'reply': m.replyTo!.id,
    if (m.secret) 'secret': true,
    if (m.kind != MsgKind.text) 'k': m.kind.name,
    if (m.att != null) 'att': m.att!.toJson(wire: true),
    if (m.geo != null) 'geo': m.geo!.toJson(),
    if (m.poll != null) 'poll': m.poll!.toJson(wire: true),
    'p': myCard.toJson(),
  }).toMap();

  Future<void> sendMessage(String chat, Message m) async {
    await saveMessage(chat, m);
    // С вложением: сначала файл, потом само сообщение (см. MediaEngine.send).
    if (m.att != null && !m.att!.uploaded) {
      unawaited(media.send(chat, m));
      return;
    }
    await queueMessage(chat, m);
  }

  /// Сообщение лежит в очереди, пока друг не пришлёт «доставлено» (до 3 дней).
  Future<void> queueMessage(String chat, Message m) async {
    await store.queue(m.id, chat, _msgPayload(m));
    await _flushOutbox();
  }

  /// Продолжить прерванное: незалитые файлы и недокачанные фото/голосовые.
  void resumeMedia() {
    if (background || _closed) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    for (final c in app.contacts) {
      for (final m in app.messagesOf(c.id)) {
        final att = m.att;
        if (att == null || media.busy(m.id) || m.time.isBefore(cutoff)) continue;
        if (m.mine && !att.uploaded && m.status == MsgStatus.sending) {
          unawaited(media.send(c.id, m));
        } else if (!m.mine &&
            !att.local &&
            !c.request &&
            MediaEngine.autoKind(m) &&
            media.retryDue(m.id)) {
          unawaited(media.download(c.id, m));
        }
      }
    }
  }

  /// Проголосовать (или изменить голос).
  Future<void> vote(String chat, Message m, List<int> options) async {
    final poll = m.poll;
    final me = keys?.pub;
    if (poll == null || me == null) return;
    poll.votes[me] = Poll.cleanVote(options, poll.options.length);
    await saveMessage(chat, m);
    _control(chat, Payload(Payload.vote, {'id': m.id, 'o': poll.votes[me]}));
  }

  /// После перезапуска: всё, что друг ещё не подтвердил, — снова в очередь.
  Future<void> _requeueUnconfirmed() async {
    final queued = await store.outboxIds();
    final cutoff = DateTime.now().subtract(const Duration(days: 3));
    for (final c in app.contacts) {
      for (final m in app.messagesOf(c.id)) {
        if (m.mine &&
            m.status.index < MsgStatus.delivered.index &&
            m.time.isAfter(cutoff) &&
            !queued.contains(m.id) &&
            (m.att == null || m.att!.uploaded)) {
          await store.queue(m.id, c.id, _msgPayload(m));
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
    if (ok) await _sent(item.chat, item.msgId);
  }

  Future<void> _sent(String chat, String msgId) async {
    for (final m in app.messagesOf(chat)) {
      if (m.id == msgId && m.status == MsgStatus.sending) {
        m.status = MsgStatus.sent;
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
      if (pl.deliveredBy(wrap.id).length == relays.length) break;
    }
    return {
      for (final url in relays)
        url: (pl.acceptedBy(wrap.id).contains(url), pl.deliveredBy(wrap.id).contains(url)),
    };
  }

  void typing(String chat) {
    final now = DateTime.now();
    if (now.difference(_lastTyping).inSeconds < 4) return;
    _lastTyping = now;
    _control(chat, Payload(Payload.typing), ephemeral: true);
  }

  Future<void> react(String chat, Message m) async {
    await saveMessage(chat, m);
    _control(chat, Payload(Payload.react, {'id': m.id, 'e': m.reaction}));
  }

  /// Отправить «прочитано» для всех непрочитанных входящих.
  Future<void> markRead(String chat, {required bool sendReceipt}) async {
    final ids = <String>[];
    for (final m in app.messagesOf(chat)) {
      if (!m.mine && m.status == MsgStatus.delivered) {
        m.status = MsgStatus.read;
        ids.add(m.id);
        await saveMessage(chat, m);
      }
    }
    if (ids.isNotEmpty && sendReceipt) {
      _control(chat, Payload(Payload.receipt, {'ids': ids, 's': 'r'}));
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
    _control(c.id, Payload(Payload.ttl, {'m': c.disappearing}));
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
