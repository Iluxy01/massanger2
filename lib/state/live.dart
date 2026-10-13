import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../core/giftwrap.dart';
import '../core/nostr.dart';
import '../core/protocol.dart';
import '../core/relay_pool.dart';
import '../core/store.dart';
import '../models/models.dart';
import 'app_state.dart';

/// Показ системных уведомлений (реализация — в core/notifier.dart).
abstract class Notify {
  Future<void> message(Contact from, Message m);
}

/// «Живой» режим: настоящие ключи, база на телефоне и ретрансляторы.
///
/// Экраны работают только с [AppState]; этот класс подгружает в него данные,
/// сохраняет изменения и обменивается зашифрованными конвертами с друзьями.
class Live {
  Live._(this.app, this.store, this.secrets, this._connector);

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
  int _lastSinceSave = 0;
  bool _closed = false;

  /// Для фоновой проверки: отдельное соединение с базой, ничего не создаём.
  static Future<Live?> bootBackground(AppState app) async {
    final s = DeviceSecrets();
    final store = await Store.open(s, shared: false, createKey: false);
    if (store == null) return null;
    final live = Live._(app, store, s, null);
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
  }) async {
    final s = secrets ?? DeviceSecrets();
    final store = await Store.open(s, factory: dbFactory, path: dbPath);
    final live = Live._(app, store!, s, connector);
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

    final priv = await secrets.read('priv');
    final prof = await store.getJson('profile');
    if (priv != null && prof != null) {
      keys = Keys(priv);
      app.profile = Profile.fromJson(prof);
      await reload();
      if (network) startNetwork();
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
    await store.set('since', '${nowSec()}');
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
      if (n > _lastOnline) _flushOutbox();
      _lastOnline = n;
      app.notifyChanged();
    });
    _subscribe();
    p.start();
    _presence = Timer.periodic(const Duration(seconds: 45), (_) => _ping());
    // Переотправка неподтверждённых сообщений и повторный запрос входящих.
    _resend = Timer.periodic(const Duration(minutes: 2), (_) => _flushOutbox());
    _resub = Timer.periodic(const Duration(minutes: 3), (_) {
      if (app.foreground) _subscribe();
    });
    store.pruneOutbox().catchError((_) {});
    Future<void>.delayed(const Duration(seconds: 3), _ping);
  }

  Future<void> _subscribe() async {
    final since = int.tryParse(await store.get('since') ?? '') ?? nowSec();
    // Конверты датированы «задним числом» до 2 суток — берём с запасом.
    pool?.subscribe([
      {
        'kinds': [GiftWrap.kindWrap],
        '#p': [keys!.pub],
        'since': since - 2 * 24 * 3600 - 600,
      },
      {
        'kinds': [GiftWrap.kindWrapEphemeral],
        '#p': [keys!.pub],
        'since': nowSec() - 60,
      },
    ]);
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
    // На всякий случай — заново запросить накопившееся у ретрансляторов.
    unawaited(_subscribe());
    pool?.wake();
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
    if (!ephemeral && nowSec() - _lastSinceSave > 30) {
      _lastSinceSave = nowSec();
      await store.set('since', '${nowSec()}');
    }
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
        final id = p.str('id'), text = p.str('text');
        if (id == null || text == null || id.length > 64) return;
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
          secret: p.flag('secret'),
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

  /// «Я в сети» — только тем, с кем недавно переписывались (до 15 человек),
  /// чтобы не тратить батарею на шифрование для всех контактов.
  void _ping({bool online = true}) {
    if (online && !app.foreground) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 14));
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
    for (final c in targets.take(15)) {
      _control(c.id, Payload(Payload.ping, {'on': online}), ephemeral: true);
    }
  }

  // ───────────────────────── действия из интерфейса ─────────────────────────

  Future<void> sendMessage(String chat, Message m) async {
    await saveMessage(chat, m);
    final k = keys, pl = pool;
    if (k == null || pl == null) return;
    final payload = Payload(Payload.msg, {
      'id': m.id,
      'ts': m.time.millisecondsSinceEpoch,
      'text': m.text,
      if (m.replyTo != null) 'reply': m.replyTo!.id,
      if (m.secret) 'secret': true,
      'p': myCard.toJson(),
    });
    final wrap = await GiftWrap.wrapAsync(sender: k, recipientPub: chat, content: payload.encode());
    // Конверт лежит в очереди, пока друг не пришлёт «доставлено» (до 3 дней).
    await store.queue(wrap.id, chat, m.id, jsonEncode(wrap.toJson()));
    log(
      '→ сообщение для ${who(chat)} (${short(wrap.id)}), онлайн ретрансляторов: ${pl.onlineCount}',
    );
    final ok = await pl.publish(wrap);
    log(
      ok
          ? '  принято: ${pl.acceptedBy(wrap.id).map((u) => u.replaceFirst('wss://', '')).join(', ')}'
          : '  пока никто не принял — повторю позже',
    );
    if (ok) await _sent(wrap.id, chat, m.id);
  }

  Future<void> _sent(String wrapId, String chat, String msgId) async {
    for (final m in app.messagesOf(chat)) {
      if (m.id == msgId && m.status == MsgStatus.sending) {
        m.status = MsgStatus.sent;
        await saveMessage(chat, m);
        app.notifyChanged();
      }
    }
  }

  bool _flushing = false;

  Future<void> _flushOutbox() async {
    final pl = pool;
    if (pl == null || _flushing) return;
    _flushing = true;
    try {
      for (final row in await store.outbox()) {
        final e = Event.fromJson(jsonDecode(row['event'] as String) as Map<String, dynamic>);
        if (await pl.publish(e)) {
          await _sent(row['id'] as String, row['chat'] as String, row['msg'] as String);
        }
      }
    } finally {
      _flushing = false;
    }
  }

  /// Проверка связи: письмо самому себе через каждый ретранслятор.
  /// Возвращает url → (принял, вернул).
  Future<Map<String, (bool, bool)>> diagnose() async {
    final k = keys, pl = pool;
    if (k == null || pl == null) return {};
    pl.wake();
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
    for (final t in [..._typingTimers.values, ..._onlineTimers.values]) {
      t.cancel();
    }
    await _events?.cancel();
    await _changes?.cancel();
    await pool?.close();
    if (store.db.isOpen) await store.close();
  }
}
