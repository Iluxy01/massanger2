import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:veil/games/checkers.dart';
import 'package:veil/games/game.dart';
import 'package:veil/games/lots.dart';
import 'package:veil/games/sea.dart';
import 'package:veil/games/ttt.dart';
import 'package:veil/games/word.dart';

int sq(String n) => (8 - int.parse(n[1])) * 8 + 'abcdefgh'.indexOf(n[0]);

/// Правила игр и честного жребия.
void main() {
  group('крестики-нолики', () {
    test('победа, ничья, чужой ход и занятая клетка', () {
      final g = Ttt.replay(['04', '10', '02', '11', '06']);
      expect(g.winner, 0);
      expect(g.line, [2, 4, 6]);
      expect(() => Ttt.replay(['04', '04']), throwsFormatException);
      expect(() => Ttt.replay(['14']), throwsFormatException, reason: 'первым ходит создатель');
      expect(() => Ttt.replay(['04', '13', '05', '11', '03', '18']), throwsFormatException);
      final draw = Ttt.replay(['00', '11', '02', '14', '03', '15', '07', '16', '08']);
      expect(draw.winner, 2);
      expect(Ttt.replay(['04', '1!']).winner, 0);
    });
  });

  group('шашки', () {
    test('начало: 7 ходов белых, чёрные — после', () {
      final g = Checkers.initial();
      expect(g.legal(), hasLength(7));
      expect(g.count(0), 12);
      expect(g.count(1), 12);
      final m = Checkers.encode(0, [sq('c3'), sq('d4')]);
      final g2 = Checkers.replay([m]);
      expect(g2.turn, 1);
      expect(() => Checkers.replay([m, m]), throwsFormatException);
      expect(
        () => Checkers.replay([
          Checkers.encode(0, [sq('c3'), sq('c4')]),
        ]),
        throwsFormatException,
      );
    });

    test('бить обязательно, двойное взятие, назад', () {
      final moves = [
        Checkers.encode(0, [sq('c3'), sq('d4')]),
        Checkers.encode(1, [sq('f6'), sq('e5')]),
      ];
      final g = Checkers.replay(moves);
      // Белые обязаны бить d4:f6.
      final legal = g.legal();
      expect(legal.every((p) => p.length >= 2), isTrue);
      expect(legal.any((p) => p.first == sq('d4') && p.last == sq('f6')), isTrue);
      expect(legal.length, 1);
      expect(
        () => Checkers.replay([
          ...moves,
          Checkers.encode(0, [sq('a3'), sq('b4')]),
        ]),
        throwsFormatException,
        reason: 'тихий ход, когда можно бить',
      );
      final after = Checkers.replay([
        ...moves,
        Checkers.encode(0, [sq('d4'), sq('f6')]),
      ]);
      expect(after.count(1), 11);
    });

    test('простая становится дамкой во время взятия и бьёт дальше', () {
      final g = Checkers.initial();
      g.board.fillRange(0, 64, 0);
      // Белая на c7 бьёт d8? Нет: бьёт b8 невозможно. Строим: белая e3, чёрные d6 и c7 — нет.
      // Белая на b6, чёрная на c7 → белая бьёт на d8 (становится дамкой) и
      // дальше как дамка бьёт чёрную на f6 → g5/h4.
      g.board[sq('b6')] = 1;
      g.board[sq('c7')] = -1;
      g.board[sq('f6')] = -1;
      g.board[sq('h8')] = -1;
      final legal = g.legal();
      expect(legal.any((p) => p.length == 3 && p[1] == sq('d8')), isTrue);
    });

    test('ходить нечем — проиграл', () {
      final g = Checkers.initial();
      g.board.fillRange(0, 64, 0);
      g.board[sq('a1')] = 1;
      g.board[sq('b2')] = -1;
      g.board[sq('c3')] = -1;
      g.turn = 0;
      expect(g.legal(), isEmpty, reason: 'белой некуда и некого бить');
    });
  });

  group('морской бой', () {
    test('случайная расстановка всегда по правилам', () {
      final r = Random(7);
      for (var i = 0; i < 200; i++) {
        final l = SeaLayout.random(r);
        expect(l.valid, isTrue);
        expect(l.cells, hasLength(20));
        expect(SeaLayout.decode(l.encode())!.cells, l.cells);
      }
      expect(SeaLayout.decode('0,1,2,3;5'), isNull);
    });

    test('партия: ответы ставит телефон сам, жульничество видно', () {
      final r = Random(3);
      final a = SeaLayout.random(r), b = SeaLayout.random(r);
      const sa = 'aaaa', sb = 'bbbb';
      final creator = Game(
        type: 'sea',
        commit: seaCommit(a.encode(), sa),
        secret: '${a.encode()}.$sa',
      );
      final second = Game(type: 'sea', commit: creator.commit, secret: '${b.encode()}.$sb');
      // Второй расставил корабли.
      second.moves.add('1h${seaCommit(b.encode(), sb)}');
      expect(creator.merge(second.moves, 1), isTrue);
      expect(creator.status().turn, 0);
      // Создатель стреляет по всем клеткам кораблей второго.
      for (final cell in b.cells) {
        creator.moves.add('0s$cell');
        expect(second.merge(creator.moves, 0), isTrue);
        second.autoMoves(1);
        expect(creator.merge(second.moves, 1), isTrue);
      }
      final s = creator.replay() as Sea;
      expect(s.winner, 0);
      // Оба раскрывают расстановки: второй — сразу после последнего ответа,
      // создатель — получив его.
      expect(second.moves.last, startsWith('1v'));
      creator.autoMoves(0);
      expect(creator.moves.last, startsWith('0v'));
      expect(second.merge(creator.moves, 0), isTrue);
      expect(second.moves.length, creator.moves.length);
      final end = creator.replay() as Sea;
      expect(end.cheat, [false, false]);
      expect(creator.status().cheat, isFalse);

      // Жульничество: «мимо» по кораблю — видно при раскрытии.
      final liar = Game(type: 'sea', commit: creator.commit, secret: '${b.encode()}.$sb');
      final honest = Game(type: 'sea', commit: creator.commit, secret: creator.secret);
      liar.moves.add('1h${seaCommit(b.encode(), sb)}');
      honest.merge(liar.moves, 1);
      final cell = b.cells.first;
      honest.moves.add('0s$cell');
      liar.merge(honest.moves, 0);
      liar.moves.add('1a${cell}m');
      honest.merge(liar.moves, 1);
      liar.moves.add('1!');
      honest.merge(liar.moves, 1);
      liar.autoMoves(1);
      honest.merge(liar.moves, 1);
      expect((honest.replay() as Sea).cheat[1], isTrue);
    });
  });

  group('угадай слово', () {
    test('буквы, ошибки, победа', () {
      expect(WordGame.normalize(' ёлка '), 'ЕЛКА');
      expect(WordGame.normalize('hello'), isNull);
      final g = WordGame.replay('КОТ', ['1К', '1О', '1Т']);
      expect(g.winner, 1);
      final lost = WordGame.replay('КОТ', ['1А', '1Б', '1В', '1Г', '1Д', '1Е', '1Ж']);
      expect(lost.winner, 0);
      expect(() => WordGame.replay('КОТ', ['1К', '1К']), throwsFormatException);
      expect(() => WordGame.replay('КОТ', ['0К']), throwsFormatException);
      expect(WordGame.replay('МАМА', ['1А']).masked, '_А_А');
    });
  });

  group('честный жребий', () {
    test('кубик: оба видят одно и то же, подмену видно', () {
      final r0 = Lot.random();
      final creator = Game(type: 'dice', commit: Lot.hash(r0), secret: r0);
      final second = Game(type: 'dice', commit: creator.commit);
      expect(second.autoMoves(1), hasLength(1));
      expect(creator.merge(second.moves, 1), isTrue);
      expect(creator.autoMoves(0), hasLength(1));
      expect(second.merge(creator.moves, 0), isTrue);
      final a = creator.replay() as Lot, b = second.replay() as Lot;
      expect(a.result, inInclusiveRange(1, 6));
      expect(b.result, a.result);
      expect(second.status().over, isTrue);

      final fake = Game(type: 'dice', commit: Lot.hash(r0), moves: [...second.moves.take(1)]);
      fake.moves.add('0${Lot.random()}');
      expect((fake.replay() as Lot).cheat, isTrue);
      expect(fake.status().cheat, isTrue);
    });

    test('монетка и КНБ', () {
      final r0 = Lot.random();
      final coin = Game(type: 'coin', commit: Lot.hash(r0), secret: r0);
      coin.moves.add('1${Lot.random()}');
      coin.autoMoves(0);
      expect((coin.replay() as Lot).result, anyOf(0, 1));

      final pick = 'r|${Lot.random()}';
      final rps = Game(type: 'rps', commit: Lot.hash(pick), secret: pick);
      expect(rps.status().turn, 1, reason: 'второй выбирает руками');
      expect(rps.autoMoves(1), isEmpty);
      rps.moves.add('1s');
      rps.autoMoves(0);
      final g = rps.replay() as Lot;
      expect(g.result, 0, reason: 'камень бьёт ножницы');
    });
  });

  test('чужие ходы и подделанные — не принимаются', () {
    final g = Game(type: 'ttt', moves: ['04']);
    expect(g.merge(['04', '13'], 1), isTrue);
    expect(g.merge(['04', '13', '05'], 1), isFalse, reason: 'ход не его роли');
    expect(g.merge(['04', '13', '14'], 1), isFalse);
    expect(g.moves, ['04', '13']);
    expect(Game.fromJson({'y': 'nope'}), isNull);
    expect(Game.fromJson({'y': 'dice'}), isNull, reason: 'жребий без обязательства');
    final j = Game(type: 'dice', commit: 'x' * 64, secret: 'tajna').toJson(wire: true);
    expect(j.containsKey('s'), isFalse, reason: 'секрет не уходит');
  });
}
