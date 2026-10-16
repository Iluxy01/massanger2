import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/media_tools.dart';
import '../models/models.dart';
import '../screens/media_viewer.dart';
import '../state/app_state.dart';
import '../utils.dart';
import 'effects.dart';
import 'visual.dart';

/// Состояние файла в сообщении.
enum Xfer { ready, uploading, downloading, needDownload, failed, missing }

Xfer xferOf(AppState app, Message m) {
  final att = m.att;
  if (att == null) return Xfer.ready;
  final busy = app.transfers.containsKey(m.id);
  final failed = app.failedTransfers.contains(m.id);
  final local = att.local && (app.demo || File(att.path!).existsSync());
  if (m.mine) {
    if (!local) return Xfer.missing;
    if (att.uploaded || app.demo) return Xfer.ready;
    if (failed && !busy) return Xfer.failed;
    return Xfer.uploading;
  }
  if (local) return Xfer.ready;
  if (busy) return Xfer.downloading;
  if (failed) return Xfer.failed;
  return Xfer.needDownload;
}

/// Нажатие на незагруженный файл: скачать или повторить.
void startTransfer(BuildContext context, String chatId, Message m) {
  final app = context.appRead;
  if (app.demo) {
    showVeilToast(context, 'В демо файлы не передаются', icon: Icons.cloud_off_rounded);
    return;
  }
  app.tick(HapticKind.light);
  m.mine ? app.retrySend(chatId, m) : app.download(chatId, m);
}

/// Кольцо прогресса / кнопка «скачать» / «повторить» поверх превью.
class TransferBadge extends StatelessWidget {
  const TransferBadge({
    super.key,
    required this.m,
    required this.chatId,
    required this.state,
    this.size = 48,
    this.dark = true,
  });

  final Message m;
  final String chatId;
  final Xfer state;
  final double size;

  /// Тёмная подложка (на картинке) или цвета акцента (в пузыре).
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final acc = app.accent;
    final fg = dark ? Colors.white : acc.onAccent;
    final bg = dark ? Colors.black.withValues(alpha: 0.45) : null;
    final progress = app.transfers[m.id];
    final icon = switch (state) {
      Xfer.needDownload => Icons.arrow_downward_rounded,
      Xfer.failed => Icons.refresh_rounded,
      Xfer.missing => Icons.block_rounded,
      Xfer.uploading || Xfer.downloading => Icons.close_rounded,
      Xfer.ready => Icons.check_rounded,
    };
    final busy = state == Xfer.uploading || state == Xfer.downloading;
    return Pressable(
      scale: 0.88,
      haptic: false,
      onTap: state == Xfer.needDownload || state == Xfer.failed
          ? () => startTransfer(context, chatId, m)
          : null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          gradient: dark ? null : acc.gradient,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (busy)
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: progress == null
                      ? CircularProgressIndicator(strokeWidth: 2.5, color: fg)
                      : ValueListenableBuilder<double>(
                          valueListenable: progress,
                          builder: (_, v, _) => TweenAnimationBuilder<double>(
                            tween: Tween(end: v),
                            duration: const Duration(milliseconds: 250).by(context),
                            builder: (_, t, _) => CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: fg,
                              backgroundColor: fg.withValues(alpha: 0.2),
                              value: t <= 0 ? null : max(0.04, t),
                            ),
                          ),
                        ),
                ),
              ),
            if (!busy) Icon(icon, color: fg, size: size * 0.5),
            // Сколько уже ушло/пришло — цифрой в центре кольца.
            if (busy && progress != null)
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (_, v, _) => v <= 0
                    ? Icon(Icons.lock_rounded, color: fg.withValues(alpha: 0.9), size: size * 0.32)
                    : Text(
                        '${(v * 100).floor()}%',
                        style: TextStyle(
                          color: fg,
                          fontSize: size * 0.25,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
              )
            else if (busy)
              Icon(Icons.lock_rounded, color: fg.withValues(alpha: 0.9), size: size * 0.32),
          ],
        ),
      ),
    );
  }
}

/// Строка «время ✓✓» поверх картинки (тёмная плашка).
class MetaPill extends StatelessWidget {
  const MetaPill({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.42),
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );
}

