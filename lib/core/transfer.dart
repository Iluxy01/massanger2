import 'dart:convert';

import '../models/models.dart';

/// Не получилось перенести аккаунт.
class TransferError implements Exception {
  TransferError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// QR-код переноса аккаунта на новый телефон.
///
/// Старый телефон кладёт на ретрансляторы один зашифрованный пакет (ключ,
/// профиль, друзья, переписка, настройки — как в резервной копии, но без
/// фото и файлов) и показывает этот код. В коде — где лежат куски, ключ
/// расшифровки и хэш для проверки. Ретрансляторы видят только шифр; код —
/// единственный способ его открыть, поэтому показывать его можно только себе.
class TransferTicket {
  TransferTicket({
    required this.key,
    required this.signer,
    required this.chunks,
    required this.chunkSize,
    required this.size,
    required this.sha,
    required this.relays,
  });

  factory TransferTicket.of(Attachment a) => TransferTicket(
    key: a.key,
    signer: a.signer,
    chunks: a.chunks,
    chunkSize: a.chunkSize,
    size: a.size,
    sha: a.sha,
    relays: a.relays.take(4).toList(),
  );

  final String key;
  final String signer;
  final int chunks;
  final int chunkSize;
  final int size;
  final String sha;
  final List<String> relays;

  static const scheme = 'veil://move';

  /// Описание пакета — в том виде, в каком его скачивает [MediaEngine].
  Attachment get attachment => Attachment(
    name: 'veil-move',
    mime: 'application/octet-stream',
    size: size,
    sha: sha,
    key: key,
    signer: signer,
    chunks: chunks,
    chunkSize: chunkSize,
    relays: relays,
    scheme: 1,
  );

  String encode() {
    final k = base64Url.encode(base64.decode(key)).replaceAll('=', '');
    final r = relays.map((u) => u.replaceFirst('wss://', '')).join(',');
    return '$scheme?v=1&k=$k&s=$signer&n=$chunks&c=$chunkSize&z=$size&h=$sha'
        '&r=${Uri.encodeComponent(r)}';
  }

  /// Разобрать код; null — это не код переноса Veil (или он повреждён).
  static TransferTicket? parse(String raw) {
    final t = raw.trim();
    if (!t.startsWith('$scheme?')) return null;
    try {
      final q = Uri.parse(t.replaceFirst(scheme, 'veil://move/')).queryParameters;
      final k = q['k']!;
      final key = base64.encode(base64Url.decode(k.padRight((k.length + 3) ~/ 4 * 4, '=')));
      final signer = q['s']!;
      final sha = q['h']!;
      final hex = RegExp(r'^[0-9a-f]{64}$');
      if (base64.decode(key).length != 32 || !hex.hasMatch(signer) || !hex.hasMatch(sha)) {
        return null;
      }
      final chunks = int.parse(q['n']!), chunkSize = int.parse(q['c']!), size = int.parse(q['z']!);
      if (chunks <= 0 || chunkSize <= 0 || size < 0) return null;
      final relays = [
        for (final r in (q['r'] ?? '').split(','))
          if (r.trim().isNotEmpty) r.contains('://') ? r.trim() : 'wss://${r.trim()}',
      ];
      return TransferTicket(
        key: key,
        signer: signer,
        chunks: chunks,
        chunkSize: chunkSize,
        size: size,
        sha: sha,
        relays: relays,
      );
    } catch (_) {
      return null;
    }
  }
}
