import 'dart:math';

import 'package:flutter/material.dart';

/// Свой набор стикеров Veil: призрачок «Вейли» под вуалью — 20 эмоций.
///
/// Нарисован кодом (векторно): у получателя он рисуется так же из одного
/// короткого кода стикера — по сети не передаётся ни одной картинки.
class VeilStickers {
  VeilStickers._();

  static const all = <StickerSpec>[
    StickerSpec('hi', 'Привет', '👋', eyes: Eyes.normal, mouth: Mouth.smile, arms: Arms.wave),
    StickerSpec(
      'yay',
      'Ура',
      '🎉',
      eyes: Eyes.happy,
      mouth: Mouth.grin,
      arms: Arms.up,
      prop: Prop.confetti,
    ),
    StickerSpec('love', 'Люблю', '😍', eyes: Eyes.heart, mouth: Mouth.smile, prop: Prop.hearts),
    StickerSpec(
      'lol',
      'Смешно',
      '😂',
      eyes: Eyes.happy,
      mouth: Mouth.laugh,
      prop: Prop.tears,
      tilt: -0.12,
    ),
    StickerSpec('sad', 'Грустно', '😢', eyes: Eyes.sad, mouth: Mouth.frown, prop: Prop.tear),
    StickerSpec(
      'angry',
      'Злюсь',
      '😠',
      eyes: Eyes.angry,
      mouth: Mouth.frown,
      prop: Prop.steam,
      tint: Color(0xFFFFB3B3),
    ),
    StickerSpec('wow', 'Ого', '😮', eyes: Eyes.wide, mouth: Mouth.o, prop: Prop.sparkle),
    StickerSpec(
      'hmm',
      'Хм',
      '🤔',
      eyes: Eyes.up,
      mouth: Mouth.flat,
      arms: Arms.chin,
      prop: Prop.question,
    ),
    StickerSpec('sleep', 'Сплю', '😴', eyes: Eyes.closed, mouth: Mouth.small, prop: Prop.zzz),
    StickerSpec('coffee', 'Кофе', '☕', eyes: Eyes.closed, mouth: Mouth.smile, prop: Prop.coffee),
    StickerSpec('like', 'Класс', '👍', eyes: Eyes.wink, mouth: Mouth.grin, arms: Arms.thumb),
    StickerSpec('cool', 'Круто', '😎', eyes: Eyes.normal, mouth: Mouth.smirk, prop: Prop.glasses),
    StickerSpec('shh', 'Тсс', '🤫', eyes: Eyes.wink, mouth: Mouth.small, arms: Arms.shh),
    StickerSpec(
      'party',
      'Праздник',
      '🥳',
      eyes: Eyes.happy,
      mouth: Mouth.grin,
      prop: Prop.party,
      tilt: 0.1,
    ),
    StickerSpec(
      'hug',
      'Обнимаю',
      '🤗',
      eyes: Eyes.happy,
      mouth: Mouth.smile,
      arms: Arms.hug,
      prop: Prop.hearts,
    ),
    StickerSpec('wait', 'Жду', '⏰', eyes: Eyes.normal, mouth: Mouth.flat, prop: Prop.clock),
    StickerSpec(
      'fire',
      'Огонь',
      '🔥',
      eyes: Eyes.wide,
      mouth: Mouth.grin,
      prop: Prop.fire,
      tint: Color(0xFFFFE2B8),
    ),
    StickerSpec(
      'night',
      'Спокойной ночи',
      '🌙',
      eyes: Eyes.closed,
      mouth: Mouth.smile,
      prop: Prop.moon,
    ),
    StickerSpec('secret', 'Секрет', '🔒', eyes: Eyes.up, mouth: Mouth.small, prop: Prop.lock),
    StickerSpec(
      'thanks',
      'Спасибо',
      '💐',
      eyes: Eyes.happy,
      mouth: Mouth.smile,
      arms: Arms.hold,
      prop: Prop.flowers,
    ),
  ];

