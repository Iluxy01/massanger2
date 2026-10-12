import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart';

final _rnd = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rnd.nextInt(256)));

String hexEncode(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexDecode(String s) {
  if (s.length.isOdd) throw const FormatException('hex');
  return Uint8List.fromList([
    for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
  ]);
}

final _hex64 = RegExp(r'^[0-9a-f]{64}$');

bool isPubkey(String s) => _hex64.hasMatch(s);

/// Пара ключей secp256k1 (как в Nostr). Публичный ключ — x-координата, 32 байта hex.
class Keys {
  Keys(this.priv) : pub = bip340.getPublicKey(priv);

  factory Keys.generate() {
    while (true) {
      final k = hexEncode(randomBytes(32));
      // Ключ должен быть в диапазоне [1, n-1]; вероятность промаха ничтожна.
      try {
        return Keys(k);
      } catch (_) {}
    }
  }

  final String priv;
  final String pub;
}

/// Событие Nostr (NIP-01).
class Event {
  Event({
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    this.id = '',
    this.sig = '',
  });

  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  String id;
  String sig;

  static String computeId(
    String pubkey,
    int createdAt,
    int kind,
    List<List<String>> tags,
    String content,
  ) {
    final data = jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    return sha256.convert(utf8.encode(data)).toString();
  }

  /// Создать и подписать событие.
  factory Event.signed(
    Keys keys, {
    required int kind,
    required String content,
    List<List<String>> tags = const [],
    int? createdAt,
  }) {
    final ts = createdAt ?? nowSec();
    final e = Event(pubkey: keys.pub, createdAt: ts, kind: kind, tags: tags, content: content);
    e.id = computeId(keys.pub, ts, kind, tags, content);
    e.sig = bip340.sign(keys.priv, e.id, hexEncode(randomBytes(32)));
    return e;
  }

  /// Неподписанное событие («rumor» из NIP-59) — у него есть id, но нет подписи.
  factory Event.unsigned(
    String pubkey, {
    required int kind,
    required String content,
    List<List<String>> tags = const [],
  }) {
    final ts = nowSec();
    final e = Event(pubkey: pubkey, createdAt: ts, kind: kind, tags: tags, content: content);
    e.id = computeId(pubkey, ts, kind, tags, content);
    return e;
  }

  bool get idValid => id == computeId(pubkey, createdAt, kind, tags, content);

  bool verify() {
    if (!idValid || sig.length != 128) return false;
    try {
      return bip340.verify(pubkey, id, sig);
    } catch (_) {
      return false;
    }
  }

  String? tag(String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    if (sig.isNotEmpty) 'sig': sig,
  };

  factory Event.fromJson(Map<String, dynamic> j) => Event(
    id: j['id'] as String? ?? '',
    pubkey: j['pubkey'] as String,
    createdAt: (j['created_at'] as num).toInt(),
    kind: (j['kind'] as num).toInt(),
    tags: [
      for (final t in j['tags'] as List) [for (final x in t as List) x.toString()],
    ],
    content: j['content'] as String,
    sig: j['sig'] as String? ?? '',
  );
}

int nowSec() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
