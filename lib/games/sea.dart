import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Расстановка кораблей морского боя: поле 10×10, клетка — `ряд * 10 + столбец`.
/// Флот: 4, 3, 3, 2, 2, 2, 1, 1, 1, 1 — корабли не касаются даже углами.
class SeaLayout {
  SeaLayout(this.ships);

  static const fleet = [4, 3, 3, 2, 2, 2, 1, 1, 1, 1];
  static const cellsTotal = 20;

  /// Корабли — списки клеток.
  final List<List<int>> ships;

  Set<int> get cells => {for (final s in ships) ...s};

  List<int>? shipAt(int cell) {
    for (final s in ships) {
      if (s.contains(cell)) return s;
    }
    return null;
  }

  /// Строка для обязательства: «0,1,2,3;20,21,22;…».
  String encode() => ships.map((s) => s.join(',')).join(';');

  static SeaLayout? decode(String s) {
    try {
      final ships = [
        for (final part in s.split(';')) [for (final c in part.split(',')) int.parse(c)],
      ];
      final l = SeaLayout(ships);
      return l.valid ? l : null;
    } catch (_) {
      return null;
    }
  }

  /// По правилам ли расставлено.
  bool get valid {
    final sizes = ships.map((s) => s.length).toList()..sort((a, b) => b.compareTo(a));
    if (sizes.join() != fleet.join()) return false;
    final all = <int>{};
    for (final s in ships) {
      if (s.any((c) => c < 0 || c > 99)) return false;
      final rows = s.map((c) => c ~/ 10).toSet(), cols = s.map((c) => c % 10).toSet();
      final sorted = [...s]..sort();
      final straight = rows.length == 1
          ? Iterable.generate(sorted.length - 1).every((i) => sorted[i + 1] - sorted[i] == 1)
          : cols.length == 1 &&
                Iterable.generate(sorted.length - 1).every((i) => sorted[i + 1] - sorted[i] == 10);
      if (!straight) return false;
      // Не касаться других кораблей (и углами).
      for (final c in s) {
        for (final n in around(c)) {
          if (all.contains(n)) return false;
        }
      }
      all.addAll(s);
    }
    return true;
  }

  /// Соседние клетки (8 направлений).
  static Iterable<int> around(int c) sync* {
    final r = c ~/ 10, col = c % 10;
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr == 0 && dc == 0) continue;
        final r2 = r + dr, c2 = col + dc;
        if (r2 >= 0 && r2 < 10 && c2 >= 0 && c2 < 10) yield r2 * 10 + c2;
      }
    }
  }

  /// Случайная расстановка по правилам.
  static SeaLayout random([Random? rnd]) {
    final r = rnd ?? Random.secure();
    while (true) {
      final ships = <List<int>>[];
      final busy = <int>{};
      var ok = true;
      for (final len in fleet) {
        List<int>? placed;
        for (var attempt = 0; attempt < 200 && placed == null; attempt++) {
          final vertical = r.nextBool();
          final row = r.nextInt(vertical ? 11 - len : 10);
          final col = r.nextInt(vertical ? 10 : 11 - len);
          final cells = [
            for (var i = 0; i < len; i++) vertical ? (row + i) * 10 + col : row * 10 + col + i,
          ];
          if (cells.every((c) => !busy.contains(c) && around(c).every((n) => !busy.contains(n)))) {
            placed = cells;
          }
        }
        if (placed == null) {
          ok = false;
          break;
        }
        ships.add(placed);
        busy.addAll(placed);
      }
      if (ok) return SeaLayout(ships);
    }
  }
}

/// Обязательство: хэш расстановки с «солью» — отправляется до игры, сама
/// расстановка раскрывается в конце. Так её нельзя подменить по ходу.
String seaCommit(String layout, String salt) =>
    sha256.convert(utf8.encode('veil-sea|$layout|$salt')).toString();

/// Морской бой. Ходы:
///   `1h<хэш>` — второй игрок расставил корабли (обязательство создателя — в
///   самом сообщении);
///   `0s45` — выстрел; `1a45h` — ответ того, по кому стреляли: m мимо,
///   h ранен, k убит (отвечает его телефон сам);
///   `0v<расстановка>.<соль>` — раскрыть расстановку в конце (проверка);
///   `1!` — сдался.
/// Первым стреляет создатель; попал — стреляет ещё.
class Sea {
  Sea._(this.commit0);

  final String? commit0;
  String? commit1;

  /// Выстрелы каждой стороны: клетка → ответ (m/h/k), null — ответа ещё нет.
  final shots = [<int, String?>{}, <int, String?>{}];
  int turn = 0;

  /// Выстрел, ждущий ответа: (кто стрелял, клетка).
  (int, int)? pending;

