@Tags(['network'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/relay_pool.dart';

/// Разведка для вложений: какой размер события принимает каждый ретранслятор
/// и сколько крупных событий подряд он выдерживает. Только печатает результат.
///   VEIL_NETWORK_TEST=1 flutter test test/media_probe_test.dart
void main() {
  final enabled = Platform.environment['VEIL_NETWORK_TEST'] == '1';

  test(
    'размеры и скорость крупных событий',
    () async {
      final keys = Keys.generate();
      final target = Keys.generate().pub;
      final results = await Future.wait([
        for (final url in defaultRelays) _probe(url, keys, target),
      ]);
      for (final r in results) {
        // ignore: avoid_print
        print(r);
      }
    },
    skip: enabled ? false : 'нужен интернет (VEIL_NETWORK_TEST=1)',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}

String _blob(int n) {
  final b = randomBytes((n * 3) ~/ 4 + 3);
  return base64.encode(b).substring(0, n);
}

Future<String> _probe(String url, Keys keys, String target) async {
  final out = StringBuffer('── $url\n');
  WebSocket ws;
  try {
    ws = await WebSocket.connect(url).timeout(const Duration(seconds: 12));
  } catch (e) {
    return '$out  нет соединения: $e';
  }
  final oks = <String, Completer<(bool, String)>>{};
  final got = <String>{};
  final eose = <String, Completer<void>>{};
  final sentIds = <String>{};
  ws.listen(
    (raw) {
      try {
        final m = jsonDecode(raw as String) as List;
        if (m[0] == 'OK') oks[m[1]]?.complete((m[2] == true, '${m[3]}'));
        if (m[0] == 'EVENT') got.add((m[2] as Map)['id'] as String);
        if (m[0] == 'EOSE') eose[m[1]]?.complete();
      } catch (_) {}
    },
    onError: (_) {},
    onDone: () {},
  );

  Future<(bool, String)> send(int size) async {
    final e = Event.signed(
      keys,
      kind: 1059,
      content: _blob(size),
      tags: [
        ['p', target],
        ['expiration', '${nowSec() + 3600}'],
      ],
    );
    final c = oks[e.id] = Completer();
    try {
      ws.add(jsonEncode(['EVENT', e.toJson()]));
    } catch (err) {
      return (false, 'сокет: $err');
    }
    final r = await c.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => (false, 'нет ответа'),
    );
    if (r.$1) sentIds.add(e.id);
    return r;
  }

  for (final size in [16000, 32000, 48000, 64000, 90000, 120000, 200000]) {
    final r = await send(size);
    out.writeln('  ${size ~/ 1000} КБ: ${r.$1 ? 'принят' : 'НЕТ'} ${r.$2}');
    if (ws.closeCode != null) {
      out.writeln('  соединение закрыто: ${ws.closeCode} ${ws.closeReason}');
      return out.toString();
    }
  }

  // Поток: 20 событий по 40 КБ подряд, каждое — после ответа на предыдущее.
  final sw = Stopwatch()..start();
  var ok = 0;
  final reasons = <String>{};
  for (var i = 0; i < 20; i++) {
    final r = await send(40000);
    if (r.$1) {
      ok++;
    } else {
      reasons.add(r.$2);
    }
    if (ws.closeCode != null) break;
  }
  out.writeln(
    '  поток 20×40 КБ: принято $ok за ${sw.elapsedMilliseconds} мс ${reasons.join(' | ')}',
  );

  // Отдаёт ли обратно по id.
  final ids = sentIds.toList();
  final sub = eose['q'] = Completer();
  try {
    ws.add(
      jsonEncode([
        'REQ',
        'q',
        {'ids': ids},
      ]),
    );
    await sub.future.timeout(const Duration(seconds: 20));
  } catch (_) {}
  out.writeln('  отдал по id: ${got.length} из ${ids.length}');
  await ws.close();
  return out.toString();
}
