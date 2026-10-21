/// Крестики-нолики. Ходы — «роль + клетка»: `04` — создатель (крестики) в
/// центр, `1!` — второй игрок сдался. Создатель ходит первым.
class Ttt {
  Ttt._();

  /// Клетки: -1 пусто, 0 — крестик (создатель), 1 — нолик.
  final cells = List<int>.filled(9, -1);
  int turn = 0;

  /// 0 / 1 — победитель, 2 — ничья, null — играем.
  int? winner;

  /// Выигрышная линия (три клетки).
  List<int>? line;
  bool resigned = false;

  static const _lines = [
    [0, 1, 2], [3, 4, 5], [6, 7, 8], //
    [0, 3, 6], [1, 4, 7], [2, 5, 8], //
    [0, 4, 8], [2, 4, 6],
  ];

  /// Повторить ходы; [FormatException] — ход не по правилам.
  factory Ttt.replay(List<String> moves) {
    final g = Ttt._();
    for (final m in moves) {
      g._apply(m);
    }
    return g;
  }

  void _apply(String m) {
    if (m.length < 2 || winner != null) throw const FormatException('ход после конца');
    final role = int.tryParse(m[0]);
    final body = m.substring(1);
    if (role != 0 && role != 1) throw const FormatException('роль');
    if (body == '!') {
      winner = 1 - role!;
      resigned = true;
      return;
    }
    if (role != turn) throw const FormatException('не твой ход');
    final cell = int.tryParse(body);
    if (cell == null || cell < 0 || cell > 8 || cells[cell] != -1) {
      throw const FormatException('клетка');
    }
    cells[cell] = role!;
    for (final l in _lines) {
      if (cells[l[0]] == role && cells[l[1]] == role && cells[l[2]] == role) {
        winner = role;
        line = l;
        return;
      }
    }
    if (!cells.contains(-1)) {
      winner = 2;
      return;
    }
    turn = 1 - turn;
  }
}
