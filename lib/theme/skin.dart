import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'palette.dart';

/// Стиль всего приложения: не только цвета, но и формы, обводки, шрифт,
/// фон и характер анимаций.
///
///   0 «Veil» — классический (сияние, стекло);
///   1 «Терминал» — тёмный, строгий, моноширинный, резкие быстрые анимации;
///   2 «Космос» — звёзды, туманность и чёрная дыра, плавные «невесомые» анимации;
///   3 «Лимонад» — светлый и тёплый, мягкие формы, пружинистые анимации.
///
/// У каждого стиля свои мелкие настройки ([opts], ключи — см. [Skin.options]).
class Skin {
  const Skin._({
    required this.id,
    required this.colors,
    required this.accent,
    required this.radius,
    required this.avatarRadius,
    required this.border,
    required this.speed,
    required this.press,
    required this.appear,
    this.font,
    this.monoMessages = false,
    this.glow = false,
    this.shadow = false,
    this.outlineMine = false,
    required this.opts,
  });

  final int id;

  /// null — цвета/акцент из обычных настроек (классический стиль).
  final VeilColors? colors;
  final Accent? accent;

  /// Множитель скруглений: панели, кнопки, пузыри.
  final double radius;

  /// Скругление аватарки (доля размера): 0.5 — круг.
  final double avatarRadius;

  /// Толщина обводок панелей.
  final double border;

  /// Темп анимаций (больше — медленнее).
  final double speed;

  /// Насколько «вжимаются» кнопки при нажатии (1 — как в классике).
  final double press;

  /// Как появляются новые сообщения.
  final Appear appear;

  /// Шрифт всего приложения (null — системный).
  final String? font;

  /// Моноширинный только в сообщениях.
  final bool monoMessages;

  /// Свечение вокруг акцентных элементов (Космос).
  final bool glow;

  /// Мягкие тени под панелями (Лимонад).
  final bool shadow;

  /// Свои сообщения — контуром, а не заливкой (Терминал).
  final bool outlineMine;

  final Map<String, int> opts;

  int opt(String k) => opts[k] ?? 0;

  static const names = ['Veil', 'Терминал', 'Космос', 'Лимонад'];
  static const hints = [
    'Сияние и матовое стекло',
    'Тёмный и строгий: моноширинный шрифт, чёткие линии',
    'Звёзды, туманность и чёрная дыра',
    'Светлый и тёплый, мягкие формы',
  ];

  /// Мелкие настройки каждого стиля.
  static const options = <int, List<SkinOption>>{
    1: [
      SkinOption(
        'tc',
        'Цвет',
        Icons.palette_rounded,
        ['Зелёный', 'Янтарный', 'Циан'],
        ['Как на старых мониторах', 'Тёплый янтарный экран', 'Холодный ночной неон'],
      ),
      SkinOption(
        'tb',
        'Фон',
        Icons.grid_4x4_rounded,
        ['Сетка', 'Код', 'Чистый'],
        ['Точечная сетка и бегущая строка', 'Силуэт кода и бегущая строка', 'Только тёмный фон'],
      ),
      SkinOption(
        'tf',
        'Моноширинный шрифт',
        Icons.text_fields_rounded,
        ['Везде', 'В сообщениях'],
        ['Во всём приложении', 'Только в переписке'],
      ),
    ],
    2: [
      SkinOption(
        'cn',
        'Туманность',
        Icons.blur_on_rounded,
        ['Фиолетовая', 'Синяя', 'Алая'],
        ['Фиолетовая с розовым', 'Синяя с бирюзой', 'Алая с золотом'],
      ),
      SkinOption(
        'ch',
        'Чёрная дыра',
        Icons.lens_blur_rounded,
        ['Есть', 'Нет'],
        ['С аккреционным диском и кольцом света', 'Только звёзды и туманность'],
      ),
      SkinOption(
        'cs',
        'Звёзды',
        Icons.auto_awesome_rounded,
        ['Мало', 'Средне', 'Много'],
        ['Тихое небо', 'Как за городом', 'Млечный Путь'],
      ),
    ],
    3: [
      SkinOption(
        'lt',
        'Вкус',
        Icons.local_drink_rounded,
        ['Лимон', 'Арбуз', 'Мята'],
        ['Солнечный жёлтый', 'Розовый с персиком', 'Свежий зелёный'],
      ),
      SkinOption(
        'lb',
        'Фон',
        Icons.bubble_chart_rounded,
        ['Пятна', 'Горошек', 'Чистый'],
        ['Мягкие цветные пятна', 'Аккуратный горошек', 'Только светлый фон'],
      ),
      SkinOption(
        'la',
        'Движения',
        Icons.waves_rounded,
        ['Мягкие', 'Пружинистые'],
        ['Плавно и спокойно', 'С лёгким отскоком'],
      ),
    ],
  };

