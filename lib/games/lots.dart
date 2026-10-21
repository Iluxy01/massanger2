import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../core/nostr.dart';

/// Честный жребий: кубик, монетка, «камень-ножницы-бумага».
///
/// Кубик и монетка: создатель заранее отправляет хэш своего случайного числа
/// (обязательство), телефон второго сам отвечает своим числом, после чего
/// телефон создателя раскрывает своё. Итог — хэш обоих чисел: подогнать его
/// не может ни один, а подмену числа видно по хэшу.
/// Ходы: `1<число>` — ответ второго, `0<число>` — раскрытие создателя.
///
/// «Камень-ножницы-бумага»: создатель отправляет хэш своего выбора, второй
/// выбирает открыто (`1r`), создатель раскрывает (`0r|соль`).
class Lot {
  Lot._(this.type, this.commit);

  final String type;
  final String? commit;
  String? r0, r1;

  /// Подмена: раскрытое не сходится с обязательством.
  bool cheat = false;

  /// Кубик: 1–6; монетка: 0 — орёл, 1 — решка; КНБ: 0 / 1 — кто победил, 2 — ничья.
  int? result;

  /// КНБ: выборы (r/p/s).
  String? pick0, pick1;

  static const rps = {'r': '✊', 'p': '✋', 's': '✌️'};

  static String random() => hexEncode(List.generate(16, (_) => Random.secure().nextInt(256)));

  static String hash(String s) => sha256.convert(utf8.encode('veil-lot|$s')).toString();

  factory Lot.replay(String type, String? commit, List<String> moves) {
    final g = Lot._(type, commit);
    for (final m in moves) {
      g._apply(m);
    }
    return g;
  }

  /// Ждём ответа второго игрока.
  bool get awaitingSecond => r1 == null && pick1 == null;

  /// Ждём раскрытия создателя.
  bool get awaitingReveal => !awaitingSecond && result == null && !cheat;

  void _apply(String m) {
    if (m.length < 2) throw const FormatException('ход');
    final role = int.tryParse(m[0]);
    final body = m.substring(1);
    if (role == 1) {
      if (!awaitingSecond) throw const FormatException('уже ответил');
      if (type == 'rps') {
        if (!rps.containsKey(body)) throw const FormatException('выбор');
        pick1 = body;
      } else {
        if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(body)) throw const FormatException('число');
        r1 = body;
      }
      return;
    }
    if (role != 0 || !awaitingReveal) throw const FormatException('раскрытие');
    if (hash(body) != commit) {
      cheat = true;
      return;
    }
    if (type == 'rps') {
      final p = body.split('|').first;
      if (!rps.containsKey(p)) {
        cheat = true;
        return;
      }
      pick0 = p;
      const beats = {'r': 's', 's': 'p', 'p': 'r'};
      result = pick0 == pick1 ? 2 : (beats[pick0] == pick1 ? 0 : 1);
    } else {
      r0 = body;
      final h = sha256.convert(utf8.encode('$r0$r1')).toString();
      final n = int.parse(h.substring(0, 8), radix: 16);
      result = type == 'dice' ? n % 6 + 1 : n % 2;
    }
  }
}
