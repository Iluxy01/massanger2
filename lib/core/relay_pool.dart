import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'nostr.dart';

/// Бесплатные публичные ретрансляторы Nostr. Они пересылают зашифрованные
/// конверты и хранят их не дольше срока из тега expiration (у нас 7 дней).
const defaultRelays = [
  // Проверены в CI (test/network_test.dart): принимают, хранят и отдают конверты.
  'wss://relay.primal.net',
  'wss://nos.lol',
  'wss://nostr.mom',
  'wss://relay.mostr.pub',
  'wss://relay.snort.social',
  'wss://nostr-pub.wellorder.net',
  'wss://nostr.oxtr.dev',
  'wss://relay.coinos.io',
  'wss://nostr.data.haus',
];

/// Прежний список по умолчанию: offchain.pub и nostr.bitcoiner.social стали
/// отказывать незнакомым ключам («web of trust») — заменены на проверенные в CI.
/// Если у человека сохранён ровно этот список, он обновляется сам.
const previousDefaultRelays = [
  'wss://relay.primal.net',
  'wss://nos.lol',
  'wss://nostr.mom',
  'wss://offchain.pub',
  'wss://relay.snort.social',
  'wss://nostr-pub.wellorder.net',
  'wss://nostr.oxtr.dev',
  'wss://nostr.bitcoiner.social',
  'wss://nostr.data.haus',
];

typedef Connector = WebSocketChannel Function(Uri uri);

enum RelayState { connecting, online, offline }

class _Relay {
  _Relay(this.url);

  final String url;
  WebSocketChannel? ch;
  StreamSubscription<dynamic>? sub;
  RelayState state = RelayState.offline;
  String? error;
  int attempt = 0;
  Timer? retry;
  bool eose = false;
  final List<String> queue = [];

  /// Номер попытки подключения: ответы «старых» соединений игнорируются.
  int gen = 0;

  /// Когда от ретранслятора последний раз что-то приходило.
  DateTime lastRx = DateTime.now();

  /// Отправлен пробный запрос, ответа ещё нет.
  DateTime? probeAt;

  /// Когда отправлен основной запрос подписки (для отметки «синхронизировано до»).
  int reqAt = 0;
}

/// Пул WebSocket-соединений с ретрансляторами: переподключение, проверка
/// живости, очередь, одна общая подписка, дедупликация входящих событий.
class RelayPool {
  RelayPool(
    List<String> urls, {
    Connector? connector,
    this.idleProbe = const Duration(seconds: 45),
    this.probeTimeout = const Duration(seconds: 12),
  }) : _connector = connector ?? ((u) => WebSocketChannel.connect(u)) {
    setUrls(urls);
  }

  final Connector _connector;

  /// Сколько можно молчать, прежде чем проверить соединение. В свёрнутом
  /// приложении — реже (батарея).
  Duration idleProbe;

  /// Сколько ждать ответа на проверку, прежде чем переподключиться.
  final Duration probeTimeout;

  final Map<String, _Relay> _relays = {};
  List<Map<String, dynamic>> Function() _filters = () => const [];
  final _seen = <String>{};
  final _events = StreamController<Event>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final Map<String, Completer<bool>> _pendingOk = {};
  final Map<String, Set<String>> _okBy = {};
  final Map<String, Set<String>> _sources = {};
  final Map<String, _Waiter> _waiters = {};
  final Map<String, _Fetch> _fetches = {};
  int _fetchSeq = 0;
  Timer? _health;
  bool _closed = false;
  bool _started = false;

  /// Ретранслятор отдал всё накопленное по запросу, отправленному в момент `reqAt`.
  void Function(String url, int reqAt)? onSynced;

  /// Ретранслятор отказался принять событие (id, url, причина).
  void Function(String id, String url, String why)? onReject;

  static const subId = 'veil';
  static const _probeId = 'hb';
  static final _probeFilter = {
    'ids': ['0' * 64],
    'limit': 1,
  };

  Stream<Event> get events => _events.stream;
  Stream<void> get changes => _changes.stream;

  List<String> get urls => _relays.keys.toList();
  int get onlineCount => _relays.values.where((r) => r.state == RelayState.online).length;
  List<String> get onlineUrls => [
    for (final r in _relays.values)
      if (r.state == RelayState.online) r.url,
  ];
  RelayState stateOf(String url) => _relays[url]?.state ?? RelayState.offline;
  String? errorOf(String url) => _relays[url]?.error;

  void setUrls(List<String> urls) {
    final wanted = urls.map((u) => u.trim()).where((u) => u.startsWith('ws')).toSet();
    for (final u in _relays.keys.toList()) {
      if (!wanted.contains(u)) _drop(_relays.remove(u)!);
    }
    for (final u in wanted) {
      if (_relays.containsKey(u)) continue;
      final r = _relays[u] = _Relay(u);
      if (_started) _connect(r);
    }
    _notify();
  }

