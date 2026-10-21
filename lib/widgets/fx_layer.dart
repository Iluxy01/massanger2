import 'dart:math';

import 'package:flutter/material.dart';

import 'visual.dart';

/// Эффект на весь экран: салют, сердечки, снег, бум, конфетти.
///
/// Рисуется одним лёгким CustomPainter'ом только пока идёт (~3 с), потом слой
/// полностью убирается — в остальное время его нет вовсе. При выключенных
/// анимациях эффектов нет.
class FxLayer extends StatefulWidget {
  const FxLayer({super.key, this.shake});

  /// Для «бума» — встряхнуть содержимое (сдвиг в точках).
  final ValueNotifier<Offset>? shake;

  static const names = {
    'fireworks': ('🎆', 'Салют'),
    'hearts': ('💖', 'Сердечки'),
    'snow': ('❄️', 'Снег'),
    'boom': ('💥', 'Бум'),
    'confetti': ('🎉', 'Конфетти'),
  };

  @override
  State<FxLayer> createState() => FxLayerState();
}

class FxLayerState extends State<FxLayer> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this);
  _Fx? _fx;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// Показать эффект [kind] (если анимации не выключены).
  void play(String kind) {
    if (!mounted || Visual.of(context).motion == 0) return;
    final ms = kind == 'boom' ? 1600 : (kind == 'snow' ? 4200 : 3200);
    setState(() => _fx = _Fx(kind, Random()));
    _c
      ..duration = Duration(milliseconds: ms)
      ..forward(from: 0).whenCompleteOrCancel(() {
        if (!mounted) return;
        widget.shake?.value = Offset.zero;
        setState(() => _fx = null);
      });
    if (kind == 'boom' && widget.shake != null) {
      void shake() {
        final t = _c.value;
        if (t > 0.35) {
          widget.shake!.value = Offset.zero;
          _c.removeListener(shake);
          return;
        }
        final k = (1 - t / 0.35) * 9;
        widget.shake!.value = Offset(sin(t * 90) * k, cos(t * 70) * k * 0.6);
      }

      _c.addListener(shake);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fx = _fx;
    if (fx == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _FxPainter(fx, _c), child: const SizedBox.expand()),
      ),
    );
  }
}

class _P {
  _P(this.x, this.y, this.vx, this.vy, this.size, this.color, this.spin, this.delay);

  final double x, y, vx, vy, size, spin, delay;
  final Color color;
}

class _Fx {
  _Fx(this.kind, Random r) {
    const party = [
      Color(0xFFFF4F8B),
      Color(0xFFFFC145),
      Color(0xFF00C2FF),
      Color(0xFF7C5CFF),
      Color(0xFF00C896),
      Color(0xFFFF7A45),
    ];
    switch (kind) {
      case 'confetti':
        for (var i = 0; i < 150; i++) {
          parts.add(
            _P(
              r.nextDouble(),
              -0.05 - r.nextDouble() * 0.5,
              (r.nextDouble() - 0.5) * 0.12,
              0.32 + r.nextDouble() * 0.3,
              5 + r.nextDouble() * 6,
              party[r.nextInt(party.length)],
              (r.nextDouble() - 0.5) * 18,
              0,
            ),
          );
        }
      case 'hearts':
        const pinks = [Color(0xFFFF4F8B), Color(0xFFFF6FA8), Color(0xFFFF2D55), Color(0xFFFF9EC4)];
        for (var i = 0; i < 46; i++) {
          parts.add(
            _P(
              r.nextDouble(),
              1.05 + r.nextDouble() * 0.15,
              (r.nextDouble() - 0.5) * 0.08,
              -(0.28 + r.nextDouble() * 0.3),
              16 + r.nextDouble() * 26,
              pinks[r.nextInt(pinks.length)],
              r.nextDouble() * 6,
              r.nextDouble() * 0.45,
            ),
          );
        }
      case 'snow':
        for (var i = 0; i < 110; i++) {
          parts.add(
            _P(
              r.nextDouble(),
              -0.05 - r.nextDouble() * 0.6,
              (r.nextDouble() - 0.5) * 0.03,
              0.12 + r.nextDouble() * 0.14,
              i % 9 == 0 ? 9 + r.nextDouble() * 6 : 1.8 + r.nextDouble() * 3.2,
              Colors.white,
              r.nextDouble() * 6,
              0,
            ),
          );
        }
      case 'fireworks':
        for (var b = 0; b < 6; b++) {
          final cx = 0.15 + r.nextDouble() * 0.7, cy = 0.12 + r.nextDouble() * 0.4;
          final color = party[r.nextInt(party.length)];
          final delay = b * 0.12 + r.nextDouble() * 0.05;
          for (var i = 0; i < 44; i++) {
            final a = i / 44 * pi * 2 + r.nextDouble() * 0.1;
            final v = 0.18 + r.nextDouble() * 0.12;
            parts.add(
              _P(cx, cy, cos(a) * v, sin(a) * v, 2.2 + r.nextDouble() * 1.6, color, 0, delay),
            );
          }
        }
      case 'boom':
        for (var i = 0; i < 60; i++) {
          final a = r.nextDouble() * pi * 2;
          final v = 0.4 + r.nextDouble() * 0.6;
          parts.add(
            _P(
              0.5,
              0.45,
              cos(a) * v,
              sin(a) * v,
              3 + r.nextDouble() * 5,
              [const Color(0xFFFFC145), const Color(0xFFFF7A45), const Color(0xFFFF3D5A)][i % 3],
              (r.nextDouble() - 0.5) * 12,
              0,
            ),
          );
        }
    }
  }

