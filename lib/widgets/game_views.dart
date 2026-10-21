import 'dart:math';

import 'package:flutter/material.dart';

import '../games/checkers.dart';
import '../games/lots.dart';
import '../games/sea.dart';
import '../games/ttt.dart';
import '../games/word.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import 'effects.dart';
import 'visual.dart';

/// Подпись к состоянию игры для игрока [me].
String gameStatusText(Game g, int me) {
  final st = g.status();
  if (st.broken) return 'Игра повреждена';
  final s = g.state;
  if (s == null) return 'Игра повреждена';
  if (st.cheat) {
    final cheater = s is Sea ? (s.cheat[me] ? me : 1 - me) : 0;
    return cheater == me ? 'Расстановка не сошлась' : '⚠️ Соперник жульничал';
  }
  if (s is Lot) {
    if (g.type == 'rps') {
      if (s.result == null) {
        return s.awaitingSecond ? (me == 1 ? 'Твой выбор?' : 'Соперник выбирает…') : 'Открываем…';
      }
      return s.result == 2 ? 'Ничья' : (s.result == me ? 'Победа! 🎉' : 'Поражение');
    }
    return s.result == null ? 'Бросаем…' : 'Честно ✓';
  }
  final resigned = switch (s) {
    Ttt g => g.resigned,
    Checkers g => g.resigned,
    Sea g => g.resigned,
    WordGame g => g.resigned,
    _ => false,
  };
  if (st.winner != null) {
    if (st.winner == 2) return 'Ничья';
    if (resigned) return st.winner == me ? 'Соперник сдался — победа' : 'Ты сдался';
    if (g.type == 'word') {
      return st.winner == me
          ? (me == 1 ? 'Угадано! 🎉' : 'Не угадали — победа!')
          : (me == 1 ? 'Не угадано' : 'Угадали слово');
    }
    return st.winner == me ? 'Победа! 🎉' : 'Поражение';
  }
  if (s is Sea && s.commit1 == null) {
    return me == 1 ? 'Расставь корабли' : 'Соперник расставляет корабли…';
  }
  if (st.turn == null) return 'Ждём ответа…';
  if (g.type == 'word') return me == 1 ? 'Угадывай!' : 'Соперник угадывает…';
  return st.turn == me ? 'Твой ход' : 'Ход соперника';
}

/// Игра в пузыре: превью, кто ходит, «Открыть».
class GameContent extends StatelessWidget {
  const GameContent({
    super.key,
    required this.m,
    required this.chatId,
    required this.fg,
    required this.meta,
    required this.onOpen,
  });

  final Message m;
  final String chatId;
  final Color fg;
  final Widget meta;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final g = m.game!;
    final me = m.mine ? 0 : 1;
    final st = g.status();
    final myTurn = st.turn == me;
    final panel = m.mine ? Colors.black.withValues(alpha: 0.16) : context.vc.surface;
    Widget? body;
    switch (st.broken ? '' : g.type) {
      case 'ttt':
        body = TttGrid(
          game: g,
          me: me,
          size: 168,
          dark: m.mine,
          onMove: (cell) => app.gameMove(chatId, m, '$cell'),
        );
      case 'dice' || 'coin':
        final lot = g.state as Lot;
        body = Center(
          child: LotFace(type: g.type, result: lot.result, cheat: lot.cheat, size: 86),
        );
      case 'rps':
        body = _RpsBody(m: m, chatId: chatId, fg: fg, me: me);
      case 'chk':
        body = SizedBox(
          width: 168,
          height: 168,
          child: CheckersBoard(game: g.state as Checkers, flip: me == 1),
        );
      case 'sea':
        final s = g.state as Sea;
        body = Text(
          s.ready
              ? 'Попаданий: ты ${s.hits(me)} / 20 · соперник ${s.hits(1 - me)} / 20'
              : 'Флот: 4 · 3 · 3 · 2 · 2 · 2 · 1 · 1 · 1 · 1',
          style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 13),
        );
      case 'word':
        final w = g.state as WordGame;
        body = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              st.over ? g.word! : w.masked.split('').join(' '),
              style: TextStyle(
                color: fg,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
                fontSize: 20,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Ошибок: ${w.wrong} из ${WordGame.maxWrong}'
              '${g.hint != null ? ' · подсказка: ${g.hint}' : ''}',
              style: TextStyle(color: fg.withValues(alpha: 0.75), fontSize: 12.5),
            ),
          ],
        );
    }
    final opens = g.type == 'chk' || g.type == 'sea' || g.type == 'word';
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(g.emoji, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  g.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (body != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(14)),
              child: Center(child: body),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (myTurn && !st.over) ...[
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: m.mine ? fg : context.accent.a,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Text(
                  gameStatusText(g, me),
                  style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13.5),
                ),
              ),
            ],
          ),
          if (opens || (st.over && !g.isLot)) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                if (opens)
                  _PillButton(
                    label: st.over ? 'Посмотреть' : (myTurn ? 'Ходить' : 'Открыть'),
                    fg: fg,
                    strong: myTurn && !st.over,
                    onTap: onOpen,
                  ),
                if (st.over && !g.isLot && g.type != 'sea' && g.type != 'word') ...[
                  _PillButton(
                    label: 'Ещё раз',
                    fg: fg,
                    onTap: () => app.sendGame(chatId, Game(type: g.type)),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: meta),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.fg,
    required this.onTap,
    this.strong = false,
  });

  final String label;
  final Color fg;
  final VoidCallback onTap;
  final bool strong;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: strong ? 0.22 : 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: fg.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13),
      ),
    ),
  );
}

