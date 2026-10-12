import 'dart:convert';
import 'dart:io';

/// Мини-ретранслятор Nostr для тестов: хранит события, отдаёт по фильтрам,
/// рассылает новые подписчикам. Эфемерные (20000–29999) не хранит.
class FakeRelay {
  late final HttpServer _server;
  final List<Map<String, dynamic>> stored = [];
  final Map<WebSocket, Map<String, List<Map<String, dynamic>>>> _subs = {};
  int published = 0;

  int get port => _server.port;

  Future<void> start() => startOn(0);

  Future<void> startOn(int port) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      _subs[ws] = {};
      ws.listen((raw) => _on(ws, raw as String), onDone: () => _subs.remove(ws));
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
    if (f['kinds'] is List && !(f['kinds'] as List).contains(e['kind'])) return false;
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
        _subs[ws]![id] = filters;
        for (final e in stored) {
          if (filters.any((f) => _match(f, e))) ws.add(jsonEncode(['EVENT', id, e]));
        }
        ws.add(jsonEncode(['EOSE', id]));
      case 'EVENT':
        final e = m[1] as Map<String, dynamic>;
        published++;
        final kind = e['kind'] as int;
        if (kind < 20000 || kind >= 30000) stored.add(e);
        ws.add(jsonEncode(['OK', e['id'], true, '']));
        for (final entry in _subs.entries) {
          for (final sub in entry.value.entries) {
            if (sub.value.any((f) => _match(f, e))) {
              try {
                entry.key.add(jsonEncode(['EVENT', sub.key, e]));
              } catch (_) {}
            }
          }
        }
      case 'CLOSE':
        _subs[ws]?.remove(m[1]);
    }
  }
}