// ───────────────────────────── Фото и видео ─────────────────────────────

/// Фото или видео в пузыре: превью, прогресс, длительность. Нажатие — на весь экран.
class VisualMedia extends StatelessWidget {
  const VisualMedia({
    super.key,
    required this.m,
    required this.chatId,
    required this.width,
    required this.radius,
    this.overlayMeta,
  });

  final Message m;
  final String chatId;
  final double width;
  final BorderRadius radius;

  /// Время и галочки поверх картинки (если нет подписи).
  final Widget? overlayMeta;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final att = m.att!;
    final state = xferOf(app, m);
    final video = m.kind == MsgKind.video;
    final aspect = att.width > 0 && att.height > 0
        ? (att.width / att.height).clamp(0.62, 1.9)
        : (video ? 16 / 9 : 4 / 3);
    final height = width / aspect;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    Widget picture;
    if (state == Xfer.ready || state == Xfer.uploading) {
      picture = video
          ? _VideoFrame(path: att.path!, thumb: att.thumb)
          : Image.file(
              File(att.path!),
              fit: BoxFit.cover,
              cacheWidth: (width * dpr).round(),
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => _Placeholder(thumb: att.thumb, video: video),
            );
    } else {
      picture = _Placeholder(thumb: att.thumb, video: video);
    }

    final tappable = state == Xfer.ready;
    return Pressable(
      scale: 0.97,
      haptic: false,
      onTap: tappable
          ? () => Navigator.of(context).push(MediaViewer.route(m, chatId))
          : (state == Xfer.needDownload || state == Xfer.failed)
          ? () => startTransfer(context, chatId, m)
          : null,
      child: ClipRRect(
        borderRadius: radius,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(tag: 'media-${m.id}', child: picture),
              if (state != Xfer.ready)
                Center(
                  child: TransferBadge(m: m, chatId: chatId, state: state),
                )
              else if (video)
                Center(
                  child: Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1.5),
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                  ),
                ),
              if (video || state == Xfer.needDownload)
                Positioned(
                  left: 8,
                  top: 8,
                  child: MetaPill(
                    child: Text(
                      [
                        if (video && att.duration > 0) fmtDuration(att.duration),
                        if (state != Xfer.ready) fmtSize(att.size),
                      ].join(' · '),
                      style: const TextStyle(color: Colors.white, fontSize: 11.5),
                    ),
                  ),
                ),
              if (overlayMeta != null)
                Positioned(right: 8, bottom: 6, child: MetaPill(child: overlayMeta!)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Размытое превью, пока файла нет (или градиент, если превью тоже нет).
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.thumb, required this.video});
  final String? thumb;
  final bool video;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final t = thumb;
    if (t != null) {
      try {
        return ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6, tileMode: TileMode.clamp),
          child: Image.memory(base64.decode(t), fit: BoxFit.cover, gaplessPlayback: true),
        );
      } catch (_) {}
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [acc.a.withValues(alpha: 0.55), acc.b.withValues(alpha: 0.35)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          video ? Icons.movie_rounded : Icons.photo_rounded,
          size: 40,
          color: Colors.white.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

/// Первый кадр видео. Плеер создаётся, только пока пузырь на экране.
class _VideoFrame extends StatefulWidget {
  const _VideoFrame({required this.path, this.thumb});
  final String path;
  final String? thumb;

  @override
  State<_VideoFrame> createState() => _VideoFrameState();
}

class _VideoFrameState extends State<_VideoFrame> {
  VideoPlayerController? _c;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    if (context.appRead.demo) return;
    final c = _c = VideoPlayerController.file(File(widget.path));
    c
        .initialize()
        .then((_) {
          if (mounted) setState(() => _ready = true);
        })
        .catchError((_) {});
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null || !_ready) return _Placeholder(thumb: widget.thumb, video: true);
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: c.value.size.width,
        height: c.value.size.height,
        child: VideoPlayer(c),
      ),
    );
  }
}

// ───────────────────────────── Документ ─────────────────────────────