  void start() {
    if (_started) return;
    _started = true;
    for (final r in _relays.values) {
      if (r.state == RelayState.offline) _connect(r);
    }
    _health = Timer.periodic(const Duration(seconds: 5), (_) => _checkHealth());
  }

  /// После выхода из фона: переподключить отвалившиеся и сразу проверить
  /// «вроде бы живые» соединения — мобильная сеть часто рвёт их молча.
  void wake() {
    for (final r in _relays.values) {
      switch (r.state) {
        case RelayState.offline:
          r.retry?.cancel();
          r.attempt = 0;
          _connect(r);
        case RelayState.online:
          if (DateTime.now().difference(r.lastRx).inSeconds > 5) _probe(r);
        case RelayState.connecting:
          break; // уже подключается — не плодим второе соединение
      }
    }
  }

  /// Проверить все соединения и дождаться результата (для «Проверить связь»).
  Future<void> verify({Duration timeout = const Duration(seconds: 10)}) async {
    wake();
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final busy = _relays.values.any((r) => r.state == RelayState.connecting || r.probeAt != null);
      if (!busy) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  void _checkHealth() {
    if (_closed) return;
    final now = DateTime.now();
    for (final r in _relays.values) {
      if (r.state != RelayState.online) continue;
      final probe = r.probeAt;
      if (probe != null) {
        if (now.difference(probe) > probeTimeout) _lost(r, 'не отвечает');
      } else if (now.difference(r.lastRx) > idleProbe) {
        _probe(r);
      }
    }
  }

  void _probe(_Relay r) {
    if (r.probeAt != null || r.state != RelayState.online) return;
    r.probeAt = DateTime.now();
    _send(r, jsonEncode(['REQ', _probeId, _probeFilter]), queue: false);
  }

  /// [build] вызывается при каждой отправке запроса (в т.ч. после переподключения),
  /// поэтому «с какого времени» всегда актуально.
  void subscribe(List<Map<String, dynamic>> Function() build) {
    _filters = build;
    // Новый запрос — события снова можно получить (если раньше их не удалось обработать).
    _seen.clear();
    for (final r in _relays.values) {
      if (r.state == RelayState.online) _sendReq(r);
    }
  }

  void _sendReq(_Relay r) {
    final filters = _filters();
    if (filters.isEmpty) return;
    r.eose = false;
    r.reqAt = nowSec();
    _send(r, jsonEncode(['REQ', subId, ...filters]), queue: false);
  }

  /// Опубликовать событие во все ретрансляторы. true — хотя бы один принял.
  Future<bool> publish(
    Event e, {
    Duration timeout = const Duration(seconds: 12),
    bool queue = true,
  }) {
    final c = _pendingOk[e.id] ??= Completer<bool>();
    final msg = jsonEncode(['EVENT', e.toJson()]);
    for (final r in _relays.values) {
      _send(r, msg, queue: queue);
    }
    Timer(timeout, () {
      if (!c.isCompleted) {
        c.complete(false);
        _pendingOk.remove(e.id);
      }
    });
    return c.future;
  }

  /// Опубликовать в выбранные ретрансляторы и дождаться ответа каждого.
  /// Возвращает, кто принял; причины отказов — в [rejected].
  ///
  /// [want] — сколько подтверждений достаточно, чтобы не ждать остальных
  /// (их ответы всё равно учитываются в [acceptedBy]).
  Future<Set<String>> publishTo(
    Event e,
    Iterable<String> urls, {
    Duration timeout = const Duration(seconds: 20),
    int? want,
  }) {
    final targets = {
      for (final u in urls)
        if (_relays[u]?.state == RelayState.online) u,
    };
    if (targets.isEmpty || _closed) return Future.value({});
    final w = _waiters[e.id] = _Waiter(targets, want ?? targets.length);
    _sentAt[e.id] = DateTime.now();
    if (_sentAt.length > 2000) _sentAt.remove(_sentAt.keys.first);
    final msg = jsonEncode(['EVENT', e.toJson()]);
    for (final u in targets) {
      _send(_relays[u]!, msg, queue: false);
    }
    w.timer = Timer(timeout, () => _finishWaiter(e.id));
    return w.done.future;
  }

  final Map<String, DateTime> _sentAt = {};
  final Map<String, double> _latency = {};

  /// Сколько (мс, сглаженно) ретранслятор отвечает на крупные события.
  double? latencyOf(String url) => _latency[url];

  /// Почему ретрансляторы отказались принять событие [id] (url → причина).
  Map<String, String> rejected(String id) => _rejected[id] ?? const {};
  final Map<String, Map<String, String>> _rejected = {};

  void _finishWaiter(String id) {
    final w = _waiters.remove(id);
    if (w == null) return;
    w.timer?.cancel();
    if (!w.done.isCompleted) w.done.complete(w.accepted);
  }

  /// Разовый запрос к одному ретранслятору. [onEvent] — на каждое событие.
  /// Завершается по EOSE, отказу, обрыву, молчанию дольше [idle] или через [total].
  Future<void> fetch(
    String url,
    Map<String, dynamic> filter,
    void Function(Event e) onEvent, {
    Duration idle = const Duration(seconds: 12),
    Duration total = const Duration(seconds: 90),
    bool Function()? stop,
  }) async {
    final r = _relays[url];
    if (r == null || r.state != RelayState.online || _closed) return;
    final id = 'f${_fetchSeq++}';
    final f = _fetches[id] = _Fetch(url, onEvent, r.gen);
    _send(r, jsonEncode(['REQ', id, filter]), queue: false);
    final end = DateTime.now().add(total);
    while (!f.done.isCompleted) {
      final now = DateTime.now();
      if (now.isAfter(end) ||
          now.difference(f.last) > idle ||
          r.gen != f.gen ||
          r.state != RelayState.online ||
          _closed ||
          (stop?.call() ?? false)) {
        break;
      }
      await Future.any([f.done.future, Future<void>.delayed(const Duration(milliseconds: 250))]);
    }
    _fetches.remove(id);
    if (r.state == RelayState.online && r.gen == f.gen) {
      _send(r, jsonEncode(['CLOSE', id]), queue: false);
    }
  }

  void _send(_Relay r, String msg, {required bool queue}) {
    if (r.state == RelayState.online && r.ch != null) {
      try {
        r.ch!.sink.add(msg);
        return;
      } catch (_) {}
    }
    if (queue && r.queue.length < 100) r.queue.add(msg);
  }

  Future<void> _connect(_Relay r) async {
    if (_closed) return;
    final gen = ++r.gen;
    r.state = RelayState.connecting;
    r.probeAt = null;
    _notify();
    WebSocketChannel? ch;
    try {
      ch = _connector(Uri.parse(r.url));
      await ch.ready.timeout(const Duration(seconds: 12));
      if (_closed || gen != r.gen || !_relays.containsKey(r.url)) {
        ch.sink.close();
        return;
      }
      r.ch = ch;
      r.state = RelayState.online;
      r.error = null;
      r.attempt = 0;
      r.lastRx = DateTime.now();
      _notify();
      r.sub = ch.stream.listen(
        (m) {
          if (gen == r.gen) _onMessage(r, m);
        },
        onDone: () {
          if (gen == r.gen) _lost(r, 'соединение закрыто');
        },
        onError: (Object e) {
          if (gen == r.gen) _lost(r, '$e');
        },
      );
      _sendReq(r);
      final q = List.of(r.queue);
      r.queue.clear();
      for (final m in q) {
        _send(r, m, queue: true);
      }
    } catch (e) {
      try {
        ch?.sink.close();
      } catch (_) {}
      if (gen == r.gen) _lost(r, '$e');
    }
  }

  void _lost(_Relay r, String why) {
    r.gen++; // всё, что придёт от этого соединения дальше, игнорируем
    // Ждущие ответа от этого ретранслятора — уже не дождутся.
    for (final e in _waiters.entries.toList()) {
      final w = e.value;
      if (w.targets.contains(r.url) &&
          w.answered.add(r.url) &&
          w.answered.length >= w.targets.length) {
        _finishWaiter(e.key);
      }
    }
    r.sub?.cancel();
    r.sub = null;
    try {
      r.ch?.sink.close();
    } catch (_) {}
    r.ch = null;
    r.probeAt = null;
    r.eose = false;
    r.state = RelayState.offline;
    r.error = why.length > 120 ? why.substring(0, 120) : why;
    r.attempt++;
    _notify();
    if (_closed || !_relays.containsKey(r.url)) return;
    final delay = Duration(seconds: [2, 4, 8, 15, 30, 60][r.attempt.clamp(1, 6) - 1]);
    r.retry?.cancel();
    r.retry = Timer(delay, () {
      if (r.state == RelayState.offline) _connect(r);
    });
  }

  void _onMessage(_Relay r, dynamic raw) {
    r.lastRx = DateTime.now();
    r.probeAt = null; // любой ответ — соединение живо
    try {
      final m = jsonDecode(raw as String) as List;
      switch (m[0]) {
        case 'EVENT':
          if (m.length < 3) return;
          final f = _fetches[m[1]];
          if (f != null) {
            if (f.url != r.url) return;
            f.last = DateTime.now();
            f.onEvent(Event.fromJson(m[2] as Map<String, dynamic>));
            return;
          }
          if (m[1] != subId) return;
          final e = Event.fromJson(m[2] as Map<String, dynamic>);
          (_sources[e.id] ??= {}).add(r.url);
          if (_sources.length > 2000) _sources.remove(_sources.keys.first);
          if (_seen.add(e.id) && !_events.isClosed) {
            if (_seen.length > 5000) _seen.remove(_seen.first);
            _events.add(e);
          }
        case 'EOSE':
          final f = m.length > 1 ? _fetches[m[1]] : null;
          if (f != null) {
            if (!f.done.isCompleted) f.done.complete();
            return;
          }
          if (m.length > 1 && m[1] == _probeId) {
            _send(r, jsonEncode(['CLOSE', _probeId]), queue: false);
            return;
          }
          if (!r.eose) {
            r.eose = true;
            onSynced?.call(r.url, r.reqAt);
            _notify();
          }
        case 'OK':
          final id = m[1] as String;
          final ok = m[2] == true;
          if (ok) {
            (_okBy[id] ??= {}).add(r.url);
            if (_okBy.length > 2000) _okBy.remove(_okBy.keys.first);
          } else {
            final why = m.length > 3 ? '${m[3]}' : '';
            (_rejected[id] ??= {})[r.url] = why;
            onReject?.call(id, r.url, why);
            if (_rejected.length > 2000) _rejected.remove(_rejected.keys.first);
            // Отказ по одному куску вложения (размер, частота) — не «поломка» связи.
            if (!_waiters.containsKey(id) && !_sentAt.containsKey(id)) {
              r.error = why.isNotEmpty ? 'отклонил: $why' : 'отклонил событие';
              _notify();
            }
          }
          final sent = _sentAt[id];
          if (ok && sent != null) {
            final ms = DateTime.now().difference(sent).inMilliseconds.toDouble();
            final old = _latency[r.url];
            _latency[r.url] = old == null ? ms : old * 0.7 + ms * 0.3;
          }
          final w = _waiters[id];
          if (w != null && w.targets.contains(r.url)) {
            w.answered.add(r.url);
            if (ok) w.accepted.add(r.url);
            if (w.answered.length >= w.targets.length || w.accepted.length >= w.want) {
              _finishWaiter(id);
            }
          }
          final c = _pendingOk[id];
          if (ok && c != null && !c.isCompleted) {
            c.complete(true);
            _pendingOk.remove(id);
          }
        case 'CLOSED':
          final f = m.length > 1 ? _fetches[m[1]] : null;
          if (f != null) {
            if (!f.done.isCompleted) f.done.complete();
            return;
          }
          if (m.length > 1 && m[1] == _probeId) return;
          r.error = m.length > 2 ? '${m[2]}' : '${m.last}';
          _notify();
        case 'NOTICE':
          r.error = m.length > 1 ? '${m[1]}' : 'notice';
          _notify();
      }
    } catch (_) {}
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Какие ретрансляторы приняли событие (OK) и какие прислали его обратно.
  Set<String> acceptedBy(String id) => _okBy[id] ?? {};
  Set<String> deliveredBy(String id) => _sources[id] ?? {};

  /// Дождаться, пока все ретрансляторы отдадут накопленное (EOSE) или окажутся
  /// недоступны. Иначе можно уйти раньше, чем медленный, но единственный
  /// хранящий сообщение ретранслятор успеет его отдать.
  Future<void> waitEose(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      final rs = _relays.values;
      final settled = rs.every((r) => r.eose || (r.state == RelayState.offline && r.attempt > 0));
      if (rs.any((r) => r.eose) && settled) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _drop(_Relay r) {
    r.gen++;
    r.retry?.cancel();
    r.sub?.cancel();
    try {
      r.ch?.sink.close();
    } catch (_) {}
  }

  Future<void> close() async {
    _closed = true;
    _health?.cancel();
    for (final r in _relays.values) {
      _drop(r);
    }
    for (final c in _pendingOk.values) {
      if (!c.isCompleted) c.complete(false);
    }
    for (final id in _waiters.keys.toList()) {
      _finishWaiter(id);
    }
    for (final f in _fetches.values) {
      if (!f.done.isCompleted) f.done.complete();
    }
    await _events.close();
    await _changes.close();
  }
}

class _Waiter {
  _Waiter(this.targets, this.want);

  final Set<String> targets;
  final int want;
  final Set<String> answered = {};
  final Set<String> accepted = {};
  final done = Completer<Set<String>>();
  Timer? timer;
}

class _Fetch {
  _Fetch(this.url, this.onEvent, this.gen);

  final String url;
  final void Function(Event e) onEvent;
  final int gen;
  final done = Completer<void>();
  DateTime last = DateTime.now();
}