  static const classic = Skin._(
    id: 0,
    colors: null,
    accent: null,
    radius: 1,
    avatarRadius: 0.5,
    border: 1,
    speed: 1,
    press: 1,
    appear: Appear.rise,
    opts: {},
  );

  static Skin of(int id, Map<String, int> opts) {
    int o(String k) => opts[k] ?? 0;
    switch (id) {
      case 1:
        const accents = [
          Accent('Зелёный', Color(0xFF3DFF9A), Color(0xFF00C9A7), onAccent: Color(0xFF03130B)),
          Accent('Янтарный', Color(0xFFFFB627), Color(0xFFFF7A1A), onAccent: Color(0xFF1C0F00)),
          Accent('Циан', Color(0xFF2CE5FF), Color(0xFF4D8BFF), onAccent: Color(0xFF02101A)),
        ];
        return Skin._(
          id: 1,
          colors: _terminal,
          accent: accents[o('tc').clamp(0, 2)],
          radius: 0.28,
          avatarRadius: 0.16,
          border: 1,
          speed: 0.65,
          press: 0.4,
          appear: Appear.type,
          font: o('tf') == 0 ? 'monospace' : null,
          monoMessages: true,
          outlineMine: true,
          opts: opts,
        );
      case 2:
        const accents = [
          Accent('Фиолетовая', Color(0xFF8B5CFF), Color(0xFFFF5CC8)),
          Accent('Синяя', Color(0xFF3D7BFF), Color(0xFF22E1FF)),
          Accent('Алая', Color(0xFFFF4D6D), Color(0xFFFF9E3D)),
        ];
        return Skin._(
          id: 2,
          colors: _cosmos,
          accent: accents[o('cn').clamp(0, 2)],
          radius: 1.15,
          avatarRadius: 0.5,
          border: 1,
          speed: 1.35,
          press: 0.8,
          appear: Appear.float,
          glow: true,
          opts: opts,
        );
      case 3:
        const accents = [
          Accent('Лимон', Color(0xFFFFC93C), Color(0xFFFF8A3D), onAccent: Color(0xFF3A2400)),
          Accent('Арбуз', Color(0xFFFF5E7E), Color(0xFFFF9A6B)),
          Accent('Мята', Color(0xFF2FCB98), Color(0xFF1FA8D8)),
        ];
        return Skin._(
          id: 3,
          colors: _lemonade,
          accent: accents[o('lt').clamp(0, 2)],
          radius: 1.3,
          avatarRadius: 0.36,
          border: 0,
          speed: 1,
          press: 1.6,
          appear: o('la') == 1 ? Appear.bounce : Appear.pop,
          shadow: true,
          opts: opts,
        );
      default:
        return classic;
    }
  }

  static const _terminal = VeilColors(
    dark: true,
    bg: Color(0xFF07090A),
    surface: Color(0xFF0D1112),
    elevated: Color(0xFF141A1B),
    border: Color(0x2E9FD8C0),
    text: Color(0xFFDDE7E2),
    textDim: Color(0xFF889A92),
    textFaint: Color(0xFF4F5E58),
    bubbleIn: Color(0xFF0E1314),
    glass: Color(0xE607090A),
    panel: Color(0xF00B0F10),
  );

  static const _cosmos = VeilColors(
    dark: true,
    bg: Color(0xFF03030A),
    surface: Color(0xFF0B0B19),
    elevated: Color(0xFF141429),
    border: Color(0x26A9B4FF),
    text: Color(0xFFEDECFF),
    textDim: Color(0xFF9C9BC6),
    textFaint: Color(0xFF5D5C88),
    bubbleIn: Color(0xFF12122A),
    glass: Color(0xB30A0A18),
    panel: Color(0xE00C0C1C),
  );

  static const _lemonade = VeilColors(
    dark: false,
    bg: Color(0xFFFFF8EC),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFF0D6),
    border: Color(0x14603A00),
    text: Color(0xFF2B2118),
    textDim: Color(0xFF7D6B57),
    textFaint: Color(0xFFB8A790),
    bubbleIn: Color(0xFFFFFFFF),
    glass: Color(0xD9FFFFFF),
    panel: Color(0xF2FFFFFF),
  );

  /// Есть ли что рисовать в живом слое фона, когда он неподвижен (у
  /// Терминала там только бегущая строка — без движения её не нужно).
  bool get stillLayer => id != 1;

  /// Кривая «обычного» движения для стиля.
  Curve get curve => switch (id) {
    1 => Curves.easeOutQuart,
    2 => Curves.easeInOutCubic,
    3 => Curves.easeOutBack,
    _ => Curves.easeOutCubic,
  };
}