/// «Камень-ножницы-бумага» в пузыре: выбор второго игрока и итог.
class _RpsBody extends StatelessWidget {
  const _RpsBody({required this.m, required this.chatId, required this.fg, required this.me});

  final Message m;
  final String chatId;
  final Color fg;
  final int me;

  @override
  Widget build(BuildContext context) {
    final g = m.game!;
    final lot = g.state as Lot;
    final mySecret = g.secret?.split('|').first;
    String face(String? p) => p == null ? '❔' : Lot.rps[p]!;
    if (lot.result != null || lot.cheat) {
      final a = me == 0 ? lot.pick0 : lot.pick1, b = me == 0 ? lot.pick1 : lot.pick0;
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(face(a), style: const TextStyle(fontSize: 40)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text('vs', style: TextStyle(color: fg.withValues(alpha: 0.7))),
          ),
          Text(face(b), style: const TextStyle(fontSize: 40)),
        ],
      );
    }
    if (me == 1 && lot.awaitingSecond) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (final e in Lot.rps.entries)
            Pressable(
              key: ValueKey('rps-${e.key}'),
              onTap: () => context.appRead.gameMove(chatId, m, e.key),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(e.value, style: const TextStyle(fontSize: 38)),
              ),
            ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(me == 0 ? face(mySecret) : face(lot.pick1), style: const TextStyle(fontSize: 40)),
        const SizedBox(width: 12),
        Text('vs  ❔', style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 28)),
      ],
    );
  }
}

// ───────────────────────────── Крестики-нолики ─────────────────────────────

class TttGrid extends StatelessWidget {
  const TttGrid({
    super.key,
    required this.game,
    required this.me,
    required this.size,
    required this.onMove,
    this.dark = false,
  });