  static StickerSpec? byId(String? id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }
}

enum Eyes { normal, happy, closed, heart, wide, sad, angry, wink, up }

enum Mouth { smile, grin, laugh, o, frown, flat, small, smirk }

enum Arms { none, wave, up, chin, thumb, shh, hug, hold }

enum Prop {
  none,
  confetti,
  hearts,
  tears,
  tear,
  steam,
  sparkle,
  question,
  zzz,
  coffee,
  glasses,
  party,
  clock,
  fire,
  moon,
  lock,
  flowers,
}

class StickerSpec {
  const StickerSpec(
    this.id,
    this.label,
    this.emoji, {
    this.eyes = Eyes.normal,
    this.mouth = Mouth.smile,
    this.arms = Arms.none,
    this.prop = Prop.none,
    this.tint,
    this.tilt = 0,
  });

  final String id;
  final String label;
  final String emoji;
  final Eyes eyes;
  final Mouth mouth;
  final Arms arms;
  final Prop prop;

  /// Оттенок «вуали» (по умолчанию — почти белая с лиловым).
  final Color? tint;

  /// Наклон всей фигурки.
  final double tilt;
}

/// Стикер из набора, размером [size].
class VeilSticker extends StatelessWidget {
  const VeilSticker(this.spec, {super.key, this.size = 150});

  final StickerSpec spec;
  final double size;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(size: Size.square(size), painter: StickerPainter(spec)),
  );
}

/// Рисует стикер в квадрате (координаты 0…100).
class StickerPainter extends CustomPainter {
  StickerPainter(this.spec);

  final StickerSpec spec;

