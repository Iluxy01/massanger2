/// Русские шашки. Поле 8×8, клетка — `ряд * 8 + столбец`, ряд 0 — сверху
/// (сторона чёрных). Создатель играет белыми и ходит первым.
///
/// Правила: простая ходит вперёд по диагонали, бьёт и вперёд, и назад;
/// бить обязательно, взятие продолжается, пока есть кого бить (выбрать можно
/// любой путь). Дамка ходит и бьёт на любое расстояние; если после взятия
/// дамка может бить дальше, она обязана встать туда, откуда бьёт. Простая,
/// дошедшая до последнего ряда во время взятия, бьёт дальше уже как дамка.
/// Сбитые снимаются после хода («турецкий удар» — дважды одну не бьют).
///
/// Ход — «роль + путь»: `052-43`, взятие `052-34-16`. `0!` — сдался.
class Checkers {
  Checkers._();

  /// 1 — белая простая, 2 — белая дамка, -1 / -2 — чёрные; 0 — пусто.
  final board = List<int>.filled(64, 0);

  /// 0 — ходят белые (создатель), 1 — чёрные.
  int turn = 0;

  /// 0 / 1 — победитель, 2 — ничья, null — играем.
  int? winner;
  bool resigned = false;

  /// Последний ход (для подсветки).
  List<int>? last;

  /// Ходов подряд одними дамками без взятий (ничья на 30).
  int _quiet = 0;

  static const _dirs = [(-1, -1), (-1, 1), (1, -1), (1, 1)];

  factory Checkers.initial() {
    final g = Checkers._();
    for (var s = 0; s < 64; s++) {
      if (!dark(s)) continue;
      final r = s ~/ 8;
      if (r <= 2) g.board[s] = -1;
      if (r >= 5) g.board[s] = 1;
    }
    return g;
  }

  /// Повторить ходы; [FormatException] — ход не по правилам.
  factory Checkers.replay(List<String> moves) {
    final g = Checkers.initial();
    for (final m in moves) {
      g._apply(m);
    }
    return g;
  }

  static bool dark(int s) => ((s ~/ 8) + (s % 8)).isOdd;

  static bool _in(int r, int c) => r >= 0 && r < 8 && c >= 0 && c < 8;

  int _side(int piece) => piece > 0 ? 0 : 1;

  bool _mine(int piece, int side) => piece != 0 && _side(piece) == side;

  /// Все разрешённые ходы стороны, что ходит (пути по клеткам).
  List<List<int>> legal() {
    if (winner != null) return const [];
    final captures = <List<int>>[];
    for (var s = 0; s < 64; s++) {
      if (_mine(board[s], turn)) _captures(s, board[s], const {}, [s], captures);
    }
    if (captures.isNotEmpty) return captures;
    final moves = <List<int>>[];
    for (var s = 0; s < 64; s++) {
      final p = board[s];
      if (!_mine(p, turn)) continue;
      final r = s ~/ 8, c = s % 8;
      for (final (dr, dc) in _dirs) {
        if (p.abs() == 1) {
          // Простая — только вперёд: белые вверх, чёрные вниз.
          if (dr != (turn == 0 ? -1 : 1)) continue;
          final r1 = r + dr, c1 = c + dc;
          if (_in(r1, c1) && board[r1 * 8 + c1] == 0) moves.add([s, r1 * 8 + c1]);
        } else {
          var r1 = r + dr, c1 = c + dc;
          while (_in(r1, c1) && board[r1 * 8 + c1] == 0) {
            moves.add([s, r1 * 8 + c1]);
            r1 += dr;
            c1 += dc;
          }
        }
      }
    }
    return moves;
  }

  /// Пустая для хода клетка (клетка, с которой начали, уже свободна).
  bool _free(int s, List<int> path) => board[s] == 0 || s == path.first;

  bool _enemy(int s, int side) => board[s] != 0 && _side(board[s]) != side;

