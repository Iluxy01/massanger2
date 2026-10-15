import 'dart:convert';
import 'dart:io';

/// Мини-ретранслятор Nostr для тестов: хранит события, отдаёт по фильтрам,
/// рассылает новые подписчикам. Эфемерные (20000–29999) не хранит.
class FakeRelay {
  late HttpServer _server;
  final List<Map<String, dynamic>> stored = [];
  final Map<WebSocket, Map<String, List<Map<String, dynamic>>>> _subs = {};
  int published = 0;

  /// «Замёрз»: соединение открыто, но ни на что не отвечает (как при тихом
  /// обрыве в мобильной сети).
  bool frozen = false;

  /// Предел размера события (как у настоящих: многие не берут больше 64 КБ).
  int maxEventBytes = 1 << 30;

  /// Не обслуживать запросы конвертов (kind 1059) по автору — как некоторые
  /// настоящие ретрансляторы, оберегающие личные сообщения.
  bool noAuthorQueries = false;

  /// Отказывать в приёме событий крупнее этого размера с такой причиной.
  String? rejectBig;
  int rejectBigOver = 1 << 30;

  /// «Урезанная» мобильная сеть: соединения, открытые по пути `/m`, замолкают
  /// навсегда, как только ретранслятор отправил по ним больше [tightBytes]
  /// (так ведут себя соединения с зарубежными серверами в мобильных сетях России).
  int tightBytes = 14 * 1024;
  final Set<WebSocket> _tight = {};
  final Map<WebSocket, int> _sent = {};

  /// Сколько соединений «замёрзло» на лимите.
  int frozenByLimit = 0;

  /// Не смотреть на фильтры по тегам (кроме #p) — как relay.snort.social.
  bool ignoreTagFilters = false;

  int get port => _server.port;

  void _send(WebSocket ws, String text) {
    if (_tight.contains(ws)) {
      final before = _sent[ws] ?? 0;
      if (before > tightBytes) return;
      final after = before + text.length;
      _sent[ws] = after;
      if (after > tightBytes) {
        frozenByLimit++;
        return; // данные «застряли» — дальше по этому соединению ничего не придёт
      }
    }
    ws.add(text);
  }

  Future<void> start() => startOn(0);

  Future<void> startOn(int port) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server.listen((req) async {
      final tight = req.uri.path == '/m';
      final ws = await WebSocketTransformer.upgrade(req);
      _subs[ws] = {};
      if (tight) _tight.add(ws);
      ws.listen(
        (raw) => _on(ws, raw as String),
        onDone: () {
          _subs.remove(ws);
          _tight.remove(ws);
          _sent.remove(ws);
        },
      );
    });
  }

  Future<void> stop() async {
    for (final ws in _subs.keys.toList()) {
      await ws.close();
    }
    await _server.close(force: true);
  }

  /// Оборвать все соединения (проверка переподключения).
  Future<void> dropAll() async {
    for (final ws in _subs.keys.toList()) {
      await ws.close();
    }
  }

  bool _match(Map<String, dynamic> f, Map<String, dynamic> e) {
    if (f['ids'] is List && !(f['ids'] as List).contains(e['id'])) return false;
    if (f['authors'] is List && !(f['authors'] as List).contains(e['pubkey'])) return false;
    if (f['kinds'] is List && !(f['kinds'] as List).contains(e['kind'])) return false;
    for (final entry in f.entries) {
      if (entry.key.length == 2 &&
          entry.key.startsWith('#') &&
          entry.key != '#p' &&
          !ignoreTagFilters) {
        final name = entry.key.substring(1);
        final vals = [
          for (final t in e['tags'] as List)
            if ((t as List).first == name && t.length > 1) t[1],
        ];
        if (!(entry.value as List).any(vals.contains)) return false;
      }
    }
    if (f['since'] is num && (e['created_at'] as num) < (f['since'] as num)) return false;
    if (f['#p'] is List) {
      final ps = [
        for (final t in e['tags'] as List)
          if ((t as List).first == 'p') t[1],
      ];
      if (!(f['#p'] as List).any(ps.contains)) return false;
    }
    return true;
  }

  void _on(WebSocket ws, String raw) {
    if (frozen) return;
    try {
      _handle(ws, raw);
    } catch (_) {
      // Сокет уже закрыт — как у настоящего ретранслятора, просто теряем.
    }
  }

  void _handle(WebSocket ws, String raw) {
    final m = jsonDecode(raw) as List;
    switch (m[0]) {
      case 'REQ':
        final id = m[1] as String;
        final filters = [for (final f in m.skip(2)) f as Map<String, dynamic>];
        if (noAuthorQueries && filters.any((f) => f['authors'] != null)) {
          _send(ws, jsonEncode(['CLOSED', id, 'restricted: gift wraps only by #p']));
          return;
        }
        _subs[ws]![id] = filters;
        final limit = filters.length == 1 && filters.first['limit'] is int
            ? filters.first['limit'] as int
            : 1 << 30;
        var sent = 0;
        for (final e in stored) {
          if (sent >= limit) break;
          if (filters.any((f) => _match(f, e))) {
            _send(ws, jsonEncode(['EVENT', id, e]));
            sent++;
          }
        }
        _send(ws, jsonEncode(['EOSE', id]));
      case 'EVENT':
        final e = m[1] as Map<String, dynamic>;
        published++;
        if (raw.length > maxEventBytes) {
          _send(ws, jsonEncode(['OK', e['id'], false, 'invalid: event too large: ${raw.length}']));
          return;
        }
        if (rejectBig != null && raw.length > rejectBigOver) {
          _send(ws, jsonEncode(['OK', e['id'], false, rejectBig]));
          return;
        }
        final kind = e['kind'] as int;
        if (kind < 20000 || kind >= 30000) stored.add(e);
        _send(ws, jsonEncode(['OK', e['id'], true, '']));
        for (final entry in _subs.entries) {
          for (final sub in entry.value.entries) {
            if (sub.value.any((f) => _match(f, e))) {
              try {
                _send(entry.key, jsonEncode(['EVENT', sub.key, e]));
              } catch (_) {}
            }
          }
        }
      case 'CLOSE':
        _subs[ws]?.remove(m[1]);
    }
  }
}
