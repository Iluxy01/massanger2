import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'palette.dart';
import 'skin.dart';

/// Фон экрана: классическое сияние или фон стиля (Терминал, Космос, Лимонад).
///
/// Главное для плавности и батареи: всё неподвижное (заливка, сетка, туманность,
/// горошек, ореол дыры) один раз рисуется в готовую картинку ([SkyCache]) и
/// дальше выводится одной текстурой — без пересчёта градиентов и размытий на
/// каждом кадре. Живое поверх — только дешёвые операции: все звёзды одной
/// командой (drawRawAtlas), диск и «нимб» чёрной дыры — тоже готовые картинки,
/// которые лишь поворачиваются.
class Sky {
  Sky({required this.skin, required this.c, required this.acc, this.dim = 1, this.aurora = 1});

  final Skin skin;
  final VeilColors c;
  final Accent acc;

  /// Яркость фона стиля (1 — полная).
  final double dim;

  /// Сила классического сияния (0 — чистый фон).
  final double aurora;

  /// Отпечаток всех параметров — для кэша картинок и сравнения.
  late final String id = [
    skin.id,
    for (final k in skin.opts.keys.toList()..sort()) '$k${skin.opts[k]}',
    c.bg.toARGB32(),
    c.text.toARGB32(),
    acc.a.toARGB32(),
    acc.b.toARGB32(),
    // Сила сияния важна только классике, яркость — только стилям: так фон
    // главной и чата у стиля — одна и та же картинка.
    if (skin.id == 0) aurora.toStringAsFixed(3) else dim.toStringAsFixed(3),
  ].join('|');

  /// Есть ли в этом фоне что двигать.
  bool get moves => switch (skin.id) {
    0 => aurora > 0,
    1 => skin.opt('tb') != 2,
    2 => true,
    _ => skin.opt('lb') == 0,
  };

  @override
  bool operator ==(Object other) => other is Sky && other.id == id;

  @override
  int get hashCode => id.hashCode;

  /// Нарисовать фон размером с экран [s]. [t] — фаза движения (0…1),
  /// [moving] — идёт ли сейчас анимация (без неё «бегущая строка» не видна).
  void paint(Canvas canvas, Size s, double dpr, double t, {required bool moving}) {
    switch (skin.id) {
      case 0:
        _aurora(canvas, s, t);
      case 1:
        _image(canvas, SkyCache.get('term|$id', s, dpr, (cv) => _terminalStill(cv, s)), dpr);
        if (moving && skin.opt('tb') != 2) _scanLine(canvas, s, t);
      case 2:
        _image(canvas, SkyCache.get('cosmos|$id', s, dpr, (cv) => _cosmosStill(cv, s)), dpr);
        _cosmosLive(canvas, s, dpr, t);
      default:
        _image(canvas, SkyCache.get('lemon|$id', s, dpr, (cv) => _lemonStill(cv, s)), dpr);
        if (skin.opt('lb') == 0) _blobs(canvas, s, t);
    }
  }

  static final _imagePaint = Paint()..filterQuality = FilterQuality.low;