({IconData icon, List<Color> colors}) fileStyle(String ext) => switch (ext) {
  'pdf' => (
    icon: Icons.picture_as_pdf_rounded,
    colors: const [Color(0xFFFF5F6D), Color(0xFFFFC371)],
  ),
  'zip' ||
  'rar' ||
  '7z' => (icon: Icons.folder_zip_rounded, colors: const [Color(0xFFF7B733), Color(0xFFFC4A1A)]),
  'doc' ||
  'docx' ||
  'txt' => (icon: Icons.description_rounded, colors: const [Color(0xFF4568DC), Color(0xFF00C2FF)]),
  'xls' ||
  'xlsx' => (icon: Icons.grid_on_rounded, colors: const [Color(0xFF11998E), Color(0xFF38EF7D)]),
  'ppt' ||
  'pptx' => (icon: Icons.slideshow_rounded, colors: const [Color(0xFFFF512F), Color(0xFFDD2476)]),
  'mp3' ||
  'm4a' ||
  'ogg' ||
  'wav' => (icon: Icons.music_note_rounded, colors: const [Color(0xFFB06AB3), Color(0xFF4568DC)]),
  'apk' => (icon: Icons.android_rounded, colors: const [Color(0xFF00C896), Color(0xFF0098E6)]),
  _ => (
    icon: Icons.insert_drive_file_rounded,
    colors: const [Color(0xFF7C5CFF), Color(0xFF00C2FF)],
  ),
};

Future<void> openAttachment(BuildContext context, Message m) async {
  final att = m.att!;
  final ok = await openExternally(att.path!, att.mime);
  if (ok || !context.mounted) return;
  showVeilToast(
    context,
    'Нет приложения, чтобы открыть — можно поделиться',
    icon: Icons.ios_share_rounded,
  );
  await shareFile(att.path!);
}

class FileContent extends StatelessWidget {
  const FileContent({
    super.key,
    required this.m,
    required this.chatId,
    required this.fg,
    required this.meta,
  });

  final Message m;
  final String chatId;
  final Color fg;
  final Widget meta;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final att = m.att!;
    final state = xferOf(app, m);
    final style = fileStyle(att.ext);
    final status = switch (state) {
      Xfer.ready => m.mine ? fmtSize(att.size) : '${fmtSize(att.size)} · открыть',
      Xfer.needDownload => '${fmtSize(att.size)} · скачать',
      Xfer.failed => m.mine ? 'не отправлено · повторить' : 'не скачалось · повторить',
      Xfer.missing => 'файл удалён с телефона',
      Xfer.uploading => 'отправка…',
      Xfer.downloading => 'загрузка…',
    };
    return Pressable(
      scale: 0.97,
      haptic: false,
      onTap: switch (state) {
        Xfer.ready => () => openAttachment(context, m),
        Xfer.needDownload || Xfer.failed => () => startTransfer(context, chatId, m),
        _ => null,
      },
      child: SizedBox(
        width: 250,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          gradient: LinearGradient(colors: style.colors),
                        ),
                      ),
                      if (state == Xfer.ready || state == Xfer.missing)
                        Icon(style.icon, color: Colors.white, size: 26)
                      else
                        TransferBadge(m: m, chatId: chatId, state: state, size: 44),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        att.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      const SizedBox(height: 2),
                      _ProgressText(m: m, base: status, color: fg.withValues(alpha: 0.7)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            meta,
          ],
        ),
      ),
    );
  }
}

/// «загрузка… 45%» — обновляется без перестройки всего пузыря.
class _ProgressText extends StatelessWidget {
  const _ProgressText({required this.m, required this.base, required this.color});
  final Message m;
  final String base;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: color, fontSize: 12.5);
    final p = context.app.transfers[m.id];
    if (p == null) return Text(base, style: style);
    return ValueListenableBuilder<double>(
      valueListenable: p,
      builder: (_, v, _) =>
          Text('$base ${(v * 100).round()}% из ${fmtSize(m.att!.size)}', style: style),
    );
  }
}

// ───────────────────────────── Голосовое ─────────────────────────────

/// Настоящее голосовое: проигрывание, форма волны, перемотка касанием.
class VoiceMessage extends StatefulWidget {
  const VoiceMessage({
    super.key,
    required this.m,
    required this.chatId,
    required this.fg,
    required this.meta,
  });

  final Message m;
  final String chatId;
  final Color fg;
  final Widget meta;

