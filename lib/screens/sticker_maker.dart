import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../state/app_state.dart';
import '../widgets/effects.dart';

/// Стикер из своего фото: обвести пальцем то, что вырезать (или взять фото
/// целиком). Получается PNG 512×512 с прозрачным фоном и белой «наклеечной»
/// обводкой — как настоящий стикер.
class StickerMaker extends StatefulWidget {
  const StickerMaker({super.key, required this.path});

  final String path;

  /// Вернёт путь готового стикера (уже в «Моих стикерах») или null.
  static Route<String> route(String path) =>
      MaterialPageRoute(builder: (_) => StickerMaker(path: path), fullscreenDialog: true);

  /// Готовый стикер: [shape] — контур в координатах [image]. null — целиком
  /// (скруглённый квадрат).
  static Future<List<int>?> render(ui.Image image, Path? shape) async {
    const out = 512.0, pad = 26.0, border = 14.0;
    final full = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final path =
        shape ??
        (Path()
          ..addRRect(RRect.fromRectAndRadius(full, Radius.circular(full.shortestSide * 0.12))));
    final box = path.getBounds().intersect(full);
    if (box.width < 8 || box.height < 8) return null;
    final k = (out - 2 * pad) / max(box.width, box.height);
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.translate(out / 2, out / 2);
    canvas.scale(k);
    canvas.translate(-box.center.dx, -box.center.dy);
    // Белая обводка вокруг вырезанного — толщиной border точек итоговой картинки.
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = border * 2 / k
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white,
    );
    canvas.drawPath(path, Paint()..color = Colors.white);
    canvas.save();
    canvas.clipPath(path);
    canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    canvas.restore();
    final pic = rec.endRecording();
    final img = await pic.toImage(out.toInt(), out.toInt());
    pic.dispose();
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    return png?.buffer.asUint8List();
  }

  @override
  State<StickerMaker> createState() => _StickerMakerState();
}

class _StickerMakerState extends State<StickerMaker> {
  ui.Image? _image;
  final _points = <Offset>[]; // в координатах картинки
  bool _closed = false;
  bool _busy = false;
  bool _failed = false;

  /// Картинка на экране: масштаб и сдвиг (для перевода касаний).
  double _scale = 1;
  Offset _origin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.path).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final desc = await ui.ImageDescriptor.encoded(buffer);
      // Большие фото уменьшаем: и быстрее, и памяти меньше.
      final big = max(desc.width, desc.height);
      final codec = await desc.instantiateCodec(
        targetWidth: big > 1400 && desc.width >= desc.height ? 1400 : null,
        targetHeight: big > 1400 && desc.height > desc.width ? 1400 : null,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      desc.dispose();
      buffer.dispose();
      if (!mounted) {
        frame.image.dispose();
        return;
      }
      setState(() => _image = frame.image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Offset _toImage(Offset local) => (local - _origin) / _scale;

  void _start(DragStartDetails d) {
    setState(() {
      _points
        ..clear()
        ..add(_toImage(d.localPosition));
      _closed = false;
    });
  }

  void _move(DragUpdateDetails d) {
    final p = _toImage(d.localPosition);
    // Точки не чаще, чем через пару пикселей — контур ровнее и легче.
    if ((p - _points.last).distance * _scale < 3) return;
    setState(() => _points.add(p));
  }

  void _end(DragEndDetails _) {
    setState(() => _closed = _points.length > 8);
    if (!_closed) _points.clear();
  }

  Path? get _shape {
    if (!_closed || _points.length < 3) return null;
    final p = Path()..moveTo(_points.first.dx, _points.first.dy);
    for (final pt in _points.skip(1)) {
      p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  Future<void> _done({required bool whole}) async {
    final image = _image;
    if (image == null || _busy) return;
    final shape = whole ? null : _shape;
    if (!whole && shape == null) return;
    setState(() => _busy = true);
    final app = context.appRead;
    final png = await StickerMaker.render(image, shape);
    if (png == null) {
      if (mounted) {
        setState(() => _busy = false);
        showVeilToast(context, 'Слишком маленький кусочек — обведи побольше');
      }
      return;
    }
    final tmp = await getTemporaryDirectory();
    final f = File('${tmp.path}/sticker_${DateTime.now().millisecondsSinceEpoch}.png');
    await f.writeAsBytes(png);
    final saved = await app.addToCollection(f.path, gif: false);
    try {
      await f.delete();
    } catch (_) {}
    if (!mounted) return;
    app.tick(HapticKind.medium);
    Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    final image = _image;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Новый стикер'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Text(
                _closed
                    ? 'Так будет вырезано. Не то — обведи заново.'
                    : 'Обведи пальцем то, что станет стикером',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
            Expanded(
              child: _failed
                  ? const Center(
                      child: Text(
                        'Не получилось открыть фото',
                        style: TextStyle(color: Colors.white70),
                      ),
                    )
                  : image == null
                  ? const Center(child: CircularProgressIndicator(color: Colors.white))
                  : LayoutBuilder(
                      builder: (context, box) {
                        final s = min(box.maxWidth / image.width, box.maxHeight / image.height);
                        _scale = s;
                        _origin = Offset(
                          (box.maxWidth - image.width * s) / 2,
                          (box.maxHeight - image.height * s) / 2,
                        );
                        return GestureDetector(
                          onPanStart: _start,
                          onPanUpdate: _move,
                          onPanEnd: _end,
                          child: CustomPaint(
                            size: box.biggest,
                            painter: _MakerPainter(
                              image: image,
                              scale: s,
                              origin: _origin,
                              points: _points,
                              closed: _closed,
                              color: acc.mid,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton.icon(
                      onPressed: image == null || _busy ? null : () => _done(whole: true),
                      icon: const Icon(Icons.crop_square_rounded, color: Colors.white70),
                      label: const Text('Целиком', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: AccentButton(
                      label: _busy ? 'Делаю…' : 'Готово',
                      icon: Icons.auto_awesome_rounded,
                      onTap: _closed && !_busy ? () => _done(whole: false) : null,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              'Стикер сохранится в «Мои стикеры»',
              style: TextStyle(color: vc.textFaint, fontSize: 12),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _MakerPainter extends CustomPainter {
  _MakerPainter({
    required this.image,
    required this.scale,
    required this.origin,
    required this.points,
    required this.closed,
    required this.color,
  }) : _count = points.length;

  final ui.Image image;
  final double scale;
  final Offset origin;
  final List<Offset> points;
  final bool closed;
  final Color color;
  final int _count;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    final full = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.medium);
    if (points.length > 1) {
      final p = Path()..moveTo(points.first.dx, points.first.dy);
      for (final pt in points.skip(1)) {
        p.lineTo(pt.dx, pt.dy);
      }
      if (closed) {
        p.close();
        // Всё, что не войдёт в стикер, — затемнено.
        canvas.drawPath(
          Path.combine(PathOperation.difference, Path()..addRect(full), p),
          Paint()..color = Colors.black.withValues(alpha: 0.6),
        );
      }
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 / scale
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round
          ..color = closed ? Colors.white : color,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MakerPainter old) =>
      old._count != _count ||
      old.closed != closed ||
      old.image != image ||
      old.scale != scale ||
      old.origin != origin;
}