  final Game game;
  final int me;
  final double size;
  final bool dark;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    final s = game.state as Ttt;
    final acc = context.accent;
    final line = dark ? Colors.white.withValues(alpha: 0.5) : context.vc.textFaint;
    final can = s.winner == null && s.turn == me;
    final cell = size / 3;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          CustomPaint(size: Size.square(size), painter: _GridPainter(line)),
          for (var i = 0; i < 9; i++)
            Positioned(
              left: (i % 3) * cell,
              top: (i ~/ 3) * cell,
              width: cell,
              height: cell,
              child: GestureDetector(
                key: ValueKey('ttt-$i'),
                behavior: HitTestBehavior.opaque,
                onTap: can && s.cells[i] == -1 ? () => onMove(i) : null,
                child: Center(
                  child: AnimatedScale(
                    scale: s.cells[i] == -1 ? 0 : 1,
                    duration: const Duration(milliseconds: 220).by(context),
                    curve: Curves.easeOutBack,
                    child: s.cells[i] == -1
                        ? const SizedBox()
                        : Text(
                            s.cells[i] == 0 ? '✕' : '◯',
                            style: TextStyle(
                              fontSize: cell * 0.55,
                              fontWeight: FontWeight.w900,
                              color: s.line != null && s.line!.contains(i)
                                  ? (dark ? Colors.white : acc.b)
                                  : s.cells[i] == 0
                                  ? (dark ? Colors.white : acc.a)
                                  : (dark ? Colors.white70 : context.vc.text),
                            ),
                          ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final c = size.width / 3;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(c * i, 6), Offset(c * i, size.height - 6), p);
      canvas.drawLine(Offset(6, c * i), Offset(size.width - 6, c * i), p);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => old.color != color;
}

// ───────────────────────────── Шашки ─────────────────────────────

/// Доска шашек. [flip] — смотреть со стороны чёрных. [marks] — подсветка
/// клеток (куда можно сходить), [selected] — выбранная фигура.
class CheckersBoard extends StatelessWidget {
  const CheckersBoard({
    super.key,
    required this.game,
    this.flip = false,
    this.selected,
    this.marks = const {},
    this.movable = const {},
    this.onTap,
  });

  final Checkers game;
  final bool flip;
  final int? selected;
  final Set<int> marks;
  final Set<int> movable;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = min(box.maxWidth, box.maxHeight);
        return GestureDetector(
          onTapUp: onTap == null
              ? null
              : (d) {
                  final cell = size / 8;
                  var c = (d.localPosition.dx / cell).floor().clamp(0, 7);
                  var r = (d.localPosition.dy / cell).floor().clamp(0, 7);
                  if (flip) {
                    c = 7 - c;
                    r = 7 - r;
                  }
                  onTap!(r * 8 + c);
                },
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.square(size),
              painter: _CheckersPainter(
                board: List.of(game.board),
                last: game.last,
                flip: flip,
                selected: selected,
                marks: marks,
                movable: movable,
                accent: context.accent.a,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CheckersPainter extends CustomPainter {
  _CheckersPainter({
    required this.board,
    required this.last,
    required this.flip,
    required this.selected,
    required this.marks,
    required this.movable,
    required this.accent,
  });

  final List<int> board;
  final List<int>? last;
  final bool flip;
  final int? selected;
  final Set<int> marks;
  final Set<int> movable;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 8;
    final light = Paint()..color = const Color(0xFFF2DFC1);
    final dark = Paint()..color = const Color(0xFF9B6A43);
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(rr);
    for (var s = 0; s < 64; s++) {
      final rect = _rect(s, cell);
      canvas.drawRect(rect, Checkers.dark(s) ? dark : light);
      if (last != null && last!.contains(s)) {
        canvas.drawRect(rect, Paint()..color = const Color(0x55FFE066));
      }
      if (movable.contains(s)) {
        canvas.drawRect(rect, Paint()..color = accent.withValues(alpha: 0.28));
      }
      if (s == selected) {
        canvas.drawRect(rect, Paint()..color = accent.withValues(alpha: 0.55));
      }
    }
    for (var s = 0; s < 64; s++) {
      final p = board[s];
      final rect = _rect(s, cell);
      if (p != 0) {
        final white = p > 0;
        final c = rect.center, r = cell * 0.38;
        canvas.drawCircle(c + Offset(0, cell * 0.04), r, Paint()..color = const Color(0x55000000));
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(
              colors: white
                  ? const [Color(0xFFFFFFFF), Color(0xFFD9D2C5)]
                  : const [Color(0xFF4A4A55), Color(0xFF15151B)],
              center: const Alignment(-0.3, -0.4),
            ).createShader(Rect.fromCircle(center: c, radius: r)),
        );
        canvas.drawCircle(
          c,
          r * 0.68,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = cell * 0.035
            ..color = white ? const Color(0x33000000) : const Color(0x44FFFFFF),
        );
        if (p.abs() == 2) {
          // Дамка — золотая корона.
          final crown = Path();
          final w = r * 0.9, h = r * 0.55, top = c.dy - h * 0.55, left = c.dx - w / 2;
          crown
            ..moveTo(left, top + h)
            ..lineTo(left, top + h * 0.25)
            ..lineTo(left + w * 0.25, top + h * 0.6)
            ..lineTo(c.dx, top)
            ..lineTo(left + w * 0.75, top + h * 0.6)
            ..lineTo(left + w, top + h * 0.25)
            ..lineTo(left + w, top + h)
            ..close();
          canvas.drawPath(crown, Paint()..color = const Color(0xFFFFC145));
        }
      }
      if (marks.contains(s)) {
        canvas.drawCircle(rect.center, cell * 0.16, Paint()..color = accent.withValues(alpha: 0.9));
      }
    }
    canvas.restore();
  }

  Rect _rect(int s, double cell) {
    var r = s ~/ 8, c = s % 8;
    if (flip) {
      r = 7 - r;
      c = 7 - c;
    }
    return Rect.fromLTWH(c * cell, r * cell, cell, cell);
  }

  @override
  bool shouldRepaint(_CheckersPainter old) =>
      old.selected != selected ||
      old.flip != flip ||
      old.accent != accent ||
      old.last != last ||
      old.marks.length != marks.length ||
      !old.marks.containsAll(marks) ||
      old.movable.length != movable.length ||
      !_same(old.board, board);

  static bool _same(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// ───────────────────────────── Морской бой ─────────────────────────────

/// Поле морского боя. [ships] — свои корабли (на своём поле), [shots] —
/// выстрелы по этому полю (клетка → m/h/k/null), [empty] — где кораблей точно нет.
class SeaBoard extends StatelessWidget {
  const SeaBoard({
    super.key,
    this.ships = const {},
    this.shots = const {},
    this.empty = const {},
    this.onTap,
    this.pending,
  });

  final Set<int> ships;
  final Map<int, String?> shots;
  final Set<int> empty;
  final int? pending;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return LayoutBuilder(
      builder: (context, box) {
        final size = min(box.maxWidth, box.maxHeight);
        return GestureDetector(
          onTapUp: onTap == null
              ? null
              : (d) {
                  final cell = size / 10;
                  final c = (d.localPosition.dx / cell).floor().clamp(0, 9);
                  final r = (d.localPosition.dy / cell).floor().clamp(0, 9);
                  onTap!(r * 10 + c);
                },
          child: RepaintBoundary(
            child: CustomPaint(
              size: Size.square(size),
              painter: _SeaPainter(
                ships: ships,
                shots: Map.of(shots),
                empty: empty,
                pending: pending,
                water: vc.dark ? const Color(0xFF14263D) : const Color(0xFFDDEBFA),
                line: vc.dark ? const Color(0xFF29425F) : const Color(0xFFB9D0EA),
                ship: acc.a,
                text: vc.textDim,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SeaPainter extends CustomPainter {
  _SeaPainter({
    required this.ships,
    required this.shots,
    required this.empty,
    required this.pending,
    required this.water,
    required this.line,
    required this.ship,
    required this.text,
  });

  final Set<int> ships;
  final Map<int, String?> shots;
  final Set<int> empty;
  final int? pending;
  final Color water, line, ship, text;

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 10;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)));
    canvas.drawRect(Offset.zero & size, Paint()..color = water);
    final grid = Paint()
      ..color = line
      ..strokeWidth = 1;
    for (var i = 1; i < 10; i++) {
      canvas.drawLine(Offset(i * cell, 0), Offset(i * cell, size.height), grid);
      canvas.drawLine(Offset(0, i * cell), Offset(size.width, i * cell), grid);
    }
    for (var s = 0; s < 100; s++) {
      final rect = Rect.fromLTWH((s % 10) * cell, (s ~/ 10) * cell, cell, cell);
      if (ships.contains(s)) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect.deflate(cell * 0.08), Radius.circular(cell * 0.18)),
          Paint()..color = ship.withValues(alpha: 0.85),
        );
      }
      final res = shots[s];
      if (shots.containsKey(s) && res == null || s == pending) {
        canvas.drawCircle(rect.center, cell * 0.18, Paint()..color = text.withValues(alpha: 0.5));
      } else if (res == 'm' || (empty.contains(s) && !shots.containsKey(s))) {
        canvas.drawCircle(
          rect.center,
          cell * (res == 'm' ? 0.12 : 0.07),
          Paint()..color = text.withValues(alpha: res == 'm' ? 0.8 : 0.35),
        );
      } else if (res == 'h' || res == 'k') {
        if (res == 'k') {
          canvas.drawRect(rect.deflate(1), Paint()..color = const Color(0x55FF3D5A));
        }
        final p = Paint()
          ..color = const Color(0xFFFF3D5A)
          ..strokeWidth = cell * 0.13
          ..strokeCap = StrokeCap.round;
        final d = cell * 0.26;
        canvas.drawLine(rect.center - Offset(d, d), rect.center + Offset(d, d), p);
        canvas.drawLine(rect.center - Offset(d, -d), rect.center + Offset(d, -d), p);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SeaPainter old) =>
      old.shots.length != shots.length ||
      old.pending != pending ||
      old.ships.length != ships.length ||
      !old.ships.containsAll(ships) ||
      old.empty.length != empty.length ||
      old.water != water ||
      old.ship != ship ||
      shots.entries.any((e) => old.shots[e.key] != e.value);
}

// ───────────────────────────── Кубик и монетка ─────────────────────────────

/// Кубик или монетка. Когда приходит результат — короткая анимация броска
/// (один раз), в остальное время — статичная картинка.
class LotFace extends StatefulWidget {
  const LotFace({
    super.key,
    required this.type,
    required this.result,
    this.cheat = false,
    this.size = 80,
  });

  final String type;
  final int? result;
  final bool cheat;
  final double size;

  @override
  State<LotFace> createState() => _LotFaceState();
}

class _LotFaceState extends State<LotFace> with SingleTickerProviderStateMixin {
  AnimationController? _roll;
  final _rnd = Random();

  @override
  void didUpdateWidget(LotFace old) {
    super.didUpdateWidget(old);
    if (old.result == null && widget.result != null && Visual.of(context).motion > 0) {
      _roll?.dispose();
      _roll = AnimationController(vsync: this, duration: const Duration(milliseconds: 750))
        ..addListener(() => setState(() {}))
        ..forward().whenComplete(() {
          if (!mounted) return;
          setState(() {
            _roll?.dispose();
            _roll = null;
          });
        });
    }
  }

  @override
  void dispose() {
    _roll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rolling = _roll != null;
    final t = _roll?.value ?? 1;
    final size = widget.size;
    if (widget.cheat) return Text('⚠️', style: TextStyle(fontSize: size * 0.6));
    if (widget.type == 'coin') {
      final face = rolling ? (_rnd.nextBool() ? 0 : 1) : widget.result;
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateX(rolling ? t * pi * 6 : 0),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFFFFE08A), Color(0xFFE0A526)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [BoxShadow(color: Color(0x44000000), blurRadius: 8, offset: Offset(0, 3))],
          ),
          child: Text(
            face == null ? '?' : (face == 0 ? 'Орёл' : 'Решка'),
            style: TextStyle(
              color: const Color(0xFF7A4E00),
              fontWeight: FontWeight.w900,
              fontSize: size * (face == null ? 0.4 : 0.2),
            ),
          ),
        ),
      );
    }
    final face = rolling ? _rnd.nextInt(6) + 1 : widget.result;
    return Transform.rotate(
      angle: rolling ? (1 - t) * pi * 2 : 0,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _DicePainter(face)),
      ),
    );
  }
}

class _DicePainter extends CustomPainter {
  _DicePainter(this.face);
  final int? face;

  static const _pips = {
    1: [(0.5, 0.5)],
    2: [(0.27, 0.27), (0.73, 0.73)],
    3: [(0.27, 0.27), (0.5, 0.5), (0.73, 0.73)],
    4: [(0.27, 0.27), (0.73, 0.27), (0.27, 0.73), (0.73, 0.73)],
    5: [(0.27, 0.27), (0.73, 0.27), (0.5, 0.5), (0.27, 0.73), (0.73, 0.73)],
    6: [(0.27, 0.25), (0.73, 0.25), (0.27, 0.5), (0.73, 0.5), (0.27, 0.75), (0.73, 0.75)],
  };

  @override
  void paint(Canvas canvas, Size size) {
    final r = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(size.width * 0.2));
    canvas.drawRRect(r.shift(const Offset(0, 3)), Paint()..color = const Color(0x44000000));
    canvas.drawRRect(
      r,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0xFFFFFFFF), Color(0xFFE6E6EE)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(Offset.zero & size),
    );
    final f = face;
    if (f == null) {
      final tp = TextPainter(
        text: TextSpan(
          text: '?',
          style: TextStyle(color: const Color(0xFF8888AA), fontSize: size.width * 0.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset((size.width - tp.width) / 2, (size.height - tp.height) / 2));
      return;
    }
    final pip = Paint()..color = f == 1 ? const Color(0xFFFF3D5A) : const Color(0xFF1B1B26);
    for (final (x, y) in _pips[f]!) {
      canvas.drawCircle(Offset(x * size.width, y * size.height), size.width * 0.085, pip);
    }
  }

  @override
  bool shouldRepaint(_DicePainter old) => old.face != face;
}
