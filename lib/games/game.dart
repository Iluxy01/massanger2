import 'checkers.dart';
import 'lots.dart';
import 'sea.dart';
import 'ttt.dart';
import 'word.dart';

/// Игра или жребий в личном чате.
///
/// Всё состояние — список ходов: каждый телефон получает его, повторяя ходы
/// по правилам (у обоих одинаково). Ход отправляется вместе со всем списком,
/// поэтому потерянный по дороге ход догоняется следующим. Роль 0 — создатель
/// (тот, кто отправил сообщение), 1 — второй игрок.
class Game {
  Game({required this.type, List<String>? moves, this.commit, this.word, this.hint, this.secret})
    : moves = moves ?? [];

  static const types = ['ttt', 'chk', 'sea', 'word', 'dice', 'coin', 'rps'];
  static const maxMoves = 600;

  final String type;
  final List<String> moves;

  /// Обязательство создателя (хэш жребия / расстановки кораблей).
  final String? commit;

  /// «Угадай слово»: загаданное и подсказка.
  final String? word;
  final String? hint;

  /// Только у себя: своё случайное число, выбор или расстановка с «солью».
  String? secret;

  bool get isLot => type == 'dice' || type == 'coin' || type == 'rps';

  String get title => switch (type) {
    'ttt' => 'Крестики-нолики',
    'chk' => 'Шашки',
    'sea' => 'Морской бой',
    'word' => 'Угадай слово',
    'dice' => 'Кубик',
    'coin' => 'Монетка',
    _ => 'Камень, ножницы, бумага',
  };

  String get emoji => switch (type) {
    'ttt' => '❌',
    'chk' => '⚫',
    'sea' => '🚢',
    'word' => '🔤',
    'dice' => '🎲',
    'coin' => '🪙',
    _ => '✊',
  };

  /// [wire] — для отправки: без своего секрета.
  Map<String, dynamic> toJson({bool wire = false}) => {
    'y': type,
    if (moves.isNotEmpty) 'mv': moves,
    if (commit != null) 'cm': commit,
    if (word != null) 'w': word,
    if (hint != null) 'h': hint,
    if (!wire && secret != null) 's': secret,
  };

  static Game? fromJson(Object? o) {
    if (o is! Map) return null;
    final y = o['y'];
    if (y is! String || !types.contains(y)) return null;
    final mv = o['mv'];
    final moves = mv is List
        ? mv.whereType<String>().where((m) => m.length <= 80).take(maxMoves).toList()
        : <String>[];
    String? str(String k, int max) =>
        o[k] is String && (o[k] as String).length <= max ? o[k] as String : null;
    final word = str('w', 24);
    if (y == 'word' && (word == null || WordGame.normalize(word) != word)) return null;
    if ((y == 'dice' || y == 'coin' || y == 'rps' || y == 'sea') && str('cm', 64) == null) {
      return null;
    }
    return Game(
      type: y,
      moves: moves,
      commit: str('cm', 64),
      word: word,
      hint: str('h', 80),
      secret: str('s', 2000),
    );
  }

  /// Повтор ходов по правилам; бросает [FormatException], если что-то не так.
  Object replay([List<String>? list]) {
    final mv = list ?? moves;
    return switch (type) {
      'ttt' => Ttt.replay(mv),
      'chk' => Checkers.replay(mv),
      'sea' => Sea.replay(commit, mv),
      'word' => WordGame.replay(word!, mv),
      _ => Lot.replay(type, commit, mv),
    };
  }

  Object? _state;
  GameStatus? _status;
  String? _key;

  /// Текущее состояние (повтор ходов кешируется до следующего хода, чтобы
  /// пузыри и экран игры не пересчитывали партию на каждой перерисовке);
  /// null — игра повреждена.
  Object? get state {
    final key = '${moves.length}|${moves.isEmpty ? '' : moves.last}';
    if (key != _key) {
      _key = key;
      _status = null;
      try {
        _state = replay();
      } catch (_) {
        _state = null;
      }
    }
    return _state;
  }