  @override
  State<VoiceMessage> createState() => _VoiceMessageState();
}

class _VoiceMessageState extends State<VoiceMessage> {
  /// Одновременно играет только одно голосовое.
  static _VoiceMessageState? _playing;

  VideoPlayerController? _c;
  double _pos = 0;
  bool _play = false;

  List<double> get _bars {
    final w = widget.m.att?.wave;
    if (w != null && w.isNotEmpty) return [for (final v in w) max(0.12, v / 31)];
    return waveform(widget.m.id, 32);
  }

  @override
  void dispose() {
    if (_playing == this) _playing = null;
    _c?.dispose();
    super.dispose();
  }

  void _tick() {
    final c = _c;
    if (c == null || !mounted) return;
    final v = c.value;
    final total = v.duration.inMilliseconds;
    final done = total > 0 && v.position.inMilliseconds >= total - 80 && !v.isPlaying;
    setState(() {
      _play = v.isPlaying && !done;
      _pos = total > 0 ? (v.position.inMilliseconds / total).clamp(0, 1) : 0;
      if (done) _pos = 0;
    });
    if (done) c.seekTo(Duration.zero);
  }

  Future<void> _toggle() async {
    final app = context.appRead;
    app.tick(HapticKind.selection);
    if (app.demo) return;
    var c = _c;
    if (c == null) {
      c = _c = VideoPlayerController.file(File(widget.m.att!.path!));
      c.addListener(_tick);
      try {
        await c.initialize();
      } catch (_) {
        if (mounted) {
          showVeilToast(context, 'Не получилось воспроизвести', icon: Icons.error_outline_rounded);
        }
        return;
      }
    }
    if (c.value.isPlaying) {
      await c.pause();
    } else {
      if (_playing != null && _playing != this) await _playing!._c?.pause();
      _playing = this;
      await c.play();
    }
  }