  /// 0 / 1 — победитель, null — играем.
  int? winner;
  bool resigned = false;

  /// Раскрытые расстановки и кто из игроков отвечал нечестно.
  final revealed = <SeaLayout?>[null, null];
  final cheat = [false, false];

  bool get ready => commit0 != null && commit1 != null;

  /// Попаданий стороны [side] по противнику.
  int hits(int side) => shots[side].values.where((v) => v == 'h' || v == 'k').length;

  factory Sea.replay(String? commit0, List<String> moves) {
    final g = Sea._(commit0);
    for (final m in moves) {
      g._apply(m);
    }
    return g;
  }

  void _apply(String m) {
    if (m.length < 2) throw const FormatException('ход');
    final role = int.tryParse(m[0]);
    if (role != 0 && role != 1) throw const FormatException('роль');
    final kind = m[1], body = m.substring(2);
    switch (kind) {
      case 'h':
        if (role != 1 || commit1 != null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(body)) {
          throw const FormatException('расстановка');
        }
        commit1 = body;
      case '!':
        if (winner != null) throw const FormatException('конец');
        winner = 1 - role!;
        resigned = true;
      case 's':
        final cell = int.tryParse(body);
        if (!ready || winner != null || pending != null || role != turn) {
          throw const FormatException('не твой выстрел');
        }
        if (cell == null || cell < 0 || cell > 99 || shots[role!].containsKey(cell)) {
          throw const FormatException('клетка');
        }
        shots[role][cell] = null;
        pending = (role, cell);
      case 'a':
        final p = pending;
        if (p == null || role != 1 - p.$1 || body.length < 2) throw const FormatException('ответ');
        final cell = int.tryParse(body.substring(0, body.length - 1));
        final res = body[body.length - 1];
        if (cell != p.$2 || !'mhk'.contains(res)) throw const FormatException('ответ');
        shots[p.$1][cell!] = res;
        pending = null;
        if (res == 'm') {
          turn = 1 - p.$1;
        } else if (hits(p.$1) >= SeaLayout.cellsTotal) {
          winner = p.$1;
        }
      case 'v':
        final dot = body.lastIndexOf('.');
        if (winner == null || dot < 0 || revealed[role!] != null) {
          throw const FormatException('раскрытие');
        }
        final layout = SeaLayout.decode(body.substring(0, dot));
        final commit = role == 0 ? commit0 : commit1;
        if (layout == null || commit == null) throw const FormatException('раскрытие');
        revealed[role] = layout;
        cheat[role] =
            seaCommit(layout.encode(), body.substring(dot + 1)) != commit ||
            !_honest(layout, shots[1 - role]);
      default:
        throw const FormatException('ход');
    }
  }

  /// Сходятся ли ответы с раскрытой расстановкой.
  static bool _honest(SeaLayout layout, Map<int, String?> shotsAt) {
    final cells = layout.cells;
    final hitSoFar = <int>{};
    for (final e in shotsAt.entries) {
      final res = e.value;
      if (res == null) continue;
      final ship = layout.shipAt(e.key);
      if ((ship != null) != (res != 'm')) return false;
      if (ship != null) {
        hitSoFar.add(e.key);
        final sunk = ship.every(hitSoFar.contains);
        if ((res == 'k') != sunk) return false;
      }
    }
    return cells.isNotEmpty;
  }

  /// Ответ на выстрел по своей расстановке.
  static String answer(SeaLayout layout, Map<int, String?> shotsAtMe, int cell) {
    final ship = layout.shipAt(cell);
    if (ship == null) return 'm';
    final hit = {...shotsAtMe.keys.where((c) => shotsAtMe[c] != 'm'), cell};
    return ship.every(hit.contains) ? 'k' : 'h';
  }

  /// Клетки вокруг убитого корабля стороны [side] (по выстрелам [shooter]) —
  /// там кораблей точно нет.
  Set<int> knownEmpty(int shooter) {
    final s = shots[shooter];
    final out = <int>{};
    final hits = {
      for (final e in s.entries)
        if (e.value == 'h' || e.value == 'k') e.key,
    };
    for (final e in s.entries) {
      if (e.value != 'k') continue;
      // Собрать корабль по соседним попаданиям.
      final ship = <int>{e.key};
      final queue = [e.key];
      while (queue.isNotEmpty) {
        final c = queue.removeLast();
        for (final n in [c - 1, c + 1, c - 10, c + 10]) {
          if (n < 0 || n > 99 || ((n - c).abs() == 1 && n ~/ 10 != c ~/ 10)) continue;
          if (hits.contains(n) && ship.add(n)) queue.add(n);
        }
      }
      for (final c in ship) {
        out.addAll(SeaLayout.around(c).where((n) => !ship.contains(n)));
      }
    }
    return out;
  }
}
