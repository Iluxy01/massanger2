import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// «Обложка» при маскировке значка: настоящий рабочий калькулятор или
/// заметки. Veil открывается только кодом входа: в калькуляторе — набрать код
/// и нажать «=», в заметках — ввести код в поиск.
class CoverScreen extends StatelessWidget {
  const CoverScreen({super.key});

  @override
  Widget build(BuildContext context) =>
      context.app.disguise == 2 ? const NotesCover() : const CalculatorCover();
}

// ───────────────────────────── Калькулятор ─────────────────────────────

class CalculatorCover extends StatefulWidget {
  const CalculatorCover({super.key});

  @override
  State<CalculatorCover> createState() => _CalculatorCoverState();
}

class _CalculatorCoverState extends State<CalculatorCover> {
  String _expr = '';
  String _result = '0';

  /// Цифры, набранные подряд с последнего «C» / «=» (это может быть код входа).
  String _typed = '';

  static const _ops = '+−×÷';

  void _tap(String k) {
    setState(() {
      switch (k) {
        case 'C':
          _expr = '';
          _result = '0';
          _typed = '';
        case '⌫':
          if (_expr.isNotEmpty) _expr = _expr.substring(0, _expr.length - 1);
          if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
        case '=':
          final code = _typed;
          _typed = '';
          final v = calc(_expr);
          if (v != null) {
            _result = fmt(v);
            _expr = _result;
          } else {
            _result = 'Ошибка';
          }
          // Код входа — проверяем тихо: неверный ничем себя не выдаёт.
          if (code.length >= 4 && code.length <= 8) context.appRead.tryCover(code);
        case '±':
          final v = calc(_expr);
          if (v != null) _expr = fmt(-v);
        case '%':
          final v = calc(_expr);
          if (v != null) _expr = fmt(v / 100);
        default:
          if (_ops.contains(k)) {
            if (_expr.isEmpty) return;
            if (_ops.contains(_expr[_expr.length - 1])) {
              _expr = _expr.substring(0, _expr.length - 1);
            }
            _expr += k;
          } else {
            _expr += k;
            if (k != ',') _typed += k;
          }
          final v = calc(_expr);
          if (v != null) _result = fmt(v);
      }
    });
  }

  static double? calc(String expr) => CalculatorCoverMath.calc(expr);
  static String fmt(double v) => CalculatorCoverMath.fmt(v);