  bool validList(List<String> list) {
    try {
      replay(list);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Чей ход (кому нужно что-то сделать руками): 0 / 1; null — никому
  /// (ждём ответа телефона или игра окончена).
  GameStatus status() {
    final s = state;
    return _status ??= switch (s) {
      Ttt g => GameStatus(turn: g.winner == null ? g.turn : null, winner: g.winner),
      Checkers g => GameStatus(turn: g.winner == null ? g.turn : null, winner: g.winner),
      WordGame g => GameStatus(turn: g.winner == null ? 1 : null, winner: g.winner),
      Sea g => GameStatus(
        turn: g.winner != null
            ? null
            : g.commit1 == null
            ? 1
            : g.pending != null
            ? null
            : g.turn,
        winner: g.winner,
        cheat: g.cheat[0] || g.cheat[1],
      ),
      Lot g => GameStatus(
        turn: type == 'rps' && g.awaitingSecond ? 1 : null,
        winner: g.cheat
            ? null
            : g.result == null
            ? null
            : (type == 'rps' ? g.result : -1),
        cheat: g.cheat,
        done: g.result != null || g.cheat,
      ),
      _ => const GameStatus(broken: true),
    };
  }

  /// Принять список ходов от соперника (роль [sender]). Новые ходы — только
  /// его; если оба сходили одновременно (например, раскрыли расстановки),
  /// его ходы встают после наших. true — что-то добавилось.
  bool merge(List<String> incoming, int sender) {
    if (incoming.length > maxMoves) return false;
    var common = 0;
    while (common < moves.length && common < incoming.length && moves[common] == incoming[common]) {
      common++;
    }
    final mine = moves.sublist(common).toSet();
    final theirs = [
      for (final m in incoming.sublist(common))
        if (!mine.contains(m)) m,
    ];
    if (theirs.isEmpty || theirs.any((m) => !m.startsWith('$sender'))) return false;
    final candidate = [...moves, ...theirs];
    if (!validList(candidate)) return false;
    moves
      ..clear()
      ..addAll(candidate);
    return true;
  }

  /// Что телефон игрока [me] делает сам: отвечает на выстрел, бросает свою
  /// половину жребия, раскрывает обязательство. Возвращает добавленные ходы.
  List<String> autoMoves(int me) {
    final added = <String>[];
    for (var i = 0; i < 3; i++) {
      final next = _auto(me);
      if (next == null || !validList([...moves, next])) break;
      moves.add(next);
      added.add(next);
    }
    return added;
  }

  String? _auto(int me) {
    switch (state) {
      case Lot g:
        if (me == 1 && g.awaitingSecond && type != 'rps') return '1${Lot.random()}';
        if (me == 0 && g.awaitingReveal && secret != null) return '0$secret';
      case Sea g:
        final mine = _layout();
        if (mine == null) return null;
        final p = g.pending;
        if (p != null && p.$1 != me) {
          return '${me}a${p.$2}${Sea.answer(mine.$1, g.shots[1 - me], p.$2)}';
        }
        if (g.winner != null && g.revealed[me] == null) return '${me}v$secret';
    }
    return null;
  }

  /// Своя расстановка из секрета «расстановка.соль».
  (SeaLayout, String)? _layout() {
    final s = secret;
    if (s == null) return null;
    final dot = s.lastIndexOf('.');
    if (dot < 0) return null;
    final l = SeaLayout.decode(s.substring(0, dot));
    return l == null ? null : (l, s.substring(dot + 1));
  }

  SeaLayout? get myLayout => _layout()?.$1;
}

class GameStatus {
  const GameStatus({this.turn, this.winner, this.cheat = false, this.broken = false, this.done});

  /// Кому ходить руками (0 / 1), null — никому.
  final int? turn;

  /// 0 / 1 — победитель, 2 — ничья, -1 — жребий брошен, null — идёт.
  final int? winner;
  final bool cheat;
  final bool broken;
  final bool? done;

  bool get over => (done ?? winner != null) || broken;
}
