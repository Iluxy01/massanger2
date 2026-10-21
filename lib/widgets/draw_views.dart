import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import 'effects.dart';
import 'visual.dart';

/// Цвет «бумаги» совместного рисунка — одинаковый у всех и в любой теме,
/// чтобы цвета штрихов смотрелись одинаково. Ластик рисует им же.
const drawPaper = Color(0xFFFFFDF8);

/// Штрихи рисунка: координаты — тысячные доли стороны квадратного холста.
class DrawingPainter extends CustomPainter {
  DrawingPainter(this.strokes, {this.version = 0});

  final List<Stroke> strokes;

  /// Меняется вместе с набором штрихов (список меняется на месте).
  final int version;

  static void paintStroke(Canvas canvas, Size size, Stroke st) =>
      _paint(canvas, size.width / 1000, st.pts, Color(st.color), st.width * size.width / 1000);

  static void _paint(Canvas canvas, double k, List<int> pts, Color color, double width) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = width
      ..isAntiAlias = true;
    if (pts.length == 2) {
      canvas.drawCircle(
        Offset(pts[0] * k, pts[1] * k),
        width / 2,
        paint..style = PaintingStyle.fill,
      );
      return;
    }
    // Сглаживание: кривые через середины соседних точек.
    final path = Path()..moveTo(pts[0] * k, pts[1] * k);
    for (var i = 2; i + 2 < pts.length; i += 2) {
      final x = pts[i] * k, y = pts[i + 1] * k;
      final nx = pts[i + 2] * k, ny = pts[i + 3] * k;
      path.quadraticBezierTo(x, y, (x + nx) / 2, (y + ny) / 2);
    }
    path.lineTo(pts[pts.length - 2] * k, pts[pts.length - 1] * k);
    canvas.drawPath(path, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (final st in strokes) {
      paintStroke(canvas, size, st);
    }
  }

  @override
  bool shouldRepaint(DrawingPainter old) =>
      old.version != version ||
      !identical(old.strokes, strokes) ||
      old.strokes.length != strokes.length;
}

/// Штрих, который рисуется прямо сейчас (перерисовывается только он).
class LiveStrokePainter extends CustomPainter {
  LiveStrokePainter(this.points, this.color, this.width) : super(repaint: points);

  final ValueNotifier<List<int>> points;
  final Color color;
  final int width;

  @override
  void paint(Canvas canvas, Size size) {
    final pts = points.value;
    if (pts.length < 2) return;
    canvas.clipRect(Offset.zero & size);
    DrawingPainter._paint(canvas, size.width / 1000, pts, color, width * size.width / 1000);
  }

  @override
  bool shouldRepaint(LiveStrokePainter old) =>
      old.points != points || old.color != color || old.width != width;
}

/// Рисунок в пузыре: превью и «Рисовать».
class DrawingContent extends StatelessWidget {
  const DrawingContent({
    super.key,
    required this.m,
    required this.fg,
    required this.meta,
    required this.onOpen,
  });

  final Message m;
  final Color fg;
  final Widget meta;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final d = m.drawing!;
    final authors = {for (final s in d.strokes) s.by}.length;
    final last = d.strokes.isEmpty ? '' : d.strokes.last.id;
    return SizedBox(
      width: 220,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Text('🎨', style: TextStyle(fontSize: 18)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Совместный рисунок',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: onOpen,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 220,
                height: 220,
                color: drawPaper,
                child: d.strokes.isEmpty
                    ? Center(
                        child: Text(
                          'Пока пусто — начни первым',
                          style: TextStyle(color: Colors.black.withValues(alpha: 0.35)),
                        ),
                      )
                    : RepaintBoundary(
                        child: CustomPaint(
                          painter: DrawingPainter(
                            d.strokes,
                            version: Object.hash(d.strokes.length, last),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Pressable(
                onTap: onOpen,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: fg.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: fg.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    'Рисовать',
                    style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              ),
              if (d.strokes.isNotEmpty)
                Text(
                  authors > 1 ? 'Рисуют: $authors' : 'Штрихов: ${d.strokes.length}',
                  style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: meta),
        ],
      ),
    );
  }
}

/// Кнопка-кружок цвета в палитре.
class ColorDot extends StatelessWidget {
  const ColorDot({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
    this.size = 30,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160).by(context),
        width: size,
        height: size,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: selected ? vc.text : vc.border, width: selected ? 3 : 1),
        ),
      ),
    );
  }
}