  @override
  Widget build(BuildContext context) {
    const keys = [
      ['C', '±', '%', '÷'],
      ['7', '8', '9', '×'],
      ['4', '5', '6', '−'],
      ['1', '2', '3', '+'],
      ['⌫', '0', ',', '='],
    ];
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final bg = dark ? const Color(0xFF101214) : const Color(0xFFF4F5F7);
    final fg = dark ? Colors.white : const Color(0xFF1F2328);
    Color keyBg(String k) {
      if (k == '=') return const Color(0xFFFF7043);
      if ('+−×÷'.contains(k)) return dark ? const Color(0xFF37474F) : const Color(0xFFCFD8DC);
      if ('C±%'.contains(k)) return dark ? const Color(0xFF263238) : const Color(0xFFE0E4E8);
      return dark ? const Color(0xFF1C1F23) : Colors.white;
    }

    return Material(
      color: bg,
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _expr.isEmpty ? ' ' : _expr,
                      maxLines: 2,
                      textAlign: TextAlign.right,
                      style: TextStyle(color: fg.withValues(alpha: 0.6), fontSize: 26),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _result,
                        style: TextStyle(color: fg, fontSize: 56, fontWeight: FontWeight.w300),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  for (final row in keys)
                    Row(
                      children: [
                        for (final k in row)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(5),
                              child: AspectRatio(
                                aspectRatio: 1.15,
                                child: Material(
                                  color: keyBg(k),
                                  borderRadius: BorderRadius.circular(18),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(18),
                                    onTap: () => _tap(k),
                                    child: Center(
                                      child: Text(
                                        k,
                                        style: TextStyle(
                                          fontSize: 26,
                                          color: k == '=' ? Colors.white : fg,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Арифметика калькулятора-обложки (× и ÷ раньше + и −).
class CalculatorCoverMath {
  /// Значение выражения. null — не считается (деление на ноль и т. п.).
  static double? calc(String expr) {
    if (expr.isEmpty) return 0;
    var e = expr.replaceAll(',', '.');
    while (e.isNotEmpty && '+−×÷'.contains(e[e.length - 1])) {
      e = e.substring(0, e.length - 1);
    }
    final nums = <double>[];
    final ops = <String>[];
    final buf = StringBuffer();
    for (var i = 0; i < e.length; i++) {
      final ch = e[i];
      if ('+−×÷'.contains(ch) && !(ch == '−' && buf.isEmpty && (i == 0))) {
        final n = double.tryParse(buf.toString());
        if (n == null) return null;
        nums.add(n);
        ops.add(ch);
        buf.clear();
      } else {
        buf.write(ch == '−' ? '-' : ch);
      }
    }
    final last = double.tryParse(buf.toString());
    if (last == null) return null;
    nums.add(last);
    // Сначала × и ÷.
    for (var i = 0; i < ops.length;) {
      if (ops[i] == '×' || ops[i] == '÷') {
        if (ops[i] == '÷' && nums[i + 1] == 0) return null;
        nums[i] = ops[i] == '×' ? nums[i] * nums[i + 1] : nums[i] / nums[i + 1];
        nums.removeAt(i + 1);
        ops.removeAt(i);
      } else {
        i++;
      }
    }
    var r = nums.first;
    for (var i = 0; i < ops.length; i++) {
      r = ops[i] == '+' ? r + nums[i + 1] : r - nums[i + 1];
    }
    return r;
  }

  static String fmt(double v) {
    if (v.isNaN || v.isInfinite) return 'Ошибка';
    if (v == v.roundToDouble() && v.abs() < 1e15) return v.toInt().toString();
    var s = v.toStringAsFixed(8);
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    return s.replaceAll('.', ',');
  }
}

// ───────────────────────────── Заметки ─────────────────────────────

class NotesCover extends StatefulWidget {
  const NotesCover({super.key});

  @override
  State<NotesCover> createState() => _NotesCoverState();
}

class _NotesCoverState extends State<NotesCover> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit([int? index]) async {
    final app = context.appRead;
    final ctrl = TextEditingController(text: index == null ? '' : app.coverNotes[index]);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(index == null ? 'Новая заметка' : 'Заметка'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 10,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          if (index != null)
            TextButton(onPressed: () => Navigator.pop(ctx, ''), child: const Text('Удалить')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (text == null) return;
    setState(() {
      if (index == null) {
        if (text.trim().isNotEmpty) app.coverNotes.insert(0, text.trim());
      } else if (text.trim().isEmpty) {
        app.coverNotes.removeAt(index);
      } else {
        app.coverNotes[index] = text.trim();
      }
    });
    app.saveCoverNotes();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final q = _search.text.trim().toLowerCase();
    final notes = [
      for (final (i, n) in app.coverNotes.indexed)
        if (q.isEmpty || n.toLowerCase().contains(q)) (i, n),
    ];
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final bg = dark ? const Color(0xFF121212) : const Color(0xFFFFFBF0);
    final fg = dark ? Colors.white : const Color(0xFF2B2B2B);
    final card = dark ? const Color(0xFF1E1E1E) : Colors.white;
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: dark ? Brightness.dark : Brightness.light,
        colorSchemeSeed: const Color(0xFFFFC107),
      ),
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          backgroundColor: bg,
          title: Text(
            'Заметки',
            style: TextStyle(color: fg, fontWeight: FontWeight.w700),
          ),
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: const Color(0xFFFFC107),
          onPressed: _edit,
          child: const Icon(Icons.add_rounded, color: Colors.black87),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _search,
                // Код входа — в поиске. Неверный ничем себя не выдаёт.
                onChanged: (v) {
                  setState(() {});
                  final t = v.trim();
                  if (t.length >= 4 && t.length <= 8 && RegExp(r'^\d+$').hasMatch(t)) {
                    app.tryCover(t).then((ok) {
                      if (ok) _search.clear();
                    });
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Поиск',
                  prefixIcon: const Icon(Icons.search_rounded),
                  filled: true,
                  fillColor: card,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            Expanded(
              child: notes.isEmpty
                  ? Center(
                      child: Text(
                        q.isEmpty ? 'Заметок пока нет' : 'Ничего не найдено',
                        style: TextStyle(color: fg.withValues(alpha: 0.5)),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 90),
                      children: [
                        for (final (i, n) in notes)
                          Card(
                            color: card,
                            elevation: 0,
                            margin: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              title: Text(
                                n.split('\n').first,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                              ),
                              subtitle: n.contains('\n')
                                  ? Text(
                                      n.split('\n').skip(1).join(' '),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    )
                                  : null,
                              onTap: () => _edit(i),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