/// Мелкая настройка стиля: ключ в настройках, название, значок, варианты и
/// подсказки к ним.
class SkinOption {
  const SkinOption(this.key, this.title, this.icon, this.labels, this.hints);

  final String key;
  final String title;
  final IconData icon;
  final List<String> labels;
  final List<String> hints;
}

/// Как появляется новое сообщение.
enum Appear {
  /// Классика: снизу с лёгким увеличением.
  rise,

  /// Терминал: «печатается» слева направо, быстро.
  type,

  /// Космос: медленно всплывает из глубины.
  float,

  /// Лимонад: мягкий «поп».
  pop,

  /// Лимонад, пружинистые: «поп» с отскоком.
  bounce,
}

// ───────────────────────────── Фоны стилей ─────────────────────────────
//
// Фон рисуется двумя слоями: неподвижный ([live] = false: заливка, сетка,
// туманность) кэшируется и не перерисовывается вовсе; живой ([live] = true:
// звёзды, диск чёрной дыры, строка развёртки, пятна) — только он и движется.

/// Художник фона для стиля [skin] (не для классического).
CustomPainter skinPainter(
  Skin skin,
  VeilColors c,
  Accent acc,
  ValueListenable<double> t, {
  required bool live,
  double dim = 1,
}) => switch (skin.id) {
  1 => TerminalPainter(t, c: c, accent: acc.a, mode: skin.opt('tb'), live: live, dim: dim),
  2 => CosmosPainter(
    t,
    c: c,
    accent: acc,
    hole: skin.opt('ch') == 0,
    stars: skin.opt('cs') == 0 ? 0 : (skin.opt('cs') == 1 ? 1 : 2),
    live: live,
    dim: dim,
  ),
  _ => LemonadePainter(t, c: c, accent: acc, mode: skin.opt('lb'), live: live, dim: dim),
};

/// Фон «Терминала»: точечная сетка или силуэт кода, медленная «строка
/// развёртки», затемнение по краям.
class TerminalPainter extends CustomPainter {
  TerminalPainter(
    this.t, {
    required this.c,
    required this.accent,
    required this.mode,
    required this.live,
    this.dim = 1,
  }) : super(repaint: live ? t : null);

  final ValueListenable<double> t;
  final VeilColors c;
  final Color accent;

  /// 0 — сетка, 1 — код, 2 — чисто.
  final int mode;
  final bool live;
  final double dim;

  @override
  void paint(Canvas canvas, Size s) {
    if (live) {
      if (mode == 2) return;
      // Строка развёртки — медленно ползёт сверху вниз.
      final y = s.height * ((t.value * 3) % 1.0);
      final band = Rect.fromLTWH(0, y - 90, s.width, 180);
      canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              accent.withValues(alpha: 0),
              accent.withValues(alpha: 0.05 * dim),
              accent.withValues(alpha: 0),
            ],
          ).createShader(band),
      );
      return;
    }
    canvas.drawRect(Offset.zero & s, Paint()..color = c.bg);
    if (mode == 0) {
      final dot = Paint()..color = accent.withValues(alpha: 0.08 * dim);
      const step = 22.0;
      for (var y = step / 2; y < s.height; y += step) {
        for (var x = step / 2; x < s.width; x += step) {
          canvas.drawRect(Rect.fromCenter(center: Offset(x, y), width: 1.5, height: 1.5), dot);
        }
      }
    } else if (mode == 1) {
      // Силуэт кода: строки разной длины с отступами — без букв, только ритм.
      final rnd = Random(7);
      final bar = Paint();
      const line = 18.0;
      var indent = 0;
      for (var y = 24.0; y < s.height; y += line) {
        if (rnd.nextDouble() < 0.12) {
          indent = max(0, indent - 1);
          continue;
        }
        var x = 18.0 + indent * 16;
        final words = 1 + rnd.nextInt(5);
        for (var w = 0; w < words && x < s.width - 30; w++) {
          final len = 14.0 + rnd.nextInt(56);
          final strong = rnd.nextDouble() < 0.18;
          bar.color = (strong ? accent : c.text).withValues(alpha: (strong ? 0.10 : 0.05) * dim);
          canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(x, y, len, 4), const Radius.circular(2)),
            bar,
          );
          x += len + 8;
        }
        if (rnd.nextDouble() < 0.2) indent = min(4, indent + 1);
      }
    }
    // Затемнение по краям — как у старого монитора, очень слегка.
    final r = Offset.zero & s;
    canvas.drawRect(
      r,
      Paint()
        ..shader = RadialGradient(
          radius: 0.95,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.5 * dim),
          ],
          stops: const [0.55, 1],
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(TerminalPainter old) =>
      old.mode != mode ||
      old.accent != accent ||
      old.c != c ||
      old.dim != dim ||
      old.live != live ||
      old.t != t;
}

