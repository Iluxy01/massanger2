import 'dart:math';

import 'package:flutter/material.dart';

import '../games/checkers.dart';
import '../games/lots.dart';
import '../games/sea.dart';
import '../games/word.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/effects.dart';
import '../widgets/game_views.dart';
import '../widgets/visual.dart';

/// Выбор игры (из меню «＋»). Игры — только в личном чате.
Future<void> pickGame(BuildContext context, String chatId, {bool lots = false}) async {
  final vc = context.vc;
  final items = lots
      ? const [
          ('dice', '🎲', 'Кубик', 'Честный бросок: подогнать не может никто'),
          ('coin', '🪙', 'Монетка', 'Орёл или решка — для споров'),
          ('rps', '✊', 'Камень, ножницы, бумага', 'Твой выбор скрыт до ответа'),
        ]
      : const [
          ('ttt', '❌', 'Крестики-нолики', 'Прямо в чате, ходите по очереди'),
          ('chk', '⚫', 'Шашки', 'Русские правила: бить обязательно, дамки'),
          ('sea', '🚢', 'Морской бой', 'Расстановку не подменить — проверка в конце'),
          ('word', '🔤', 'Угадай слово', 'Загадай слово — друг угадывает буквы'),
        ];
  final type = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 24,
          color: vc.elevated,
          padding: const EdgeInsets.symmetric(vertical: 10),
          // Своя «материя» — чтобы у пунктов был виден отклик на касание.
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
                  child: Text(
                    lots ? 'Жребий' : 'Игры',
                    style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                for (final (id, emoji, title, sub) in items)
                  ListTile(
                    key: ValueKey('pick-$id'),
                    leading: Text(emoji, style: const TextStyle(fontSize: 28)),
                    title: Text(
                      title,
                      style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(sub, style: TextStyle(color: vc.textDim, fontSize: 12.5)),
                    onTap: () => Navigator.pop(ctx, id),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (type == null || !context.mounted) return;
  await startGame(context, chatId, type);
}

/// Начать игру [type]: что нужно — спросить, и отправить.
Future<void> startGame(BuildContext context, String chatId, String type) async {
  final app = context.appRead;
  switch (type) {
    case 'ttt' || 'chk':
      app.sendGame(chatId, Game(type: type));
    case 'dice' || 'coin':
      final r = Lot.random();
      app.sendGame(chatId, Game(type: type, commit: Lot.hash(r), secret: r));
    case 'rps':
      final pick = await _pickRps(context);
      if (pick == null) return;
      final secret = '$pick|${Lot.random()}';
      app.sendGame(chatId, Game(type: 'rps', commit: Lot.hash(secret), secret: secret));
    case 'sea':
      final placed = await Navigator.of(context).push<(SeaLayout, String)>(
        MaterialPageRoute(builder: (_) => const SeaSetupScreen(title: 'Расставь корабли')),
      );
      if (placed == null) return;
      final (layout, salt) = placed;
      app.sendGame(
        chatId,
        Game(
          type: 'sea',
          commit: seaCommit(layout.encode(), salt),
          secret: '${layout.encode()}.$salt',
        ),
      );
    case 'word':
      final w = await _askWord(context);
      if (w == null) return;
      app.sendGame(chatId, Game(type: 'word', word: w.$1, hint: w.$2));
  }
}

Future<String?> _pickRps(BuildContext context) {
  final vc = context.vc;
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 24,
          color: vc.elevated,
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Твой выбор',
                style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                'Соперник увидит его только после своего хода',
                style: TextStyle(color: vc.textDim, fontSize: 13),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final (k, e, name) in const [
                    ('r', '✊', 'Камень'),
                    ('s', '✌️', 'Ножницы'),
                    ('p', '✋', 'Бумага'),
                  ])
                    Pressable(
                      onTap: () => Navigator.pop(ctx, k),
                      child: Column(
                        children: [
                          Text(e, style: const TextStyle(fontSize: 46)),
                          Text(name, style: TextStyle(color: vc.textDim, fontSize: 12.5)),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<(String, String?)?> _askWord(BuildContext context) async {
  final vc = context.vc;
  final word = TextEditingController();
  final hint = TextEditingController();
  String? error;
  final res = await showDialog<(String, String?)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => AlertDialog(
        backgroundColor: vc.elevated,
        title: Text('Загадай слово', style: TextStyle(color: vc.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('word-input'),
              controller: word,
              autofocus: true,
              maxLength: 24,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(color: vc.text, fontSize: 18, letterSpacing: 2),
              decoration: InputDecoration(
                hintText: 'Например: КАРАНДАШ',
                errorText: error,
                hintStyle: TextStyle(color: vc.textFaint),
              ),
            ),
            TextField(
              controller: hint,
              maxLength: 60,
              style: TextStyle(color: vc.text),
              decoration: InputDecoration(
                hintText: 'Подсказка (необязательно)',
                hintStyle: TextStyle(color: vc.textFaint),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(
            onPressed: () {
              final w = WordGame.normalize(word.text);
              if (w == null) {
                set(() => error = 'Только русские буквы, от 2 до 24');
                return;
              }
              final h = hint.text.trim();
              Navigator.pop(ctx, (w, h.isEmpty ? null : h));
            },
            child: const Text('Загадать'),
          ),
        ],
      ),
    ),
  );
  word.dispose();
  hint.dispose();
  return res;
}

/// Полноэкранная игра: шашки, морской бой, «угадай слово», крестики-нолики.
class GameScreen extends StatefulWidget {
  const GameScreen({super.key, required this.chatId, required this.msgId});

  final String chatId;
  final String msgId;

  static Route<void> route(String chatId, String msgId) => MaterialPageRoute(
    builder: (_) => GameScreen(chatId: chatId, msgId: msgId),
  );

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  /// Шашки: путь, который игрок набирает касаниями.
  List<int> _path = [];

  Message? _msg(AppState app) {
    for (final m in app.messagesOf(widget.chatId)) {
      if (m.id == widget.msgId) return m;
    }
    return null;
  }

  Future<void> _resign(Message m) async {
    final vc = context.vc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        title: Text('Сдаться?', style: TextStyle(color: vc.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Нет', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сдаться')),
        ],
      ),
    );
    if (ok == true && mounted) context.appRead.gameMove(widget.chatId, m, '!');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final m = _msg(app);
    if (m == null || m.game == null) {
      return Scaffold(
        backgroundColor: vc.bg,
        appBar: AppBar(backgroundColor: vc.bg),
      );
    }
    final g = m.game!;
    final me = m.mine ? 0 : 1;
    final st = g.status();
    final Widget body = switch (g.type) {
      'chk' => _checkers(m, me),
      'sea' => _sea(m, me),
      'word' => _word(m, me),
      _ => Center(
        child: TttGrid(
          game: g,
          me: me,
          size: min(MediaQuery.sizeOf(context).width - 64, 340),
          onMove: (c) => app.gameMove(widget.chatId, m, '$c'),
        ),
      ),
    };
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: Text('${g.emoji} ${g.title}'),
        actions: [
          if (!st.over && !(g.type == 'word' && me == 0))
            TextButton(
              onPressed: () => _resign(m),
              child: Text('Сдаться', style: TextStyle(color: vc.textDim)),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250).by(context),
                child: Text(
                  gameStatusText(g, me),
                  key: ValueKey(gameStatusText(g, me)),
                  style: TextStyle(
                    color: st.turn == me && !st.over ? app.accent.a : vc.text,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  // ── шашки ──

  Widget _checkers(Message m, int me) {
    final app = context.appRead;
    final g = m.game!.state as Checkers;
    final myTurn = g.winner == null && g.turn == me;
    final legal = myTurn ? g.legal() : const <List<int>>[];
    bool prefix(List<int> l) {
      if (l.length <= _path.length) return false;
      for (var i = 0; i < _path.length; i++) {
        if (l[i] != _path[i]) return false;
      }
      return true;
    }

    final next = _path.isEmpty
        ? <int>{}
        : {
            for (final l in legal)
              if (prefix(l)) l[_path.length],
          };
    final movable = _path.isEmpty ? {for (final l in legal) l.first} : <int>{};

    void tap(int s) {
      if (!myTurn) return;
      if (_path.isNotEmpty && next.contains(s)) {
        final p = [..._path, s];
        final done =
            legal.any((l) => l.length == p.length && prefix(l) && l.last == s) &&
            !legal.any((l) => l.length > p.length && _startsWith(l, p));
        if (done) {
          setState(() => _path = []);
          app.gameMove(widget.chatId, m, Checkers.encode(0, p).substring(1));
        } else {
          setState(() => _path = p);
        }
        return;
      }
      setState(() => _path = legal.any((l) => l.first == s) ? [s] : []);
    }

    final vc = context.vc;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: AspectRatio(
            aspectRatio: 1,
            child: CheckersBoard(
              game: g,
              flip: me == 1,
              selected: _path.isEmpty ? null : _path.last,
              marks: next,
              movable: movable,
              onTap: tap,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Ты — ${me == 0 ? 'белые' : 'чёрные'} · шашек: у тебя ${g.count(me)}, '
          'у соперника ${g.count(1 - me)}',
          style: TextStyle(color: vc.textDim, fontSize: 13.5),
        ),
        if (myTurn && legal.isNotEmpty && legal.first.length > 2 || _isCapture(g, legal))
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Бить обязательно', style: TextStyle(color: vc.textFaint, fontSize: 12.5)),
          ),
      ],
    );
  }

  static bool _startsWith(List<int> l, List<int> p) {
    if (l.length < p.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (l[i] != p[i]) return false;
    }
    return true;
  }

  bool _isCapture(Checkers g, List<List<int>> legal) {
    if (legal.isEmpty) return false;
    final l = legal.first;
    final dr = (l[1] ~/ 8 - l[0] ~/ 8).abs();
    // Простая на две клетки — это взятие; у дамки проверяем, есть ли кто между.
    if (g.board[l[0]].abs() == 1) return dr == 2;
    final sr = (l[1] ~/ 8 - l[0] ~/ 8).sign, sc = (l[1] % 8 - l[0] % 8).sign;
    var r = l[0] ~/ 8 + sr, c = l[0] % 8 + sc;
    while (r * 8 + c != l[1]) {
      if (g.board[r * 8 + c] != 0) return true;
      r += sr;
      c += sc;
    }
    return false;
  }

  // ── морской бой ──

  Widget _sea(Message m, int me) {
    final app = context.appRead;
    final vc = context.vc;
    final g = m.game!;
    final s = g.state as Sea;
    final mine = g.myLayout;
    if (me == 1 && s.commit1 == null) {
      return SeaSetupView(
        onReady: (layout, salt) => app.gameSetup(
          widget.chatId,
          m,
          '${layout.encode()}.$salt',
          'h${seaCommit(layout.encode(), salt)}',
        ),
      );
    }
    final canShoot = s.ready && s.winner == null && s.pending == null && s.turn == me;
    // Своё поле после конца у соперника видно из раскрытия.
    final theirShips = s.revealed[1 - me]?.cells ?? <int>{};
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Text(
          'Поле соперника',
          style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        AspectRatio(
          aspectRatio: 1,
          child: SeaBoard(
            key: const ValueKey('sea-enemy'),
            ships: theirShips,
            shots: s.shots[me],
            empty: s.knownEmpty(me),
            pending: s.pending?.$1 == me ? s.pending!.$2 : null,
            onTap: canShoot
                ? (c) {
                    if (s.shots[me].containsKey(c)) return;
                    app.gameMove(widget.chatId, m, 's$c');
                  }
                : null,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 150,
              height: 150,
              child: SeaBoard(ships: mine?.cells ?? const {}, shots: s.shots[1 - me]),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Твоё поле',
                    style: TextStyle(color: vc.text, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Попаданий: ты ${s.hits(me)} из 20, соперник ${s.hits(1 - me)} из 20',
                    style: TextStyle(color: vc.textDim, fontSize: 13, height: 1.35),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Попал — стреляешь ещё. На выстрелы по тебе твой телефон отвечает сам; '
                    'в конце расстановки сверяются.',
                    style: TextStyle(color: vc.textFaint, fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  // ── угадай слово ──

  Widget _word(Message m, int me) {
    final app = context.appRead;
    final vc = context.vc;
    final g = m.game!;
    final w = g.state as WordGame;
    final over = w.winner != null;
    final shown = over || me == 0 ? g.word! : w.masked;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      children: [
        Center(
          child: Wrap(
            spacing: 6,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final ch in shown.split(''))
                Container(
                  width: 34,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: ch == ' ' ? null : vc.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: ch == ' ' ? null : Border.all(color: vc.border),
                  ),
                  child: Text(
                    ch == '_' ? '' : ch,
                    style: TextStyle(
                      color: me == 0 && !over && !w.guessed.contains(ch) ? vc.textFaint : vc.text,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            '${'❤️' * max(0, WordGame.maxWrong - w.wrong)}${'🖤' * min(w.wrong, WordGame.maxWrong)}',
            style: const TextStyle(fontSize: 20),
          ),
        ),
        if (g.hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              'Подсказка: ${g.hint}',
              textAlign: TextAlign.center,
              style: TextStyle(color: vc.textDim),
            ),
          ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          children: [
            for (final l in WordGame.letters.split(''))
              _Key(
                letter: l,
                used: w.guessed.contains(l),
                right: g.word!.contains(l),
                onTap: me == 1 && !over && !w.guessed.contains(l)
                    ? () => app.gameMove(widget.chatId, m, l)
                    : null,
              ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.letter, required this.used, required this.right, this.onTap});

  final String letter;
  final bool used;
  final bool right;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Pressable(
      key: ValueKey('key-$letter'),
      onTap: onTap,
      child: Container(
        width: 38,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: used && right ? acc.gradient : null,
          color: used ? (right ? null : vc.surface.withValues(alpha: 0.4)) : vc.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: vc.border),
        ),
        child: Text(
          letter,
          style: TextStyle(
            color: used ? (right ? acc.onAccent : vc.textFaint) : vc.text,
            fontWeight: FontWeight.w700,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}

/// Расстановка кораблей — отдельным экраном (создатель, до отправки).
class SeaSetupScreen extends StatelessWidget {
  const SeaSetupScreen({super.key, required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: Text(title),
      ),
      body: SafeArea(child: SeaSetupView(onReady: (l, s) => Navigator.of(context).pop((l, s)))),
    );
  }
}

/// Случайная расстановка с «Перемешать» и «Готово».
class SeaSetupView extends StatefulWidget {
  const SeaSetupView({super.key, required this.onReady});

  final void Function(SeaLayout layout, String salt) onReady;

  @override
  State<SeaSetupView> createState() => _SeaSetupViewState();
}

class _SeaSetupViewState extends State<SeaSetupView> {
  SeaLayout _layout = SeaLayout.random();

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        Text(
          'Корабли расставлены случайно и по правилам. Не нравится — перемешай. '
          'Сопернику уйдёт только «отпечаток» расстановки: сама она откроется в '
          'конце, чтобы её нельзя было подменить по ходу игры.',
          style: TextStyle(color: vc.textDim, fontSize: 13.5, height: 1.4),
        ),
        const SizedBox(height: 14),
        AspectRatio(aspectRatio: 1, child: SeaBoard(ships: _layout.cells)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextButton.icon(
                onPressed: () => setState(() => _layout = SeaLayout.random()),
                icon: Icon(Icons.shuffle_rounded, color: vc.textDim),
                label: Text('Перемешать', style: TextStyle(color: vc.textDim)),
              ),
            ),
            Expanded(
              flex: 2,
              child: AccentButton(
                label: 'Готов к бою',
                icon: Icons.check_rounded,
                onTap: () => widget.onReady(_layout, Lot.random()),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}