  final String kind;
  final parts = <_P>[];
}

class _FxPainter extends CustomPainter {
  _FxPainter(this.fx, this.t) : super(repaint: t);

  final _Fx fx;
  final Animation<double> t;

  static final _heart = Path()
    ..moveTo(0, 0.35)
    ..cubicTo(-0.5, -0.05, -0.25, -0.55, 0, -0.25)
    ..cubicTo(0.25, -0.55, 0.5, -0.05, 0, 0.35)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final v = t.value;
    final secs = (t as AnimationController).duration!.inMilliseconds / 1000 * v;
    final w = size.width, h = size.height;
    final paint = Paint();
    // Плавно гаснет в конце.
    final fade = v > 0.8 ? (1 - v) / 0.2 : 1.0;
    switch (fx.kind) {
      case 'confetti':
        for (final p in fx.parts) {
          final y = (p.y + p.vy * secs) * h;
          if (y < -20 || y > h + 20) continue;
          final x = (p.x + p.vx * secs) * w + sin(secs * 3 + p.spin) * 14;
          paint.color = p.color.withValues(alpha: fade);
          canvas
            ..save()
            ..translate(x, y)
            ..rotate(p.spin * secs * 0.4)
            ..scale(1, cos(secs * 5 + p.spin).abs() * 0.8 + 0.2)
            ..drawRect(
              Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.6),
              paint,
            )
            ..restore();
        }
      case 'hearts':
        for (final p in fx.parts) {
          final s = secs - p.delay * 3;
          if (s < 0) continue;
          final y = (p.y + p.vy * s) * h;
          if (y < -50) continue;
          final x = (p.x + p.vx * s) * w + sin(s * 2 + p.spin) * 18;
          final grow = (s * 3).clamp(0.0, 1.0);
          paint.color = p.color.withValues(alpha: 0.9 * fade);
          canvas
            ..save()
            ..translate(x, y)
            ..rotate(sin(s * 2 + p.spin) * 0.25)
            ..scale(p.size * grow)
            ..drawPath(_heart, paint)
            ..restore();
        }
      case 'snow':
        for (final p in fx.parts) {
          final y = (p.y + p.vy * secs) * h;
          if (y < -10 || y > h + 10) continue;
          final x = (p.x + p.vx * secs) * w + sin(secs * 1.5 + p.spin) * 10;
          paint.color = Colors.white.withValues(alpha: 0.85 * fade);
          if (p.size > 8) {
            // Снежинка: шесть лучей.
            paint
              ..strokeWidth = 1.6
              ..strokeCap = StrokeCap.round;
            for (var k = 0; k < 3; k++) {
              final a = k * pi / 3 + secs * 0.5;
              final d = Offset(cos(a), sin(a)) * p.size;
              canvas.drawLine(Offset(x, y) - d, Offset(x, y) + d, paint);
            }
          } else {
            canvas.drawCircle(Offset(x, y), p.size, paint);
          }
        }
      case 'fireworks':
        for (final p in fx.parts) {
          final s = secs - p.delay * 3;
          if (s < 0 || s > 1.6) continue;
          final life = 1 - s / 1.6;
          // Скорость гаснет, частицы падают.
          final dx = p.vx * (1 - exp(-s * 2.5)) / 2.5;
          final dy = p.vy * (1 - exp(-s * 2.5)) / 2.5 + 0.06 * s * s;
          final pos = Offset((p.x + dx) * w, (p.y + dy) * h);
          paint.color = p.color.withValues(alpha: life * fade);
          canvas.drawCircle(pos, p.size * (0.6 + life * 0.6), paint);
          if (s < 0.25) {
            paint.color = Colors.white.withValues(alpha: (1 - s / 0.25) * 0.8);
            canvas.drawCircle(Offset(p.x * w, p.y * h), 10 * (1 - s / 0.25), paint);
          }
        }
      case 'boom':
        final c = Offset(w * 0.5, h * 0.45);
        // Вспышка и две ударные волны.
        if (v < 0.25) {
          paint.color = Colors.white.withValues(alpha: (1 - v / 0.25) * 0.55);
          canvas.drawRect(Offset.zero & size, paint);
        }
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6;
        for (final (k, color) in [(1.0, const Color(0xFFFFC145)), (0.7, const Color(0xFFFF7A45))]) {
          final r = (v * 1.6 * k) * size.longestSide * 0.6;
          paint.color = color.withValues(alpha: (1 - v).clamp(0.0, 1.0) * 0.8);
          canvas.drawCircle(c, r, paint);
        }
        paint.style = PaintingStyle.fill;
        for (final p in fx.parts) {
          final dx = p.vx * secs * 0.9, dy = p.vy * secs * 0.9 + 0.25 * secs * secs;
          paint.color = p.color.withValues(alpha: (1 - v) * 0.95);
          canvas
            ..save()
            ..translate(c.dx + dx * w, c.dy + dy * w)
            ..rotate(p.spin * secs)
            ..drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size), paint)
            ..restore();
        }
    }
  }

  @override
  bool shouldRepaint(_FxPainter old) => old.fx != fx;
}
