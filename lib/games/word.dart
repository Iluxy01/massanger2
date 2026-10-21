/// «Угадай слово» (виселица): создатель загадывает слово, второй игрок
/// называет буквы. 7 ошибок — проиграл. Ходы: `1А` — буква, `1!` — сдался.
class WordGame {
  WordGame._(this.word);

  static const maxWrong = 7;
  static const letters = 'АБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ';

  /// Загаданное (заглавными, Ё → Е).
  final String word;
  final guessed = <String>{};
  int wrong = 0;

  /// 0 — победил загадавший, 1 — угадавший, null — играем.
  int? winner;
  bool resigned = false;

  /// Привести слово к виду игры; null — не подходит.
  static String? normalize(String raw) {
    final w = raw.trim().toUpperCase().replaceAll('Ё', 'Е').replaceAll(RegExp(r'\s+'), ' ');
    if (w.length < 2 || w.length > 24) return null;
    if (!RegExp(r'^[А-Я -]+$').hasMatch(w)) return null;
    if (!w.split('').any((c) => letters.contains(c))) return null;
    return w;
  }

  factory WordGame.replay(String word, List<String> moves) {
    final g = WordGame._(word);
    for (final m in moves) {
      g._apply(m);
    }
    return g;
  }

  bool get solved => word.split('').every((c) => !letters.contains(c) || guessed.contains(c));

  /// Что видно угадывающему: угаданные буквы, остальное — «_».
  String get masked =>
      word.split('').map((c) => !letters.contains(c) || guessed.contains(c) ? c : '_').join();

  void _apply(String m) {
    if (m.length < 2 || winner != null) throw const FormatException('ход после конца');
    final role = int.tryParse(m[0]);
    final body = m.substring(1);
    if (body == '!' && (role == 0 || role == 1)) {
      winner = 1 - role!;
      resigned = true;
      return;
    }
    if (role != 1 || body.length != 1 || !letters.contains(body) || guessed.contains(body)) {
      throw const FormatException('буква');
    }
    guessed.add(body);
    if (!word.contains(body)) wrong++;
    if (solved) {
      winner = 1;
    } else if (wrong >= maxWrong) {
      winner = 0;
    }
  }
}