  Future<void> _seek(double x) async {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    await c.seekTo(c.value.duration * x.clamp(0, 1));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final m = widget.m;
    final fg = widget.fg;
    final acc = app.accent;
    final state = xferOf(app, m);
    final bars = _bars;
    final secs = m.seconds;
    final shown = _play || _pos > 0 ? (secs * _pos).floor() : secs;

    Widget button;
    if (state == Xfer.ready || state == Xfer.uploading && m.mine) {
      button = Pressable(
        scale: 0.85,
        haptic: false,
        onTap: state == Xfer.ready ? _toggle : null,
        child: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: m.mine ? Colors.white.withValues(alpha: 0.22) : null,
            gradient: m.mine ? null : acc.gradient,
          ),
          child: state == Xfer.uploading
              ? Padding(
                  padding: const EdgeInsets.all(10),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: m.mine ? fg : acc.onAccent,
                  ),
                )
              : AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200).by(context),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: Icon(
                    _play ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    key: ValueKey(_play),
                    color: m.mine ? fg : acc.onAccent,
                  ),
                ),
        ),
      );
    } else {
      button = TransferBadge(m: m, chatId: widget.chatId, state: state, size: 42, dark: false);
    }

    return SizedBox(
      width: 236,
      child: Row(
        children: [
          button,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (_, box) => GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _seek(d.localPosition.dx / box.maxWidth),
                    onHorizontalDragUpdate: (d) => _seek(d.localPosition.dx / box.maxWidth),
                    child: SizedBox(
                      height: 30,
                      child: Row(
                        children: [
                          for (var i = 0; i < bars.length; i++)
                            Expanded(
                              child: Center(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160).by(context),
                                  width: 3,
                                  height: 4 + 24 * bars[i],
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(2),
                                    color: (i + 0.5) / bars.length <= _pos && (_play || _pos > 0)
                                        ? (m.mine ? fg : acc.a)
                                        : fg.withValues(alpha: 0.35),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        state == Xfer.needDownload || state == Xfer.downloading
                            ? '${fmtDuration(secs)} · ${fmtSize(m.att!.size)}'
                            : fmtDuration(shown),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.8),
                          fontSize: 12,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    widget.meta,
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Геопозиция ─────────────────────────────

/// Карта вокруг точки из готовых плиток (без отдельной библиотеки карт).
class MapPreview extends StatelessWidget {
  const MapPreview({
    super.key,
    required this.point,
    required this.width,
    required this.height,
    this.zoom = 15,
  });

  final GeoPoint point;
  final double width;
  final double height;
  final int zoom;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    // В демо и в «Ультра» плитки карты не грузим — рисуем схему.
    final demo = context.appRead.demo || context.appRead.ultra;
    const tile = 256.0;
    final t = tileOf(point.lat, point.lng, zoom);
    // Пиксель точки в «мире» плиток; центр карты — на точке.
    final px = t.x * tile, py = t.y * tile;
    final left = px - width / 2, top = py - height / 2;
    final x0 = (left / tile).floor(), x1 = ((left + width) / tile).floor();
    final y0 = (top / tile).floor(), y1 = ((top + height) / tile).floor();
    final n = 1 << zoom;
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned.fill(
            child: ColoredBox(color: vc.dark ? const Color(0xFF1B1C22) : const Color(0xFFE9E6DF)),
          ),
          if (!demo)
            for (var x = x0; x <= x1; x++)
              for (var y = y0; y <= y1; y++)
                if (y >= 0 && y < n)
                  Positioned(
                    left: x * tile - left,
                    top: y * tile - top,
                    width: tile,
                    height: tile,
                    child: Image.network(
                      tileUrl(x % n, y, zoom, dark: vc.dark),
                      headers: tileHeaders,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox(),
                    ),
                  ),
          if (demo) Positioned.fill(child: CustomPaint(painter: _FakeMapPainter(vc.dark))),
          // Пин с мягкой «волной» точности.
          Center(
            child: Transform.translate(
              offset: const Offset(0, -14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: acc.gradient,
                      border: Border.all(color: Colors.white, width: 2.5),
                      boxShadow: [
                        BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8),
                      ],
                    ),
                    child: Icon(Icons.person_pin_circle_rounded, size: 16, color: acc.onAccent),
                  ),
                  Container(width: 2.5, height: 10, color: Colors.white),
                ],
              ),
            ),
          ),
          Positioned(
            right: 4,
            bottom: 2,
            child: Text(
              '© OpenStreetMap · CARTO',
              style: TextStyle(
                fontSize: 8,
                color: (vc.dark ? Colors.white : Colors.black).withValues(alpha: 0.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Условная «карта» для демо (без сети).
class _FakeMapPainter extends CustomPainter {
  _FakeMapPainter(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final road = Paint()
      ..color = dark ? const Color(0xFF2E3038) : Colors.white
      ..strokeWidth = 7
      ..style = PaintingStyle.stroke;
    final park = Paint()..color = dark ? const Color(0xFF1F3A2E) : const Color(0xFFCFE8C9);
    canvas.drawCircle(Offset(size.width * 0.2, size.height * 0.3), 34, park);
    canvas.drawLine(Offset(0, size.height * 0.62), Offset(size.width, size.height * 0.48), road);
    canvas.drawLine(Offset(size.width * 0.58, 0), Offset(size.width * 0.66, size.height), road);
    canvas.drawLine(
      Offset(0, size.height * 0.15),
      Offset(size.width * 0.5, size.height),
      road..strokeWidth = 4,
    );
  }

  @override
  bool shouldRepaint(_FakeMapPainter old) => old.dark != dark;
}

class GeoContent extends StatelessWidget {
  const GeoContent({
    super.key,
    required this.m,
    required this.width,
    required this.radius,
    required this.fg,
    required this.meta,
  });

  final Message m;
  final double width;
  final BorderRadius radius;
  final Color fg;
  final Widget meta;

  @override
  Widget build(BuildContext context) {
    final g = m.geo!;
    return Pressable(
      scale: 0.97,
      haptic: false,
      onTap: () async {
        context.appRead.tick(HapticKind.selection);
        final ok = await openMap(g);
        if (!ok && context.mounted) {
          await Clipboard.setData(ClipboardData(text: '${g.lat}, ${g.lng}'));
          if (context.mounted) {
            showVeilToast(
              context,
              'Нет приложения карт — координаты скопированы',
              icon: Icons.map_rounded,
            );
          }
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ClipRRect(
            borderRadius: radius,
            child: MapPreview(point: g, width: width, height: width * 0.62),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 8, 3),
            child: SizedBox(
              width: width - 18,
              child: Row(
                children: [
                  Icon(Icons.location_on_rounded, size: 16, color: fg),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      g.accuracy > 0 ? 'Геопозиция · ±${g.accuracy.round()} м' : 'Геопозиция',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  meta,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Опрос ─────────────────────────────

class PollContent extends StatelessWidget {
  const PollContent({
    super.key,
    required this.m,
    required this.chatId,
    required this.fg,
    required this.meta,
  });

  final Message m;
  final String chatId;
  final Color fg;
  final Widget meta;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final poll = m.poll!;
    final me = app.me;
    final mine = poll.of(me);
    final voted = mine.isNotEmpty;
    final total = poll.voters;
    final friend = app.contact(chatId);
    final acc = app.accent;

    void tap(int i) {
      app.tick(HapticKind.selection);
      List<int> next;
      if (poll.multi) {
        next = mine.contains(i) ? (List.of(mine)..remove(i)) : [...mine, i];
      } else {
        next = mine.contains(i) ? [] : [i];
      }
      app.vote(chatId, m, next);
    }

    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            poll.question,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16, height: 1.25),
          ),
          const SizedBox(height: 2),
          Text(
            poll.multi ? 'Опрос · можно несколько ответов' : 'Опрос',
            style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < poll.options.length; i++)
            _PollOption(
              text: poll.options[i],
              share: total == 0 ? 0 : poll.count(i) / total,
              count: poll.count(i),
              showResults: voted,
              selected: mine.contains(i),
              multi: poll.multi,
              fg: fg,
              accent: m.mine ? fg : acc.a,
              // Кто как голосовал — только после своего голоса, как и проценты.
              voters: [
                if (voted && mine.contains(i)) app.profile?.emoji ?? '🙂',
                for (final e in poll.votes.entries)
                  if (voted && e.key != me && e.value.contains(i)) friend?.emoji ?? '🙂',
              ],
              onTap: () => tap(i),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  total == 0 ? 'Пока никто не голосовал' : 'Проголосовали: $total',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg.withValues(alpha: 0.65), fontSize: 12),
                ),
              ),
              meta,
            ],
          ),
        ],
      ),
    );
  }
}

class _PollOption extends StatelessWidget {
  const _PollOption({
    required this.text,
    required this.share,
    required this.count,
    required this.showResults,
    required this.selected,
    required this.multi,
    required this.fg,
    required this.accent,
    required this.voters,
    required this.onTap,
  });

  final String text;
  final double share;
  final int count;
  final bool showResults;
  final bool selected;
  final bool multi;
  final Color fg;
  final Color accent;
  final List<String> voters;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dur = const Duration(milliseconds: 450).by(context);
    return Pressable(
      scale: 0.97,
      haptic: false,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: dur,
                  curve: Curves.easeOutBack,
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: multi ? BoxShape.rectangle : BoxShape.circle,
                    borderRadius: multi ? BorderRadius.circular(6) : null,
                    color: selected ? accent : Colors.transparent,
                    border: Border.all(
                      color: selected ? accent : fg.withValues(alpha: 0.45),
                      width: 2,
                    ),
                  ),
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 14,
                          color: accent == fg ? Colors.black54 : Colors.white,
                        )
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(text, style: TextStyle(color: fg, fontSize: 15)),
                ),
                for (final e in voters) Text(e, style: const TextStyle(fontSize: 13)),
                if (showResults)
                  TweenAnimationBuilder<double>(
                    tween: Tween(begin: 0, end: 1),
                    duration: dur,
                    builder: (_, t, child) => Opacity(opacity: t, child: child),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        '${(share * 100).round()}%',
                        style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 13),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.only(left: 30),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  height: 5,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: fg.withValues(alpha: 0.12))),
                      TweenAnimationBuilder<double>(
                        tween: Tween(end: showResults ? share : 0),
                        duration: dur,
                        curve: Curves.easeOutCubic,
                        builder: (_, v, _) => FractionallySizedBox(
                          widthFactor: v,
                          child: ColoredBox(color: accent),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