  /// Картинка из кэша — пиксель в пиксель (размер картинки в точках экрана).
  static void _image(Canvas canvas, ui.Image img, double dpr) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, img.width / dpr, img.height / dpr),
      _imagePaint,
    );
  }

  // ───────────────────────────── Veil (сияние) ─────────────────────────────

  void _aurora(Canvas canvas, Size size, double anim) {
    canvas.drawRect(Offset.zero & size, Paint()..color = c.bg);
    if (aurora <= 0) return;
    final colors = [acc.a, acc.b, Color.lerp(acc.a, const Color(0xFFFF4F8B), 0.5)!];
    final t = anim * 2 * pi;
    const speeds = [1.0, 2.0, 1.0];
    const phases = [0.0, 2.1, 4.2];
    for (var i = 0; i < colors.length; i++) {
      final cx = size.width * (0.5 + 0.38 * sin(t * speeds[i] + phases[i]));
      final cy = size.height * (0.32 + 0.28 * cos(t * speeds[i] * 0.7 + phases[i]) + i * 0.12);
      final r = size.width * (0.75 + 0.15 * sin(t + i));
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colors[i].withValues(alpha: 0.30 * aurora),
              colors[i].withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }
  }

  // ───────────────────────────── Терминал ─────────────────────────────

  /// Сетка или силуэт кода и затемнение по краям — один раз, в картинку.
  void _terminalStill(Canvas canvas, Size s) {
    final accent = acc.a;
    final mode = skin.opt('tb');
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

  /// Строка развёртки — медленно ползёт сверху вниз.
  void _scanLine(Canvas canvas, Size s, double t) {
    final accent = acc.a;
    final y = s.height * ((t * 3) % 1.0);
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
  }

  // ───────────────────────────── Космос ─────────────────────────────

  bool get _hole => skin.opt('ch') == 0;
  int get _starCount => const [90, 170, 260][skin.opt('cs').clamp(0, 2)];

  static Offset _holeAt(Size s) => Offset(s.width * 0.7, s.height * 0.2);
  static double _holeR(Size s) => s.width * 0.12;

  static const _white = Color(0xFFFFF4E6);
  Color get _hot => Color.lerp(acc.b, _white, 0.6)!;

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

  /// Туманность и ореол дыры — один раз, в картинку.
  void _cosmosStill(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = c.bg);
    for (final (x, y, r, col, a) in [
      (0.12, 0.78, 0.95, acc.a, 0.22),
      (0.9, 0.12, 0.75, acc.b, 0.13),
      (0.55, 0.5, 0.6, Color.lerp(acc.a, acc.b, 0.5)!, 0.07),
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
    if (!_hole) return;
    // Ореол: свет, искривлённый гравитацией.
    final o = _holeAt(s);
    final r = _holeR(s);
    final halo = Rect.fromCircle(center: o, radius: r * 3);
    canvas.drawCircle(
      o,
      r * 3,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _hot.withValues(alpha: 0.22 * dim),
            acc.b.withValues(alpha: 0.08 * dim),
            Colors.transparent,
          ],
          stops: const [0.15, 0.5, 1],
        ).createShader(halo),
    );
  }

  /// Звёзды (одной командой) и чёрная дыра (готовые картинки).
  void _cosmosLive(Canvas canvas, Size s, double dpr, double t) {
    final a0 = t * 2 * pi;
    final field = _StarField.of(s, _starCount, _hole);
    final n = field.count;
    if (n > 0) {
      final colors = Int32List(n * 2);
      for (var j = 0; j < n; j++) {
        final i = field.index[j];
        final phase = _field[i].$4;
        final a =
            (0.35 + 0.65 * (0.5 + 0.5 * sin(a0 * (12 + (i % 3) * 6) + phase))) * field.fade[j];
        // Свечение (у мелких звёзд его нет — прозрачное) и сама звезда.
        colors[j * 2] = field.glow[j] ? _alpha(a * 0.35 * dim) : 0;
        colors[j * 2 + 1] = _alpha(a * 0.85 * dim);
      }
      canvas.drawRawAtlas(
        SkyCache.get('sprites|${acc.b.toARGB32()}', const Size(40, 32), 1, _sprites),
        field.transforms,
        field.rects,
        colors,
        BlendMode.modulate,
        null,
        _imagePaint,
      );
    }
    if (_hole) _blackHole(canvas, s, dpr, a0 * 2);
  }

  /// Белый с прозрачностью [a] (для окраски спрайтов).
  static int _alpha(double a) => ((a.clamp(0.0, 1.0) * 255).round() << 24) | 0xFFFFFF;

  /// Спрайты звёзд: белая точка (0…8) и мягкое цветное свечение (8…40).
  void _sprites(Canvas canvas) {
    canvas.drawCircle(const Offset(4, 4), 3.2, Paint()..color = Colors.white);
    const center = Offset(24, 16);
    canvas.drawCircle(
      center,
      16,
      Paint()
        ..shader = RadialGradient(
          colors: [acc.b, acc.b.withValues(alpha: 0.55), acc.b.withValues(alpha: 0)],
          stops: const [0, 0.45, 1],
        ).createShader(Rect.fromCircle(center: center, radius: 16)),
    );
  }

  /// Аккреционный диск в «развёрнутом» виде: кольца, снаружи холоднее, у
  /// горизонта раскалённо-белые. Рисуется один раз; дальше только поворот.
  static double _diskExtent(double r) => r * 3.05;

  void _disk(Canvas canvas, double r) {
    final e = _diskExtent(r);
    canvas.translate(e, e);
    for (final (rad, width, color, alpha, blur) in [
      (1.75, 0.8, acc.a, 0.45, 0.3),
      (1.4, 0.55, acc.b, 0.8, 0.14),
      (1.08, 0.3, _white, 0.95, 0.06),
    ]) {
      final ring = Rect.fromCircle(center: Offset.zero, radius: r * rad);
      canvas.drawCircle(
        Offset.zero,
        r * rad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * width
          ..shader = SweepGradient(
            colors: [
              for (final k in const [1.0, 0.6, 0.9, 0.5, 0.85, 0.65, 1.0])
                color.withValues(alpha: alpha * k * dim),
            ],
          ).createShader(ring)
          // Размытие по вертикали после «наклона» сжимается в 5 раз — даём
          // его с запасом, чтобы край диска остался мягким.
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * blur * 1.6),
      );
    }
  }

  /// «Нимб» (свет, обогнувший дыру), тень и фотонное кольцо.
  static double _coreExtent(double r) => r * 1.3;

  void _core(Canvas canvas, double r) {
    final e = _coreExtent(r);
    final o = Offset(e, e);
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
              _white.withValues(alpha: alpha * dim),
              _hot.withValues(alpha: alpha * 0.6 * dim),
            ],
          ).createShader(Rect.fromCircle(center: o, radius: r * (rad + width)))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.07),
      );
    }
    canvas.drawCircle(o, r * 0.62, Paint()..color = Colors.black);
    canvas.drawCircle(
      o,
      r * 0.64,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = max(1.2, r * 0.03)
        ..color = _white.withValues(alpha: 0.9 * dim)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, max(0.8, r * 0.02)),
    );
  }

  void _blackHole(Canvas canvas, Size s, double dpr, double turn) {
    final o = _holeAt(s);
    final r = _holeR(s);
    final e = _diskExtent(r);
    final disk = SkyCache.get('disk|$id', Size.square(e * 2), dpr, (cv) => _disk(cv, r));
    final diskSrc = Rect.fromLTWH(0, 0, disk.width.toDouble(), disk.height.toDouble());
    final diskDst = Rect.fromCenter(center: Offset.zero, width: e * 2, height: e * 2);

    // Диск наклонён: задняя половина — за дырой, передняя — перед ней.
    // Узор медленно вращается в плоскости диска.
    void half({required bool front}) {
      canvas.save();
      canvas.translate(o.dx, o.dy);
      canvas.rotate(-0.28);
      canvas.scale(1, 0.2);
      // Без сглаживания края: две половинки ложатся встык, без шва.
      canvas.clipRect(
        front ? Rect.fromLTRB(-e, 0, e, e) : Rect.fromLTRB(-e, -e, e, 0),
        doAntiAlias: false,
      );
      canvas.rotate(turn);
      canvas.drawImageRect(disk, diskSrc, diskDst, _imagePaint);
      canvas.restore();
    }

    half(front: false);
    final ce = _coreExtent(r);
    final core = SkyCache.get('core|$id', Size.square(ce * 2), dpr, (cv) => _core(cv, r));
    canvas.drawImageRect(
      core,
      Rect.fromLTWH(0, 0, core.width.toDouble(), core.height.toDouble()),
      Rect.fromLTWH(o.dx - ce, o.dy - ce, core.width / dpr, core.height / dpr),
      _imagePaint,
    );
    half(front: true);
  }

  // ───────────────────────────── Лимонад ─────────────────────────────

  /// Заливка и горошек — один раз, в картинку.
  void _lemonStill(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = c.bg);
    if (skin.opt('lb') != 1) return;
    final dot = Paint()..color = acc.a.withValues(alpha: 0.13 * dim);
    const step = 34.0;
    var row = 0;
    for (var y = step / 2; y < s.height; y += step, row++) {
      for (var x = row.isEven ? step / 2 : step; x < s.width; x += step) {
        canvas.drawCircle(Offset(x, y), 3.2, dot);
      }
    }
  }

  /// Мягкие цветные пятна — медленно плывут.
  void _blobs(Canvas canvas, Size s, double t) {
    final a0 = t * 2 * pi;
    for (final (x, y, r, col, sp) in [
      (0.08, 0.1, 0.6, acc.a, 1.0),
      (0.98, 0.4, 0.5, acc.b, 2.0),
      (0.18, 0.86, 0.62, Color.lerp(acc.a, const Color(0xFF8EE3C8), 0.5)!, 1.0),
      (0.9, 0.97, 0.42, Color.lerp(acc.b, const Color(0xFFFFE08A), 0.5)!, 2.0),
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
}

/// Звёзды, разложенные по экрану заданного размера: положения и размеры
/// считаются один раз, на кадре меняется только яркость.
class _StarField {
  _StarField(Size s, int total, bool hole) {
    final o = Sky._holeAt(s);
    final hr = Sky._holeR(s);
    final idx = <int>[];
    final fades = <double>[];
    for (var i = 0; i < total; i++) {
      final (x, y, _, _) = Sky._field[i];
      final p = Offset(x * s.width, y * s.height);
      var f = 1.0;
      // Рядом с дырой звёзды гаснут — она «съедает» свет.
      if (hole) {
        final d = (p - o).distance / hr;
        if (d < 1.8) continue;
        if (d < 2.8) f = d - 1.8;
      }
      idx.add(i);
      fades.add(f);
    }
    count = idx.length;
    index = Int32List.fromList(idx);
    fade = Float64List.fromList(fades);
    glow = List<bool>.generate(count, (j) => Sky._field[idx[j]].$3 > 1.35);
    transforms = Float32List(count * 2 * 4);
    rects = Float32List(count * 2 * 4);
    for (var j = 0; j < count; j++) {
      final (x, y, size, _) = Sky._field[idx[j]];
      final px = x * s.width;
      final py = y * s.height;
      // Свечение: спрайт 32×32 (центр 16,16) на радиус size·2.2 + мягкий край.
      final g = (size * 2.2 + 3.75) / 16;
      transforms.setAll(j * 8, [g, 0, px - 16 * g, py - 16 * g]);
      rects.setAll(j * 8, [8, 0, 40, 32]);
      // Звезда: спрайт 8×8 (центр 4,4, радиус 3.2) на радиус size.
      final k = size / 3.2;
      transforms.setAll(j * 8 + 4, [k, 0, px - 4 * k, py - 4 * k]);
      rects.setAll(j * 8 + 4, [0, 0, 8, 8]);
    }
  }

  late final int count;
  late final Int32List index;
  late final Float64List fade;
  late final List<bool> glow;
  late final Float32List transforms;
  late final Float32List rects;

  static _StarField? _last;
  static String? _lastKey;

  static _StarField of(Size s, int total, bool hole) {
    final key = '${s.width}x${s.height}|$total|$hole';
    if (key != _lastKey || _last == null) {
      _last = _StarField(s, total, hole);
      _lastKey = key;
    }
    return _last!;
  }
}

/// Готовые картинки фонов. Рисуются один раз и хранятся, пока помещаются в
/// бюджет памяти; старые вытесняются первыми.
class SkyCache {
  static final _items = <String, ui.Image>{};
  static int _bytes = 0;
  static const _budget = 64 << 20;

  static ui.Image get(String key, Size size, double dpr, void Function(Canvas canvas) draw) {
    final k = '$key@${size.width.toStringAsFixed(1)}x${size.height.toStringAsFixed(1)}*$dpr';
    final hit = _items.remove(k);
    if (hit != null) return _items[k] = hit;
    final w = max(1, (size.width * dpr).ceil());
    final h = max(1, (size.height * dpr).ceil());
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec)..scale(dpr);
    draw(canvas);
    final pic = rec.endRecording();
    final img = pic.toImageSync(w, h);
    pic.dispose();
    _items[k] = img;
    _bytes += w * h * 4;
    // Уже нарисованное на экране не пострадает: кадр держит свою ссылку.
    while (_bytes > _budget && _items.length > 1) {
      final old = _items.remove(_items.keys.first)!;
      _bytes -= old.width * old.height * 4;
      old.dispose();
    }
    return img;
  }

  @visibleForTesting
  static int get length => _items.length;
}

/// Рисует [Sky]. Картинки фона — размером с экран [screen] (а не с виджет),
/// поэтому выезжающая клавиатура не заставляет их перерисовывать.
class SkyPainter extends CustomPainter {
  SkyPainter(this.sky, {required this.t, required this.screen, required this.dpr, this.moving})
    : super(repaint: moving == null ? t : Listenable.merge([t, moving]));

  final Sky sky;
  final ValueListenable<double> t;
  final Size screen;
  final double dpr;

  /// Идёт ли анимация сейчас (null — фон неподвижен).
  final ValueListenable<bool>? moving;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width > screen.width + 0.5 || size.height > screen.height + 0.5) {
      canvas.drawRect(Offset.zero & size, Paint()..color = sky.c.bg);
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    sky.paint(canvas, screen, dpr, t.value, moving: moving?.value ?? false);
    canvas.restore();
  }

  @override
  bool shouldRepaint(SkyPainter old) =>
      old.sky != sky ||
      old.screen != screen ||
      old.dpr != dpr ||
      old.moving != moving ||
      old.t != t;
}
