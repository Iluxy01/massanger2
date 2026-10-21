import 'dart:math';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../utils.dart' show randomHex;
import '../widgets/draw_views.dart';
import '../widgets/effects.dart';

/// Совместный рисунок: каждый штрих уходит в чат, как только палец отпущен,
/// и появляется у всех. Перерисовывается только то, что поменялось: готовые
/// штрихи — слоем, который трогается лишь при новом штрихе, текущий — своим.
class DrawScreen extends StatefulWidget {
  const DrawScreen({super.key, required this.chatId, required this.msgId});

  final String chatId;
  final String msgId;

  static Route<void> route(String chatId, String msgId) => MaterialPageRoute(
    builder: (_) => DrawScreen(chatId: chatId, msgId: msgId),
  );

  @override
  State<DrawScreen> createState() => _DrawScreenState();
}

class _DrawScreenState extends State<DrawScreen> {
  static const _colors = [
    Color(0xFF1B1B1F),
    Color(0xFFFF3B30),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF00C2FF),
    Color(0xFF3A5BFF),
    Color(0xFF8E5CFF),
    Color(0xFFFF4F8B),
    Color(0xFF8D5B3A),
  ];
  static const _widths = [4, 10, 22];

  late final AppState _app = context.appRead;
  Color _color = _colors.first;
  int _width = _widths[1];
  bool _eraser = false;

  /// Текущий штрих (тысячные доли стороны холста).
  final _live = ValueNotifier<List<int>>(const []);
  int? _pointer;

  /// Сообщение с рисунком — каждый раз из списка: после возврата в
  /// приложение переписка перечитывается, и прежний экземпляр устаревает.
  Message? get _m {
    for (final m in _app.messagesOf(widget.chatId).reversed) {
      if (m.id == widget.msgId) return m.drawing == null ? null : m;
    }
    return null;
  }

  @override
  void dispose() {
    _live.dispose();
    super.dispose();
  }

  int get _strokeWidth => _eraser ? 44 : _width;
  Color get _strokeColor => _eraser ? drawPaper : _color;

  void _down(PointerDownEvent e, double side) {
    if (_pointer != null) return;
    _pointer = e.pointer;
    final p = _q(e.localPosition, side);
    _live.value = [p.$1, p.$2];
  }

  void _move(PointerMoveEvent e, double side) {
    if (e.pointer != _pointer) return;
    final p = _q(e.localPosition, side);
    final pts = _live.value;
    if (pts.length >= 2) {
      final dx = p.$1 - pts[pts.length - 2], dy = p.$2 - pts[pts.length - 1];
      if (dx * dx + dy * dy < 16) return; // меньше ~1.5 точки — не нужно
    }
    final next = [...pts, p.$1, p.$2];
    if (next.length >= Stroke.maxPoints * 2) {
      // Длинный штрих — режем на части, продолжая с той же точки.
      _commit(next);
      _live.value = [p.$1, p.$2];
      return;
    }
    _live.value = next;
  }

  void _up(PointerEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    _commit(_live.value);
    _live.value = const [];
  }

  (int, int) _q(Offset o, double side) {
    int c(double v) => (v / side * 1000).round().clamp(0, 1000);
    return (c(o.dx), c(o.dy));
  }

  void _commit(List<int> pts) {
    final m = _m;
    if (m == null || pts.length < 2) return;
    _app.drawAdd(
      widget.chatId,
      m,
      Stroke(
        id: randomHex(8).toLowerCase(),
        by: _app.myKey,
        color: _strokeColor.toARGB32(),
        width: _strokeWidth,
        pts: pts,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vc = _app.colors;
    final m = _m;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('🎨 Рисунок'),
        actions: [
          IconButton(
            key: const ValueKey('draw-undo'),
            tooltip: 'Отменить свой штрих',
            icon: const Icon(Icons.undo_rounded),
            onPressed: m == null
                ? null
                : () {
                    final cur = _m;
                    if (cur != null) _app.drawUndo(widget.chatId, cur);
                  },
          ),
        ],
      ),
      body: SafeArea(
        child: m == null
            ? Center(
                child: Text('Рисунок удалён', style: TextStyle(color: vc.textDim)),
              )
            : Column(
                children: [
                  Expanded(
                    child: LayoutBuilder(
                      builder: (_, box) {
                        final side = min(box.maxWidth - 24, box.maxHeight - 16);
                        return Center(child: _canvas(m, side));
                      },
                    ),
                  ),
                  _toolbar(),
                ],
              ),
      ),
    );
  }

  Widget _canvas(Message m, double side) {
    final strokes = m.drawing!.strokes;
    return Container(
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: drawPaper,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 16)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Listener(
        key: const ValueKey('draw-canvas'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) => _down(e, side),
        onPointerMove: (e) => _move(e, side),
        onPointerUp: _up,
        onPointerCancel: _up,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Готовые штрихи — перерисовываются, только когда штрих добавили
            // или отменили (свой или чужой).
            RepaintBoundary(
              child: ListenableBuilder(
                listenable: Listenable.merge([_app.drawUpdates, _app]),
                builder: (_, _) => CustomPaint(
                  painter: DrawingPainter(
                    _m?.drawing?.strokes ?? strokes,
                    version: _app.drawUpdates.value,
                  ),
                ),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(painter: LiveStrokePainter(_live, _strokeColor, _strokeWidth)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    final vc = _app.colors;
    final acc = _app.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Glass(
        radius: 22,
        color: vc.elevated,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final c in _colors)
                    ColorDot(
                      color: c,
                      selected: !_eraser && c == _color,
                      onTap: () => setState(() {
                        _color = c;
                        _eraser = false;
                      }),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (final w in _widths)
                  GestureDetector(
                    key: ValueKey('draw-w$w'),
                    onTap: () => setState(() {
                      _width = w;
                      _eraser = false;
                    }),
                    child: Container(
                      width: 44,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: !_eraser && _width == w ? acc.mid.withValues(alpha: 0.18) : null,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Container(
                        width: 4 + w * 0.9,
                        height: 4 + w * 0.9,
                        decoration: BoxDecoration(
                          color: _eraser ? vc.textDim : _color,
                          shape: BoxShape.circle,
                          // Чёрный на тёмной панели иначе не видно.
                          border: Border.all(color: vc.textDim, width: 1),
                        ),
                      ),
                    ),
                  ),
                GestureDetector(
                  key: const ValueKey('draw-eraser'),
                  onTap: () => setState(() => _eraser = !_eraser),
                  child: Container(
                    height: 36,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: _eraser ? acc.mid.withValues(alpha: 0.18) : null,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.auto_fix_normal_rounded, size: 18, color: vc.text),
                        const SizedBox(width: 6),
                        Text('Ластик', style: TextStyle(color: vc.text)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
