@Tags(['network'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil/core/media.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/relay_pool.dart';

import 'network_test.dart' show candidateRelays;

/// Диагностика для вложений: принимает ли каждый ретранслятор куски файла и
/// по какому фильтру их отдаёт обратно. Только печатает результат.
///   VEIL_NETWORK_TEST=1 flutter test test/media_probe_test.dart
void main() {
  final enabled = Platform.environment['VEIL_NETWORK_TEST'] == '1';

  test(
    'куски файла: приём и выдача по разным фильтрам',
    () async {
      final lines = await Future.wait([
        for (final url in [...defaultRelays, ...candidateRelays]) _probe(url),
      ]);
      // ignore: avoid_print
      print(lines.join('\n'));
    },
    skip: enabled ? false : 'нужен интернет (VEIL_NETWORK_TEST=1)',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

Future<String> _probe(String url) async {
  final name = url.replaceFirst('wss://', '');
  WebSocket ws;
  try {
    ws = await WebSocket.connect(url).timeout(const Duration(seconds: 12));
  } catch (e) {
    return '$name: нет соединения';
  }
  final ok = <String, Completer<String>>{};
  final subs = <String, (Set<String>, Completer<String>)>{};
  ws.listen((raw) {
    try {
      final m = jsonDecode(raw as String) as List;
      switch (m[0]) {
        case 'OK':
          ok[m[1]]?.complete(m[2] == true ? 'ok' : 'нет: ${m[3]}');
        case 'EVENT':
          subs[m[1]]?.$1.add((m[2] as Map)['id'] as String);
        case 'EOSE':
          final s = subs[m[1]];
          if (s != null && !s.$2.isCompleted) s.$2.complete('${s.$1.length}');
        case 'CLOSED':
          final s = subs[m[1]];
          if (s != null && !s.$2.isCompleted) s.$2.complete('закрыл: ${m.length > 2 ? m[2] : ''}');
      }
    } catch (_) {}
  }, onError: (_) {});

  final signer = Keys.generate();
  final key = randomBytes(32);
  final events = [
    for (var i = 0; i < 2; i++) MediaCodec.seal(signer, key, i, randomBytes(MediaCodec.chunkSize)),
    // Мелкий кусок (для «урезанных» мобильных сетей) — номер в теге `s`.
    MediaCodec.seal(signer, key, 0, randomBytes(MediaCodec.smallChunk), small: true),
  ];
  final accepted = <String>[];
  for (final e in events) {
    final c = ok[e.id] = Completer();
    ws.add(jsonEncode(['EVENT', e.toJson()]));
    accepted.add(
      await c.future.timeout(const Duration(seconds: 15), onTimeout: () => 'нет ответа'),
    );
  }
  await Future<void>.delayed(const Duration(seconds: 1));

  Future<String> query(String id, Map<String, dynamic> filter) async {
    final c = Completer<String>();
    subs[id] = (<String>{}, c);
    ws.add(jsonEncode(['REQ', id, filter]));
    final r = await c.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => 'таймаут (${subs[id]!.$1.length})',
    );
    ws.add(jsonEncode(['CLOSE', id]));
    return r;
  }

  final ids = [for (final e in events) e.id];
  final results = {
    'ids': await query('a', {'ids': ids}),
    '#p': await query('b', {
      'kinds': [1059],
      '#p': [signer.pub],
    }),
    '#p+#c': await query('c', {
      'kinds': [1059],
      '#p': [signer.pub],
      '#c': ['1'],
    }),
    '#p+#s': await query('e', {
      'kinds': [1059],
      '#p': [signer.pub],
      '#s': ['0'],
    }),
    'authors': await query('d', {
      'kinds': [1059],
      'authors': [signer.pub],
    }),
  };
  await ws.close();
  return '$name: приём ${accepted.join(', ')} | выдача ${results.entries.map((e) => '${e.key}=${e.value}').join('  ')}';
}