  /// Продолжить взятие с клетки [s] фигурой [piece]; готовые пути — в [out].
  void _captures(int s, int piece, Set<int> taken, List<int> path, List<List<int>> out) {
    final side = _side(piece);
    final r = s ~/ 8, c = s % 8;
    var any = false;
    for (final (dr, dc) in _dirs) {
      if (piece.abs() == 1) {
        final r1 = r + dr, c1 = c + dc, r2 = r + 2 * dr, c2 = c + 2 * dc;
        if (!_in(r2, c2)) continue;
        final v = r1 * 8 + c1, land = r2 * 8 + c2;
        if (!_enemy(v, side) || taken.contains(v) || !_free(land, path)) continue;
        any = true;
        // Дошла до последнего ряда — дальше бьёт как дамка.
        final promoted = (side == 0 && r2 == 0) || (side == 1 && r2 == 7);
        _captures(land, promoted ? piece * 2 : piece, {...taken, v}, [...path, land], out);
      } else {
        // Дамка: до первой фигуры на диагонали.
        var r1 = r + dr, c1 = c + dc;
        while (_in(r1, c1) && _free(r1 * 8 + c1, path)) {
          r1 += dr;
          c1 += dc;
        }
        if (!_in(r1, c1)) continue;
        final v = r1 * 8 + c1;
        if (!_enemy(v, side) || taken.contains(v)) continue;
        final landings = <int>[];
        var r2 = r1 + dr, c2 = c1 + dc;
        while (_in(r2, c2) && _free(r2 * 8 + c2, path)) {
          landings.add(r2 * 8 + c2);
          r2 += dr;
          c2 += dc;
        }
        if (landings.isEmpty) continue;
        any = true;
        // Если с какой-то клетки можно бить дальше — встать можно только туда.
        final results = <int, List<List<int>>>{};
        for (final l in landings) {
          final sub = <List<int>>[];
          _captures(l, piece, {...taken, v}, [...path, l], sub);
          results[l] = sub;
        }
        final cont = results.entries.where((e) => e.value.any((p) => p.length > path.length + 1));
        for (final e in cont.isNotEmpty ? cont : results.entries) {
          out.addAll(e.value);
        }
      }
    }
    if (!any && path.length > 1) out.add(path);
  }

  static List<int>? parsePath(String body) {
    final parts = body.split('-');
    if (parts.length < 2 || parts.length > 13) return null;
    final path = <int>[];
    for (final p in parts) {
      final s = int.tryParse(p);
      if (s == null || s < 0 || s > 63) return null;
      path.add(s);
    }
    return path;
  }

  static String encode(int role, List<int> path) => '$role${path.join('-')}';

  void _apply(String m) {
    if (m.length < 2 || winner != null) throw const FormatException('ход после конца');
    final role = int.tryParse(m[0]);
    if (role != 0 && role != 1) throw const FormatException('роль');
    final body = m.substring(1);
    if (body == '!') {
      winner = 1 - role!;
      resigned = true;
      return;
    }
    if (role != turn) throw const FormatException('не твой ход');
    final path = parsePath(body);
    if (path == null) throw const FormatException('путь');
    final ok = legal().any(
      (l) => l.length == path.length && Iterable.generate(l.length).every((i) => l[i] == path[i]),
    );
    if (!ok) throw const FormatException('так ходить нельзя');
    _move(path);
  }

  /// Сделать ход (уже проверенный).
  void _move(List<int> path) {
    var piece = board[path.first];
    final side = _side(piece);
    final wasKing = piece.abs() == 2;
    var captured = false;
    board[path.first] = 0;
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1], b = path[i];
      final dr = (b ~/ 8 - a ~/ 8).sign, dc = (b % 8 - a % 8).sign;
      var r = a ~/ 8 + dr, c = a % 8 + dc;
      while (r * 8 + c != b) {
        if (board[r * 8 + c] != 0) {
          board[r * 8 + c] = 0;
          captured = true;
        }
        r += dr;
        c += dc;
      }
      final row = b ~/ 8;
      if (piece.abs() == 1 && ((side == 0 && row == 0) || (side == 1 && row == 7))) {
        piece *= 2;
      }
    }
    board[path.last] = piece;
    last = path;
    _quiet = captured || !wasKing ? 0 : _quiet + 1;
    turn = 1 - turn;
    if (_quiet >= 30) {
      winner = 2;
    } else if (legal().isEmpty) {
      // Ходить нечем — проиграл тот, чей ход.
      winner = 1 - turn;
    }
  }

  /// Сколько фигур у стороны.
  int count(int side) => board.where((p) => _mine(p, side)).length;
}
