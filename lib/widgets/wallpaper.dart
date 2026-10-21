import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/sky.dart';

/// Готовые фоны чата: название, два цвета градиента, узор (0 — точки, 1 — волны).
const wallpaperPresets = <(String, List<Color>, int)>[
  ('Ночь', [Color(0xFF141E30), Color(0xFF243B55)], 0),
  ('Закат', [Color(0xFFFF7E5F), Color(0xFFFEB47B)], 1),
  ('Глубина', [Color(0xFF43C6AC), Color(0xFF191654)], 0),
  ('Лаванда', [Color(0xFFB993D6), Color(0xFF8CA6DB)], 1),
  ('Океан', [Color(0xFF2193B0), Color(0xFF6DD5ED)], 1),
  ('Графит', [Color(0xFF232526), Color(0xFF414345)], 0),
  ('Персик', [Color(0xFFFFDDE1), Color(0xFFEE9CA7)], 0),
  ('Лес', [Color(0xFF134E5E), Color(0xFF71B280)], 1),
  ('Космос', [Color(0xFF0F0C29), Color(0xFF302B63)], 0),
];

/// Фон отдельного чата: готовый (`p:<номер>`) или своё фото (`f:<путь>`).
///
/// Готовый рисуется один раз в картинку размером с экран (кеш общий с фонами
/// стилей), фото декодируется сразу под ширину экрана. Размер не зависит от
/// клавиатуры — при её появлении ничего не перерисовывается.
class ChatWallpaper extends StatelessWidget {
  const ChatWallpaper({super.key, required this.wallpaper, this.dim = 35, this.size});

  final String wallpaper;

  /// Затемнение своего фото, %.
  final int dim;

  /// Размер картинки; по умолчанию — экран.
  final Size? size;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final s = size ?? mq.size;
    final dpr = mq.devicePixelRatio;
    final Widget child;
    if (wallpaper.startsWith('f:')) {
      final bg = context.vc.bg;
      child = Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: bg),
          Image.file(
            File(wallpaper.substring(2)),
            fit: BoxFit.cover,
            cacheWidth: (s.width * dpr).round(),
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          ColoredBox(color: bg.withValues(alpha: dim.clamp(0, 80) / 100)),
        ],
      );
    } else {
      final i = int.tryParse(wallpaper.startsWith('p:') ? wallpaper.substring(2) : '') ?? 0;
      child = CustomPaint(painter: _PresetPainter(i, s, dpr));
    }
    return RepaintBoundary(
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minWidth: s.width,
          maxWidth: s.width,
          minHeight: s.height,
          maxHeight: s.height,
          child: child,
        ),
      ),
    );
  }
}

class _PresetPainter extends CustomPainter {
  _PresetPainter(this.index, this.screen, this.dpr);

  final int index;
  final Size screen;
  final double dpr;

  (String, List<Color>, int) get _p => wallpaperPresets[index % wallpaperPresets.length];

  @override
  void paint(Canvas canvas, Size size) {
    final img = SkyCache.get('wallpaper|$index', screen, dpr, _draw);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, img.width / dpr, img.height / dpr),
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  void _draw(Canvas canvas) {
    final s = screen;
    final (_, colors, pattern) = _p;
    final rect = Offset.zero & s;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(rect),
    );
    // Мягкие пятна света.
    for (final (c, r) in [
      (Offset(s.width * 0.9, s.height * 0.12), s.width * 0.8),
      (Offset(s.width * 0.05, s.height * 0.8), s.width * 0.9),
    ]) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.white.withValues(alpha: 0.12), Colors.white.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    final ink = Paint()..color = Colors.white.withValues(alpha: 0.07);
    if (pattern == 0) {
      const step = 24.0;
      for (var y = 0.0; y < s.height; y += step) {
        final shift = (y / step).floor().isEven ? 0.0 : step / 2;
        for (var x = shift; x < s.width; x += step) {
          canvas.drawCircle(Offset(x, y), 1.2, ink);
        }
      }
    } else {
      ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      const gap = 34.0;
      for (var y = -gap; y < s.height + gap; y += gap) {
        final path = Path()..moveTo(0, y);
        for (var x = 0.0; x <= s.width; x += 8) {
          path.lineTo(x, y + sin(x / 38) * 7);
        }
        canvas.drawPath(path, ink);
      }
    }
  }

  @override
  bool shouldRepaint(_PresetPainter old) =>
      old.index != index || old.screen != screen || old.dpr != dpr;
}