/// Фон «Космоса»: туманность, мерцающие звёзды и чёрная дыра с аккреционным
/// диском и кольцом света вокруг горизонта событий.
class CosmosPainter extends CustomPainter {
  CosmosPainter(
    this.t, {
    required this.c,
    required this.accent,
    required this.hole,
    required this.stars,
    required this.live,
    this.dim = 1,
  }) : super(repaint: live ? t : null);

  final ValueListenable<double> t;
  final VeilColors c;
  final Accent accent;
  final bool hole;

  /// 0 — мало, 1 — средне, 2 — много.
  final int stars;
  final bool live;
  final double dim;

  /// Звёзды: x, y, размер, фаза мерцания. Одни и те же при каждом запуске.
  static final List<(double, double, double, double)> _field = () {
    final r = Random(42);
    return [
      for (var i = 0; i < 260; i++)
        (
          r.nextDouble(),
          r.nextDouble(),
          0.35 + pow(r.nextDouble(), 3) * 1.6,
          r.nextDouble() * 2 * pi,
        ),
    ];
  }();

  @override
  void paint(Canvas canvas, Size s) {
    final holeC = Offset(s.width * 0.7, s.height * 0.2);
    final holeR = s.width * 0.12;
    if (!live) {
      canvas.drawRect(Offset.zero & s, Paint()..color = c.bg);
      // Туманность — несколько мягких облаков.
      for (final (x, y, r, col, a) in [
        (0.12, 0.78, 0.95, accent.a, 0.22),
        (0.9, 0.12, 0.75, accent.b, 0.13),
        (0.55, 0.5, 0.6, Color.lerp(accent.a, accent.b, 0.5)!, 0.07),
      ]) {
        final center = Offset(s.width * x, s.height * y);
        final rad = s.width * r;
        canvas.drawCircle(
          center,
          rad,
          Paint()
            ..shader = RadialGradient(
              colors: [
                col.withValues(alpha: a * dim),
                col.withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: center, radius: rad)),
        );
      }
      return;
    }
    final a0 = t.value * 2 * pi;

    // Звёзды мерцают каждая в своём ритме.
    final count = const [90, 170, 260][stars.clamp(0, 2)];
    final star = Paint();
    // Крупные звёзды — с мягким цветным свечением.
    final glow = Paint()..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
    for (var i = 0; i < count; i++) {
      final (x, y, size, phase) = _field[i];
      final p = Offset(x * s.width, y * s.height);
      var a = 0.35 + 0.65 * (0.5 + 0.5 * sin(a0 * (12 + (i % 3) * 6) + phase));
      // Рядом с дырой звёзды гаснут — она «съедает» свет.
      if (hole) {
        final d = (p - holeC).distance / holeR;
        if (d < 1.8) continue;
        if (d < 2.8) a *= d - 1.8;
      }
      if (size > 1.35) {
        canvas.drawCircle(p, size * 2.2, glow..color = accent.b.withValues(alpha: a * 0.35 * dim));
      }
      star.color = Colors.white.withValues(alpha: a * 0.85 * dim);
      canvas.drawCircle(p, size, star);
    }
    if (hole) _blackHole(canvas, holeC, holeR, a0 * 2);
  }

  void _blackHole(Canvas canvas, Offset o, double r, double turn) {
    const white = Color(0xFFFFF4E6);
    final hot = Color.lerp(accent.b, white, 0.6)!;
    // Ореол: свет, искривлённый гравитацией.
    final halo = Rect.fromCircle(center: o, radius: r * 3);
    canvas.drawCircle(
      o,
      r * 3,
      Paint()
        ..shader = RadialGradient(
          colors: [
            hot.withValues(alpha: 0.22 * dim),
            accent.b.withValues(alpha: 0.08 * dim),
            Colors.transparent,
          ],
          stops: const [0.15, 0.5, 1],
        ).createShader(halo),
    );

    // Аккреционный диск — наклонённые кольца: снаружи холоднее, у горизонта
    // раскалённо-белый. Узор медленно вращается. Задняя половина — за дырой,
    // передняя — перед ней.
    void disk({required bool front}) {
      canvas.save();
      canvas.translate(o.dx, o.dy);
      canvas.rotate(-0.28);
      canvas.scale(1, 0.2);
      for (final (rad, width, color, alpha, blur) in [
        (1.75, 0.8, accent.a, 0.45, 0.3),
        (1.4, 0.55, accent.b, 0.8, 0.14),
        (1.08, 0.3, white, 0.95, 0.06),
      ]) {
        final ring = Rect.fromCircle(center: Offset.zero, radius: r * rad);
        canvas.drawArc(
          ring,
          front ? 0 : pi,
          pi,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * width
            ..shader = SweepGradient(
              transform: GradientRotation(turn),
              colors: [
                for (final k in const [1.0, 0.6, 0.9, 0.5, 0.85, 0.65, 1.0])
                  color.withValues(alpha: alpha * k * dim),
              ],
            ).createShader(ring)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * blur),
        );
      }
      canvas.restore();
    }

