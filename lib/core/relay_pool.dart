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
  'wss://offchain.pub',
  'wss://relay.snort.social',
  'wss://nostr-pub.wellorder.net',
  'wss://nostr.oxtr.dev',
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
}

/// Пул WebSocket-соединений с ретрансляторами: переподключение, очередь,
/// одна общая подписка, дедупликация входящих событий.
class RelayPool {
  RelayPool(List<String> urls, {Connector? connector})
    : _connector = connector ?? ((u) => WebSocketChannel.connect(u)) {
    setUrls(urls);
  }

  final Connector _connector;
  final Map<String, _Relay> _relays = {};
  List<Map<String, dynamic>> _filters = [];
  final _seen = <String>{};
  final _events = StreamController<Event>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final Map<String, Completer<bool>> _pendingOk = {};
  final Map<String, int> _okCount = {};
  final Map<String, Set<String>> _okBy = {};
  final Map<String, Set<String>> _sources = {};
  bool _closed = false;
  bool _started = false;

  static const subId = 'veil';

  Stream<Event> get events => _events.stream;
  Stream<void> get changes => _changes.stream;

  List<String> get urls => _relays.keys.toList();
  int get onlineCount => _relays.values.where((r) => r.state == RelayState.online).length;
  RelayState stateOf(String url) => _relays[url]?.state ?? RelayState.offline;
  String? errorOf(String url) => _relays[url]?.error;
  bool get allEose =>
      _relays.values.every((r) => r.eose || r.state == RelayState.offline && r.attempt > 0);

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
    _started = true;
    for (final r in _relays.values) {
      if (r.state == RelayState.offline) _connect(r);
    }
  }

  /// Переподключить «уснувшие» соединения (например, после выхода из фона).
  void wake() {
    for (final r in _relays.values) {
      if (r.state != RelayState.online) {
        r.retry?.cancel();
        r.attempt = 0;
        _connect(r);
      }
    }
  }

  void subscribe(List<Map<String, dynamic>> filters) {
    _filters = filters;
    // Новый запрос — события снова можно получить (если раньше их не удалось обработать).
    _seen.clear();
    for (final r in _relays.values) {
      r.eose = false;
      if (r.state == RelayState.online) _sendReq(r);
    }
  }

  void _sendReq(_Relay r) => _send(r, jsonEncode(['REQ', subId, ..._filters]), queue: false);

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

  void _send(_Relay r, String msg, {required bool queue}) {
    if (r.state == RelayState.online && r.ch != null) {
      try {
        r.ch!.sink.add(msg);
        return;
      } catch (_) {}
    }
    if (queue && r.queue.length < 200) r.queue.add(msg);
  }

  Future<void> _connect(_Relay r) async {
    if (_closed) return;
    r.state = RelayState.connecting;
    _notify();
    try {
      final ch = _connector(Uri.parse(r.url));
      r.ch = ch;
      await ch.ready.timeout(const Duration(seconds: 12));
      if (_closed || !_relays.containsKey(r.url)) {
        ch.sink.close();
        return;
      }
      r.state = RelayState.online;
      r.error = null;
      r.attempt = 0;
      _notify();
      r.sub = ch.stream.listen(
        (m) => _onMessage(r, m),
        onDone: () => _lost(r, 'соединение закрыто'),
        onError: (Object e) => _lost(r, '$e'),
      );
      if (_filters.isNotEmpty) _sendReq(r);
      final q = List.of(r.queue);
      r.queue.clear();
      for (final m in q) {
        _send(r, m, queue: true);
      }
    } catch (e) {
      _lost(r, '$e');
    }
  }

  void _lost(_Relay r, String why) {
    r.sub?.cancel();
    r.sub = null;
    try {
      r.ch?.sink.close();
    } catch (_) {}
    r.ch = null;
    r.state = RelayState.offline;
    r.error = why.length > 120 ? why.substring(0, 120) : why;
    r.attempt++;
    _notify();
    if (_closed || !_relays.containsKey(r.url)) return;
    final delay = Duration(seconds: [2, 4, 8, 15, 30, 60][r.attempt.clamp(1, 6) - 1]);
    r.retry?.cancel();
    r.retry = Timer(delay, () => _connect(r));
  }

  void _onMessage(_Relay r, dynamic raw) {
    try {
      final m = jsonDecode(raw as String) as List;
      switch (m[0]) {
        case 'EVENT':
          if (m.length < 3 || m[1] != subId) return;
          final e = Event.fromJson(m[2] as Map<String, dynamic>);
          (_sources[e.id] ??= {}).add(r.url);
          if (_sources.length > 2000) _sources.remove(_sources.keys.first);
          if (_seen.add(e.id) && !_events.isClosed) {
            if (_seen.length > 5000) _seen.remove(_seen.first);
            _events.add(e);
          }
        case 'EOSE':
          r.eose = true;
          _notify();
        case 'OK':
          final id = m[1] as String;
          final ok = m[2] == true;
          if (ok) {
            _okCount[id] = (_okCount[id] ?? 0) + 1;
            (_okBy[id] ??= {}).add(r.url);
            if (_okBy.length > 2000) _okBy.remove(_okBy.keys.first);
          } else {
            r.error = m.length > 3 ? 'отклонил: ${m[3]}' : 'отклонил событие';
            _notify();
          }
          final c = _pendingOk[id];
          if (ok && c != null && !c.isCompleted) {
            c.complete(true);
            _pendingOk.remove(id);
          }
        case 'CLOSED':
        case 'NOTICE':
          r.error = m.length > 2 ? '${m[2]}' : '${m.last}';
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

  /// Сколько ретрансляторов подтвердили событие.
  int acks(String id) => _okCount[id] ?? 0;

  /// Дождаться, пока все доступные ретрансляторы отдадут накопленное (EOSE).
  Future<void> waitEose(Duration timeout) async {
    final end = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(end)) {
      // Ждём, пока все ретрансляторы либо ответят полностью (EOSE), либо
      // окажутся недоступны. Иначе можно уйти раньше, чем медленный, но
      // единственный хранящий сообщение ретранслятор успеет его отдать.
      final rs = _relays.values;
      final settled = rs.every((r) => r.eose || (r.state == RelayState.offline && r.attempt > 0));
      if (rs.any((r) => r.eose) && settled) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  void _drop(_Relay r) {
    r.retry?.cancel();
    r.sub?.cancel();
    try {
      r.ch?.sink.close();
    } catch (_) {}
  }

  Future<void> close() async {
    _closed = true;
    for (final r in _relays.values) {
      _drop(r);
    }
    for (final c in _pendingOk.values) {
      if (!c.isCompleted) c.complete(false);
    }
    await _events.close();
    await _changes.close();
  }
}