  static const _ink = Color(0xFF2A2340);
  static const _blush = Color(0xFFFF8FB1);
  static const _red = Color(0xFFFF4D6A);

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.width / 100;
    canvas.save();
    canvas.scale(k);
    // Мягкая тень на «земле».
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(50, 93), width: 46, height: 7),
      Paint()..color = Colors.black.withValues(alpha: 0.12),
    );
    canvas.save();
    canvas.translate(50, 60);
    canvas.rotate(spec.tilt);
    canvas.translate(-50, -60);
    _back(canvas);
    _body(canvas);
    _arms(canvas);
    _face(canvas);
    canvas.restore();
    _front(canvas);
    canvas.restore();
  }

  // ── Тело: «вуаль» с волнистым краем ──

  static Path _ghost() {
    final p = Path()
      ..moveTo(22, 52)
      ..cubicTo(22, 30, 36, 18, 50, 18)
      ..cubicTo(64, 18, 78, 30, 78, 52)
      ..lineTo(78, 80);
    // Волнистый низ: три «волны».
    const xs = [78.0, 68.7, 59.3, 50.0, 40.7, 31.3, 22.0];
    for (var i = 0; i < xs.length - 1; i++) {
      final mid = (xs[i] + xs[i + 1]) / 2;
      p.quadraticBezierTo(mid, i.isEven ? 90 : 78, xs[i + 1], 84);
    }
    p
      ..lineTo(22, 52)
      ..close();
    return p;
  }

  void _body(Canvas canvas) {
    final path = _ghost();
    // Белая «наклейка» вокруг и контур.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
    final tint = spec.tint ?? const Color(0xFFF1ECFF);
    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Colors.white, tint],
        ).createShader(const Rect.fromLTWH(22, 18, 56, 72)),
    );
    // Блик на макушке.
    canvas.drawPath(
      Path()
        ..moveTo(32, 36)
        ..quadraticBezierTo(36, 26, 46, 23),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..color = _ink,
    );
  }

  // ── Лицо ──

  void _face(Canvas canvas) {
    final ink = Paint()..color = _ink;
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = _ink;
    const l = Offset(41, 48), r = Offset(59, 48);

    void dot(Offset c, {double w = 5.4, double h = 7}) {
      canvas.drawOval(Rect.fromCenter(center: c, width: w, height: h), ink);
      canvas.drawCircle(c + const Offset(-1, -1.6), 1.2, Paint()..color = Colors.white);
    }

    void arc(Offset c, {bool up = true, double w = 7}) {
      final rect = Rect.fromCenter(center: c + Offset(0, up ? 1.5 : -1.5), width: w, height: 6);
      canvas.drawArc(rect, up ? pi : 0, pi, false, line);
    }

    switch (spec.eyes) {
      case Eyes.normal:
        dot(l);
        dot(r);
      case Eyes.happy:
        arc(l);
        arc(r);
      case Eyes.closed:
        arc(l, up: false);
        arc(r, up: false);
      case Eyes.heart:
        _heart(canvas, l, 4.2, _red);
        _heart(canvas, r, 4.2, _red);
      case Eyes.wide:
        for (final c in [l, r]) {
          canvas.drawCircle(c, 4.6, Paint()..color = Colors.white);
          canvas.drawCircle(c, 4.6, line..strokeWidth = 1.8);
          canvas.drawCircle(c, 2.4, ink);
        }
        line.strokeWidth = 2.4;
      case Eyes.sad:
        dot(l, h: 6);
        dot(r, h: 6);
        canvas.drawLine(l + const Offset(-4, -6), l + const Offset(3, -8), line);
        canvas.drawLine(r + const Offset(4, -6), r + const Offset(-3, -8), line);
      case Eyes.angry:
        dot(l, h: 5.5);
        dot(r, h: 5.5);
        canvas.drawLine(l + const Offset(-4, -8), l + const Offset(3, -5), line);
        canvas.drawLine(r + const Offset(4, -8), r + const Offset(-3, -5), line);
      case Eyes.wink:
        dot(l);
        arc(r);
      case Eyes.up:
        for (final c in [l, r]) {
          canvas.drawOval(
            Rect.fromCenter(center: c, width: 6.5, height: 8),
            Paint()..color = Colors.white,
          );
          canvas.drawOval(
            Rect.fromCenter(center: c, width: 6.5, height: 8),
            line..strokeWidth = 1.6,
          );
          canvas.drawCircle(c + const Offset(1.2, -1.8), 2.2, ink);
        }
        line.strokeWidth = 2.4;
    }

    // Румянец.
    if (spec.eyes != Eyes.angry) {
      for (final c in [const Offset(35, 56), const Offset(65, 56)]) {
        canvas.drawOval(
          Rect.fromCenter(center: c, width: 7, height: 3.6),
          Paint()..color = _blush.withValues(alpha: 0.55),
        );
      }
    }

    const m = Offset(50, 58);
    switch (spec.mouth) {
      case Mouth.smile:
        canvas.drawArc(
          Rect.fromCenter(center: m, width: 9, height: 7),
          0.15,
          pi - 0.3,
          false,
          line,
        );
      case Mouth.grin:
      case Mouth.laugh:
        final mouth = Path()
          ..moveTo(m.dx - 6, m.dy - 1.5)
          ..quadraticBezierTo(m.dx, m.dy - 0.5, m.dx + 6, m.dy - 1.5)
          ..quadraticBezierTo(
            m.dx,
            m.dy + (spec.mouth == Mouth.laugh ? 11 : 8),
            m.dx - 6,
            m.dy - 1.5,
          )
          ..close();
        canvas.drawPath(mouth, ink);
        // Язык.
        canvas.save();
        canvas.clipPath(mouth);
        canvas.drawCircle(m + const Offset(0, 7), 4, Paint()..color = const Color(0xFFFF7A93));
        canvas.restore();
      case Mouth.o:
        canvas.drawOval(
          Rect.fromCenter(center: m + const Offset(0, 1), width: 5, height: 6.5),
          ink,
        );
      case Mouth.frown:
        canvas.drawArc(
          Rect.fromCenter(center: m + const Offset(0, 3), width: 8, height: 6),
          pi + 0.3,
          pi - 0.6,
          false,
          line,
        );
      case Mouth.flat:
        canvas.drawLine(m + const Offset(-3.5, 1), m + const Offset(3.5, 0), line);
      case Mouth.small:
        canvas.drawArc(Rect.fromCenter(center: m, width: 5, height: 4), 0.2, pi - 0.4, false, line);
      case Mouth.smirk:
        final p = Path()
          ..moveTo(m.dx - 4, m.dy + 1)
          ..quadraticBezierTo(m.dx + 1, m.dy + 3.5, m.dx + 5, m.dy - 1);
        canvas.drawPath(p, line);
    }
  }

  // ── Ручки ──

  void _hand(Canvas canvas, Offset c, {double r = 5}) {
    canvas.drawCircle(c, r + 3, Paint()..color = Colors.white);
    canvas.drawCircle(c, r, Paint()..color = spec.tint ?? const Color(0xFFF7F4FF));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = _ink,
    );
  }

  void _arms(Canvas canvas) {
    switch (spec.arms) {
      case Arms.none:
        break;
      case Arms.wave:
        _hand(canvas, const Offset(21, 62));
        _hand(canvas, const Offset(84, 40));
        // Взмах.
        final m = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..strokeCap = StrokeCap.round
          ..color = _ink.withValues(alpha: 0.6);
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(84, 40), radius: 10),
          -1.3,
          0.9,
          false,
          m,
        );
        canvas.drawArc(
          Rect.fromCircle(center: const Offset(84, 40), radius: 14),
          -1.2,
          0.7,
          false,
          m,
        );
      case Arms.up:
        _hand(canvas, const Offset(16, 32));
        _hand(canvas, const Offset(84, 32));
      case Arms.chin:
        _hand(canvas, const Offset(21, 64));
        _hand(canvas, const Offset(57, 66), r: 4.5);
      case Arms.thumb:
        _hand(canvas, const Offset(21, 64));
        _thumb(canvas, const Offset(84, 58));
      case Arms.shh:
        _hand(canvas, const Offset(21, 64));
        // Палец у губ.
        _finger(canvas, const Rect.fromLTWH(52.5, 51, 5, 15));
        _hand(canvas, const Offset(55, 69), r: 4.8);
      case Arms.hug:
        _hand(canvas, const Offset(12, 50));
        _hand(canvas, const Offset(88, 50));
      case Arms.hold:
        break; // руки рисуются вместе с предметом
    }
  }

  void _finger(Canvas canvas, Rect r) {
    final f = RRect.fromRectAndRadius(r, Radius.circular(r.width / 2));
    canvas.drawRRect(f.inflate(2.5), Paint()..color = Colors.white);
    canvas.drawRRect(f, Paint()..color = spec.tint ?? const Color(0xFFF7F4FF));
    canvas.drawRRect(
      f,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _ink,
    );
  }

  void _thumb(Canvas canvas, Offset c) {
    // Кулачок и поднятый большой палец.
    _finger(canvas, Rect.fromCenter(center: c + const Offset(0, -9), width: 5.5, height: 11));
    final fist = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: 13, height: 11),
      const Radius.circular(5),
    );
    canvas.drawRRect(fist.inflate(2.5), Paint()..color = Colors.white);
    canvas.drawRRect(fist, Paint()..color = spec.tint ?? const Color(0xFFF7F4FF));
    canvas.drawRRect(
      fist,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..color = _ink,
    );
    final crease = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..color = _ink.withValues(alpha: 0.6);
    canvas.drawLine(c + const Offset(-4, 1), c + const Offset(3, 1), crease);
  }

  // ── Предметы ──

  static void _heart(Canvas canvas, Offset c, double s, Color color, {bool outline = false}) {
    final p = Path()
      ..moveTo(c.dx, c.dy + s)
      ..cubicTo(c.dx - s * 2.2, c.dy - s * 0.4, c.dx - s * 1.1, c.dy - s * 2, c.dx, c.dy - s * 0.7)
      ..cubicTo(c.dx + s * 1.1, c.dy - s * 2, c.dx + s * 2.2, c.dy - s * 0.4, c.dx, c.dy + s)
      ..close();
    if (outline) {
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white,
      );
    }
    canvas.drawPath(p, Paint()..color = color);
  }

  static void _star(Canvas canvas, Offset c, double r, Color color) {
    final p = Path();
    for (var i = 0; i < 8; i++) {
      final a = i * pi / 4 - pi / 2;
      final rr = i.isEven ? r : r * 0.35;
      final pt = c + Offset(cos(a) * rr, sin(a) * rr);
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    p.close();
    canvas.drawPath(p, Paint()..color = color);
  }

  /// Линия с белой «наклеечной» обводкой.
  static void _outlined(Canvas canvas, Path p, double w, Color color) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(
      p,
      paint
        ..color = Colors.white
        ..strokeWidth = w + 3.5,
    );
    canvas.drawPath(
      p,
      paint
        ..color = color
        ..strokeWidth = w,
    );
  }

  /// За фигуркой.
  void _back(Canvas canvas) {
    switch (spec.prop) {
      case Prop.moon:
        final moon = Path.combine(
          PathOperation.difference,
          Path()..addOval(Rect.fromCircle(center: const Offset(80, 22), radius: 12)),
          Path()..addOval(Rect.fromCircle(center: const Offset(87, 17), radius: 10)),
        );
        canvas.drawPath(moon, Paint()..color = const Color(0xFFFFD66B));
        _star(canvas, const Offset(16, 20), 5, const Color(0xFFFFE08A));
        _star(canvas, const Offset(28, 10), 3.5, const Color(0xFFFFE08A));
      case Prop.fire:
        for (final (dx, s) in [(-20.0, 0.75), (20.0, 0.75), (0.0, 1.0)]) {
          final c = Offset(50 + dx, 24 - s * 4);
          final f = Path()
            ..moveTo(c.dx, c.dy - 16 * s)
            ..cubicTo(
              c.dx + 12 * s,
              c.dy - 2 * s,
              c.dx + 10 * s,
              c.dy + 12 * s,
              c.dx,
              c.dy + 12 * s,
            )
            ..cubicTo(
              c.dx - 10 * s,
              c.dy + 12 * s,
              c.dx - 12 * s,
              c.dy - 2 * s,
              c.dx,
              c.dy - 16 * s,
            )
            ..close();
          canvas.drawPath(f, Paint()..color = const Color(0xFFFF7A2F));
          canvas.save();
          canvas.translate(c.dx, c.dy + 5 * s);
          canvas.scale(0.55);
          canvas.translate(-c.dx, -c.dy);
          canvas.drawPath(f, Paint()..color = const Color(0xFFFFD34D));
          canvas.restore();
        }
      default:
        break;
    }
  }

  /// Перед фигуркой.
  void _front(Canvas canvas) {
    switch (spec.prop) {
      case Prop.none:
      case Prop.moon:
      case Prop.fire:
        break;
      case Prop.confetti:
        final rnd = Random(3);
        const colors = [Color(0xFFFF5C8A), Color(0xFF7C5CFF), Color(0xFF2BD99F), Color(0xFFFFC145)];
        for (var i = 0; i < 16; i++) {
          final c = Offset(8 + rnd.nextDouble() * 84, 4 + rnd.nextDouble() * 26);
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(rnd.nextDouble() * pi);
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              const Rect.fromLTWH(-2.2, -1, 4.4, 2),
              const Radius.circular(1),
            ),
            Paint()..color = colors[i % colors.length],
          );
          canvas.restore();
        }
      case Prop.hearts:
        _heart(canvas, const Offset(84, 22), 5, _red, outline: true);
        _heart(canvas, const Offset(16, 28), 3.6, const Color(0xFFFF7FA8), outline: true);
        _heart(canvas, const Offset(75, 9), 2.8, const Color(0xFFFF9EBD), outline: true);
      case Prop.tears:
        for (final (c, a) in [(const Offset(32, 50), -0.6), (const Offset(68, 50), 0.6)]) {
          canvas.save();
          canvas.translate(c.dx, c.dy);
          canvas.rotate(a);
          final drop = Path()
            ..moveTo(0, -5)
            ..quadraticBezierTo(4, 1, 0, 4)
            ..quadraticBezierTo(-4, 1, 0, -5);
          canvas.drawPath(drop, Paint()..color = const Color(0xFF6EC8FF));
          canvas.restore();
        }
      case Prop.tear:
        final drop = Path()
          ..moveTo(60, 53)
          ..quadraticBezierTo(64.5, 60, 60, 63)
          ..quadraticBezierTo(55.5, 60, 60, 53);
        canvas.drawPath(drop, Paint()..color = const Color(0xFF6EC8FF));
      case Prop.steam:
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.6
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFFB9B4C9);
        for (final x in [24.0, 76.0]) {
          final s = Path()
            ..moveTo(x, 20)
            ..quadraticBezierTo(x - 4, 15, x, 11)
            ..quadraticBezierTo(x + 4, 7, x, 3);
          canvas.drawPath(s, p);
        }
      case Prop.sparkle:
        _star(canvas, const Offset(83, 22), 7, const Color(0xFFFFC145));
        _star(canvas, const Offset(17, 30), 5, const Color(0xFF7C5CFF));
        _star(canvas, const Offset(74, 9), 3.5, const Color(0xFFFF7FA8));
      case Prop.question:
        final q = Path()
          ..moveTo(76, 12)
          ..cubicTo(76, 4, 90, 4, 90, 12)
          ..cubicTo(90, 18, 83, 18, 83, 24);
        _outlined(canvas, q, 4, const Color(0xFF7C5CFF));
        canvas.drawCircle(const Offset(83, 31), 4, Paint()..color = Colors.white);
        canvas.drawCircle(const Offset(83, 31), 2.4, Paint()..color = const Color(0xFF7C5CFF));
      case Prop.zzz:
        for (final (x, y, h) in [(72.0, 22.0, 6.0), (79.0, 10.0, 8.0), (86.0, -4.0, 10.0)]) {
          final z = Path()
            ..moveTo(x, y)
            ..lineTo(x + h, y)
            ..lineTo(x, y + h)
            ..lineTo(x + h, y + h);
          _outlined(canvas, z, h * 0.32, const Color(0xFF7C5CFF));
        }
      case Prop.coffee:
        // Кружка в «руках».
        final cup = RRect.fromRectAndCorners(
          const Rect.fromLTWH(38, 64, 24, 20),
          bottomLeft: const Radius.circular(7),
          bottomRight: const Radius.circular(7),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        );
        canvas.drawRRect(cup.inflate(3), Paint()..color = Colors.white);
        canvas.drawCircle(const Offset(64, 73), 8, Paint()..color = Colors.white);
        canvas.drawCircle(
          const Offset(63, 73),
          5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = const Color(0xFFB0643A),
        );
        canvas.drawRRect(cup, Paint()..color = const Color(0xFFD9824E));
        canvas.drawRect(
          const Rect.fromLTWH(38, 70, 24, 4),
          Paint()..color = const Color(0xFFF2B28A),
        );
        _hand(canvas, const Offset(36, 76), r: 4.2);
      case Prop.glasses:
        final frame = Paint()..color = _ink;
        for (final c in [const Offset(41, 47), const Offset(59, 47)]) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromCenter(center: c, width: 15, height: 10),
              const Radius.circular(4),
            ),
            frame,
          );
          canvas.drawLine(
            c + const Offset(-4, -2),
            c + const Offset(-1, -3.5),
            Paint()
              ..strokeWidth = 1.4
              ..strokeCap = StrokeCap.round
              ..color = Colors.white.withValues(alpha: 0.8),
          );
        }
        canvas.drawLine(
          const Offset(47, 46),
          const Offset(53, 46),
          Paint()
            ..strokeWidth = 2
            ..color = _ink,
        );
      case Prop.party:
        final hat = Path()
          ..moveTo(50, 2)
          ..lineTo(62, 24)
          ..lineTo(38, 24)
          ..close();
        canvas.drawPath(
          hat,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4
            ..strokeJoin = StrokeJoin.round
            ..color = Colors.white,
        );
        canvas.drawPath(
          hat,
          Paint()
            ..shader = const LinearGradient(
              colors: [Color(0xFFFF5C8A), Color(0xFF7C5CFF)],
            ).createShader(const Rect.fromLTWH(38, 2, 24, 22)),
        );
        for (final y in [10.0, 17.0]) {
          canvas.drawCircle(
            Offset(50 + (y - 13) * 0.3, y),
            1.8,
            Paint()..color = const Color(0xFFFFE08A),
          );
        }
        canvas.drawCircle(const Offset(50, 2), 3.2, Paint()..color = const Color(0xFFFFC145));
      case Prop.clock:
        const c = Offset(82, 24);
        canvas.drawCircle(c, 13, Paint()..color = Colors.white);
        canvas.drawCircle(c, 10.5, Paint()..color = const Color(0xFFFFF4D6));
        canvas.drawCircle(
          c,
          10.5,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..color = _ink,
        );
        final hand = Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = _ink;
        canvas.drawLine(c, c + const Offset(0, -6.5), hand);
        canvas.drawLine(c, c + const Offset(5, 2), hand);
      case Prop.lock:
        const body = Rect.fromLTWH(70, 18, 20, 16);
        canvas.drawRRect(
          RRect.fromRectAndRadius(body.inflate(3), const Radius.circular(6)),
          Paint()..color = Colors.white,
        );
        canvas.drawArc(
          const Rect.fromLTWH(73.5, 8, 13, 18),
          pi,
          pi,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 7
            ..color = Colors.white,
        );
        canvas.drawArc(
          const Rect.fromLTWH(73.5, 8, 13, 18),
          pi,
          pi,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..color = _ink,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(body, const Radius.circular(4)),
          Paint()
            ..shader = const LinearGradient(
              colors: [Color(0xFF7C5CFF), Color(0xFF00C2FF)],
            ).createShader(body),
        );
        canvas.drawCircle(const Offset(80, 25), 2.2, Paint()..color = Colors.white);
      case Prop.flowers:
        // Букетик в руках — ниже лица.
        final stems = Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF27B37F);
        for (final dx in [-6.0, 0.0, 6.0]) {
          canvas.drawLine(Offset(50 + dx, 72), const Offset(50, 86), stems);
        }
        for (final (c, col) in [
          (const Offset(43, 70), const Color(0xFFFF7FA8)),
          (const Offset(57, 70), const Color(0xFFFFC145)),
          (const Offset(50, 66), const Color(0xFFB08CFF)),
        ]) {
          canvas.drawCircle(c, 6.5, Paint()..color = Colors.white);
          for (var i = 0; i < 5; i++) {
            final a = i * 2 * pi / 5 - pi / 2;
            canvas.drawCircle(c + Offset(cos(a) * 2.8, sin(a) * 2.8), 2.5, Paint()..color = col);
          }
          canvas.drawCircle(c, 1.7, Paint()..color = const Color(0xFFFFF4D6));
        }
        _hand(canvas, const Offset(45, 83), r: 4);
        _hand(canvas, const Offset(55, 83), r: 4);
    }
  }

  @override
  bool shouldRepaint(StickerPainter old) => old.spec != spec;
}