    disk(front: false);
    // Свет дальней части диска, обогнувший дыру: широкая дуга сверху и
    // тонкая снизу — тот самый «нимб» вокруг тени.
    for (final (start, rad, width, alpha) in [(pi, 0.86, 0.3, 0.75), (0.0, 0.76, 0.12, 0.45)]) {
      canvas.drawArc(
        Rect.fromCircle(center: o, radius: r * rad),
        start,
        pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * width
          ..shader = RadialGradient(
            colors: [
              white.withValues(alpha: alpha * dim),
              hot.withValues(alpha: alpha * 0.6 * dim),
            ],
          ).createShader(Rect.fromCircle(center: o, radius: r * (rad + width)))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.07),
      );
    }
    // Тень (горизонт событий) с мягким краем.
    canvas.drawCircle(o, r * 0.62, Paint()..color = Colors.black);
    // Фотонное кольцо — тонкое и яркое.
    canvas.drawCircle(
      o,
      r * 0.64,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.2, r * 0.03)
        ..color = white.withValues(alpha: 0.9 * dim)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, max(0.8, r * 0.02)),
    );
    disk(front: true);
  }

  @override
  bool shouldRepaint(CosmosPainter old) =>
      old.hole != hole ||
      old.stars != stars ||
      old.accent != accent ||
      old.c != c ||
      old.dim != dim ||
      old.live != live ||
      old.t != t;
}

/// Фон «Лимонада»: мягкие плывущие пятна или аккуратный горошек.
class LemonadePainter extends CustomPainter {
  LemonadePainter(
    this.t, {
    required this.c,
    required this.accent,
    required this.mode,
    required this.live,
    this.dim = 1,
  }) : super(repaint: live ? t : null);

  final ValueListenable<double> t;
  final VeilColors c;
  final Accent accent;

  /// 0 — пятна, 1 — горошек, 2 — чисто.
  final int mode;
  final bool live;
  final double dim;

  @override
  void paint(Canvas canvas, Size s) {
    if (!live) {
      canvas.drawRect(Offset.zero & s, Paint()..color = c.bg);
      if (mode == 1) {
        final dot = Paint()..color = accent.a.withValues(alpha: 0.13 * dim);
        const step = 34.0;
        var row = 0;
        for (var y = step / 2; y < s.height; y += step, row++) {
          for (var x = row.isEven ? step / 2 : step; x < s.width; x += step) {
            canvas.drawCircle(Offset(x, y), 3.2, dot);
          }
        }
      }
      return;
    }
    if (mode != 0) return;
    final a0 = t.value * 2 * pi;
    for (final (x, y, r, col, sp) in [
      (0.08, 0.1, 0.6, accent.a, 1.0),
      (0.98, 0.4, 0.5, accent.b, 2.0),
      (0.18, 0.86, 0.62, Color.lerp(accent.a, const Color(0xFF8EE3C8), 0.5)!, 1.0),
      (0.9, 0.97, 0.42, Color.lerp(accent.b, const Color(0xFFFFE08A), 0.5)!, 2.0),
    ]) {
      final center = Offset(
        s.width * (x + 0.05 * sin(a0 * sp + x * 7)),
        s.height * (y + 0.03 * cos(a0 * sp + y * 5)),
      );
      final rad = s.width * r;
      canvas.drawCircle(
        center,
        rad,
        Paint()
          ..shader = RadialGradient(
            colors: [
              col.withValues(alpha: 0.3 * dim),
              col.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: rad)),
      );
    }
  }

  @override
  bool shouldRepaint(LemonadePainter old) =>
      old.mode != mode ||
      old.accent != accent ||
      old.c != c ||
      old.dim != dim ||
      old.live != live ||
      old.t != t;
}
