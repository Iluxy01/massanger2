import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'bip39_words.dart';
import 'nostr.dart';

/// Почему не получилось прочитать ключ восстановления.
class RecoveryError implements Exception {
  RecoveryError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Ключ восстановления — тот же секретный ключ аккаунта, записанный словами.
///
/// 24 слова из стандартного списка BIP39: 256 бит ключа + 8 бит контрольной
/// суммы (первый байт SHA-256 ключа). Опечатку в любом слове видно сразу —
/// не сойдётся сумма. Слово узнаётся по первым четырём буквам.
///
/// Также понимаем `nsec1…` (NIP-19) — так ключ записывают другие приложения
/// Nostr.
class Recovery {
  Recovery._();

  static const wordCount = 24;
  static final _index = {for (var i = 0; i < bip39Words.length; i++) bip39Words[i]: i};
  static final _byPrefix = {
    for (var i = 0; i < bip39Words.length; i++)
      bip39Words[i].substring(0, bip39Words[i].length.clamp(0, 4)): i,
  };

  /// Секретный ключ (64 hex) → 24 слова.
  static List<String> toWords(String priv) {
    final key = hexDecode(priv);
    if (key.length != 32) throw ArgumentError('ключ — 32 байта');
    final check = sha256.convert(key).bytes.first;
    final bits = StringBuffer();
    for (final b in [...key, check]) {
      bits.write(b.toRadixString(2).padLeft(8, '0'));
    }
    final s = bits.toString();
    return [
      for (var i = 0; i < wordCount; i++)
        bip39Words[int.parse(s.substring(i * 11, i * 11 + 11), radix: 2)],
    ];
  }

  /// Какое это слово списка (по целому слову или первым четырём буквам).
  static int? wordIndex(String w) {
    final x = w.trim().toLowerCase();
    if (x.isEmpty) return null;
    return _index[x] ?? (x.length >= 4 ? _byPrefix[x.substring(0, 4)] : null);
  }

  /// Подсказка при вводе: слова списка, начинающиеся так.
  static List<String> suggest(String prefix, {int max = 4}) {
    final p = prefix.trim().toLowerCase();
    if (p.isEmpty) return const [];
    return bip39Words.where((w) => w.startsWith(p)).take(max).toList();
  }

  /// Слова → секретный ключ (64 hex). Бросает [RecoveryError].
  static String fromWords(List<String> words) {
    final list = words.where((w) => w.trim().isNotEmpty).toList();
    if (list.length != wordCount) {
      throw RecoveryError('Нужно $wordCount слова, а сейчас ${list.length}');
    }
    final bits = StringBuffer();
    for (var i = 0; i < list.length; i++) {
      final n = wordIndex(list[i]);
      if (n == null) throw RecoveryError('Слово №${i + 1} «${list[i].trim()}» не из списка');
      bits.write(n.toRadixString(2).padLeft(11, '0'));
    }
    final s = bits.toString();
    final bytes = Uint8List(33);
    for (var i = 0; i < 33; i++) {
      bytes[i] = int.parse(s.substring(i * 8, i * 8 + 8), radix: 2);
    }
    final key = Uint8List.sublistView(bytes, 0, 32);
    if (sha256.convert(key).bytes.first != bytes[32]) {
      throw RecoveryError('Слова не сходятся — проверь, нет ли опечатки или пропуска');
    }
    return _valid(hexEncode(key));
  }

  /// Ввод пользователя: 24 слова (через пробелы, запятые, с номерами) или nsec1….
  static String parse(String input) {
    final t = input.trim();
    if (t.toLowerCase().startsWith('nsec1')) return fromNsec(t);
    final words = t
        .toLowerCase()
        .split(RegExp(r'[\s,;.]+'))
        .where((w) => w.isNotEmpty && !RegExp(r'^\d+\)?$').hasMatch(w))
        .map((w) => w.replaceAll(RegExp(r'^\d+[).:]?'), ''))
        .where((w) => w.isNotEmpty)
        .toList();
    return fromWords(words);
  }

  /// Ключ должен быть в диапазоне [1, n−1] кривой secp256k1.
  static String _valid(String priv) {
    try {
      Keys(priv);
      return priv;
    } catch (_) {
      throw RecoveryError('Это не ключ аккаунта');
    }
  }

  // ───────────────────────── nsec (NIP-19, bech32) ─────────────────────────

  static const _charset = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';

  static String toNsec(String priv) => _bech32('nsec', hexDecode(priv));

  static String fromNsec(String s) {
    final (hrp, data) = _unbech32(s.trim().toLowerCase());
    if (hrp != 'nsec' || data.length != 32) throw RecoveryError('Это не ключ nsec');
    return _valid(hexEncode(data));
  }

  static int _polymod(List<int> values) {
    const gen = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
    var chk = 1;
    for (final v in values) {
      final top = chk >> 25;
      chk = (chk & 0x1ffffff) << 5 ^ v;
      for (var i = 0; i < 5; i++) {
        if ((top >> i) & 1 == 1) chk ^= gen[i];
      }
    }
    return chk;
  }

  static List<int> _hrpExpand(String hrp) => [
    for (final c in hrp.codeUnits) c >> 5,
    0,
    for (final c in hrp.codeUnits) c & 31,
  ];

  static List<int> _convert(List<int> data, int from, int to, {required bool pad}) {
    var acc = 0, bits = 0;
    final out = <int>[];
    final maxv = (1 << to) - 1;
    for (final v in data) {
      if (v < 0 || v >> from != 0) throw RecoveryError('Ключ повреждён');
      acc = (acc << from) | v;
      bits += from;
      while (bits >= to) {
        bits -= to;
        out.add((acc >> bits) & maxv);
      }
    }
    if (pad) {
      if (bits > 0) out.add((acc << (to - bits)) & maxv);
    } else if (bits >= from || ((acc << (to - bits)) & maxv) != 0) {
      throw RecoveryError('Ключ повреждён');
    }
    return out;
  }

  static String _bech32(String hrp, List<int> bytes) {
    final data = _convert(bytes, 8, 5, pad: true);
    final mod = _polymod([..._hrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
    final check = [for (var i = 0; i < 6; i++) (mod >> 5 * (5 - i)) & 31];
    return '${hrp}1${[...data, ...check].map((d) => _charset[d]).join()}';
  }

  static (String, List<int>) _unbech32(String s) {
    final sep = s.lastIndexOf('1');
    if (sep < 1 || sep + 7 > s.length) throw RecoveryError('Ключ повреждён');
    final hrp = s.substring(0, sep);
    final data = <int>[];
    for (final c in s.substring(sep + 1).split('')) {
      final d = _charset.indexOf(c);
      if (d < 0) throw RecoveryError('В ключе лишний символ «$c»');
      data.add(d);
    }
    if (_polymod([..._hrpExpand(hrp), ...data]) != 1) {
      throw RecoveryError('Ключ не сходится — проверь, нет ли опечатки');
    }
    return (hrp, _convert(data.sublist(0, data.length - 6), 5, 8, pad: false));
  }
}
