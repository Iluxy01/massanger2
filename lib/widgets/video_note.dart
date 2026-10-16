import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../core/media_tools.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils.dart';
import 'attachments.dart';
import 'effects.dart';
import 'visual.dart';

/// Видеосообщения — «квадратики» с мягкими углами (как кружки в Telegram):
/// запись с фронтальной камеры, пока держишь кнопку, до минуты.
class VideoNote {
  static const maxSeconds = 60;

  /// Скругление углов — доля стороны квадрата.
  static const corner = 0.12;
}

/// Запись видеосообщения.
class NoteRecorder {
  CameraController? controller;
  bool _recording = false;
  List<CameraDescription> _cams = const [];
  bool _flipping = false;

  /// Есть и фронтальная, и основная камера — можно переворачивать.
  bool get canFlip =>
      _cams.any((c) => c.lensDirection == CameraLensDirection.front) &&
      _cams.any((c) => c.lensDirection != CameraLensDirection.front);

  /// Открыть камеру (фронтальную или основную — [back]) и начать запись.
  /// false — нет камеры или разрешения.
  Future<bool> start({bool back = false}) async {
    try {
      final cams = _cams = await availableCameras();
      if (cams.isEmpty) return false;
      bool want(CameraDescription c) => back
          ? c.lensDirection == CameraLensDirection.back
          : c.lensDirection == CameraLensDirection.front;
      final first = cams.firstWhere(want, orElse: () => cams.first);
      final c = CameraController(
        first,
        // 480p и умеренный битрейт: минута ≈ 8 МБ — быстро уходит через ретрансляторы.
        ResolutionPreset.medium,
        enableAudio: true,
        fps: 30,
        videoBitrate: 1000000,
        audioBitrate: 64000,
      );
      controller = c;
      await c.initialize();
      await c.startVideoRecording();
      _recording = true;
      return true;
    } catch (_) {
      await _close();
      return false;
    }
  }

  /// Перевернуть камеру (фронтальная ↔ основная) — запись при этом не прерывается.
  Future<bool> flip() async {
    final c = controller;
    if (c == null || !c.value.isInitialized || !canFlip || _flipping) return false;
    final front = c.description.lensDirection == CameraLensDirection.front;
    final next = _cams.firstWhere(
      (d) => front
          ? d.lensDirection != CameraLensDirection.front
          : d.lensDirection == CameraLensDirection.front,
    );
    _flipping = true;
    try {
      await c.setDescription(next);
      return true;
    } catch (_) {
      return false;
    } finally {
      _flipping = false;
    }
  }

  /// Остановить запись. Путь к файлу или null (отменили / не получилось).
  Future<String?> stop({bool cancel = false}) async {
    final c = controller;
    String? path;
    if (c != null && _recording) {
      _recording = false;
      try {
        final f = await c.stopVideoRecording();
        if (cancel) {
          try {
            await File(f.path).delete();
          } catch (_) {}
        } else {
          path = f.path;
        }
      } catch (_) {}
    }
    await _close();
    return path;
  }

  Future<void> _close() async {
    final c = controller;
    controller = null;
    _recording = false;
    try {
      await c?.dispose();
    } catch (_) {}
  }
}

/// Обводка по периметру скруглённого квадрата: [progress] 0..1 — какая часть
/// пройдена (от середины верхней стороны по часовой стрелке).
class _EdgeProgressPainter extends CustomPainter {
  _EdgeProgressPainter({
    required this.progress,
    required this.colors,
    required this.radius,
    this.width = 4,
    this.track,
  });

  final double progress;
  final List<Color> colors;
  final double radius;
  final double width;
  final Color? track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width / 2);
    final r = Radius.circular(max(0, radius - width / 2));
    // Начинаем с середины верхней стороны.
    final path = Path()
      ..moveTo(rect.center.dx, rect.top)
      ..lineTo(rect.right - r.x, rect.top)
      ..arcToPoint(Offset(rect.right, rect.top + r.y), radius: r)
      ..lineTo(rect.right, rect.bottom - r.y)
      ..arcToPoint(Offset(rect.right - r.x, rect.bottom), radius: r)
      ..lineTo(rect.left + r.x, rect.bottom)
      ..arcToPoint(Offset(rect.left, rect.bottom - r.y), radius: r)
      ..lineTo(rect.left, rect.top + r.y)
      ..arcToPoint(Offset(rect.left + r.x, rect.top), radius: r)
      ..close();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    if (track != null) canvas.drawPath(path, Paint.from(stroke)..color = track!);
    if (progress <= 0) return;
    stroke.shader = LinearGradient(colors: colors).createShader(Offset.zero & size);
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * progress.clamp(0, 1)), stroke);
    }
  }

  @override
  bool shouldRepaint(_EdgeProgressPainter old) =>
      old.progress != progress || old.colors != colors || old.radius != radius;
}

/// Затемнение поверх чата во время записи: превью камеры в квадратике и
/// обводка — сколько из минуты уже записано.
class NoteRecordingOverlay extends StatelessWidget {
  const NoteRecordingOverlay({
    super.key,
    required this.recorder,
    required this.seconds,
    required this.recording,
    this.cancel = false,
    this.onFlip,
  });

  final NoteRecorder recorder;

  /// Перевернуть камеру (кнопку можно нажать вторым пальцем, пока держишь запись).
  final VoidCallback? onFlip;
  final int seconds;

  /// Камера уже пишет (иначе — ещё открывается).
  final bool recording;
  final bool cancel;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final screen = MediaQuery.sizeOf(context);
    final side = min(screen.width * 0.78, 340.0);
    final radius = side * VideoNote.corner;
    final c = recorder.controller;
    final live = c != null && c.value.isInitialized;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260).by(context),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14 * t, sigmaY: 14 * t),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.45 * t),
          child: Opacity(
            opacity: t,
            child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
          ),
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: side,
              height: side,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(7),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(radius - 7),
                      child: live
                          ? FittedBox(
                              fit: BoxFit.cover,
                              clipBehavior: Clip.hardEdge,
                              child: SizedBox(
                                // Превью камеры отдаёт размер в «альбомной» ориентации.
                                width: c.value.previewSize?.height ?? 480,
                                height: c.value.previewSize?.width ?? 640,
                                child: CameraPreview(c),
                              ),
                            )
                          : const ColoredBox(
                              color: Colors.black,
                              child: Center(child: CircularProgressIndicator(color: Colors.white)),
                            ),
                    ),
                  ),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: recording ? seconds / VideoNote.maxSeconds : 0),
                    duration: const Duration(milliseconds: 950),
                    builder: (_, v, _) => CustomPaint(
                      painter: _EdgeProgressPainter(
                        progress: v,
                        colors: cancel
                            ? const [Colors.redAccent, Colors.redAccent]
                            : [acc.a, acc.b],
                        radius: radius,
                        track: Colors.white.withValues(alpha: 0.25),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: recording ? Colors.redAccent : Colors.white38,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${fmtDuration(seconds)} / ${fmtDuration(VideoNote.maxSeconds)}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            if (onFlip != null && recorder.canFlip) ...[
              const SizedBox(height: 14),
              Pressable(
                scale: 0.85,
                onTap: onFlip,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.45),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
                  ),
                  child: const Icon(
                    Icons.flip_camera_android_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Видеосообщение в чате: без пузыря, скруглённый квадрат. Само крутится без
/// звука; нажатие — со звуком с начала, обводка показывает, сколько прошло.
class NoteBubble extends StatefulWidget {
  const NoteBubble({super.key, required this.m, required this.chatId, required this.meta});

  final Message m;
  final String chatId;

  /// Время и галочки (белые, на тёмной плашке).
  final Widget meta;

  @override
  State<NoteBubble> createState() => _NoteBubbleState();
}

class _NoteBubbleState extends State<NoteBubble> {
  /// Со звуком играет только одно видеосообщение.
  static _NoteBubbleState? _loud;

  VideoPlayerController? _c;
  String? _path;
  bool _sound = false;

  @override
  void dispose() {
    if (_loud == this) _loud = null;
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  Future<void> _open(String path) async {
    _path = path;
    final c = VideoPlayerController.file(
      File(path),
      // Без звука не забираем звук у музыки и других приложений.
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _c = c;
    // При «без анимаций» сами не крутим — только по нажатию.
    final auto = context.appRead.motion > 0;
    try {
      await c.initialize();
      if (!mounted || _c != c) return;
      await c.setVolume(0);
      await c.setLooping(true);
      if (auto) await c.play();
      c.addListener(_tick);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _tick() {
    final c = _c;
    if (c == null || !_sound) return;
    final v = c.value;
    final total = v.duration.inMilliseconds;
    if (total > 0 && v.position.inMilliseconds >= total - 120 && !v.isPlaying) {
      _quiet(); // досмотрели со звуком — снова тихо по кругу
    }
  }

  Future<void> _quiet() async {
    final c = _c;
    if (c == null) return;
    final auto = !mounted || context.appRead.motion > 0;
    if (mounted) setState(() => _sound = false);
    if (_loud == this) _loud = null;
    await c.setVolume(0);
    await c.setLooping(true);
    if (auto) {
      await c.play();
    } else {
      await c.pause();
      await c.seekTo(Duration.zero);
    }
  }

  Future<void> _tap() async {
    final c = _c;
    final app = context.appRead;
    if (c == null || !c.value.isInitialized) return;
    app.tick(HapticKind.selection);
    if (!_sound) {
      final other = _loud;
      if (other != null && other != this) await other._quiet();
      _loud = this;
      setState(() => _sound = true);
      await c.setLooping(false);
      await c.seekTo(Duration.zero);
      await c.setVolume(1);
      await c.play();
    } else if (c.value.isPlaying) {
      await c.pause();
      if (mounted) setState(() {});
    } else {
      await c.play();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final acc = app.accent;
    final m = widget.m;
    final att = m.att!;
    final state = xferOf(app, m);
    final side = min(MediaQuery.sizeOf(context).width * 0.6, 240.0);
    final radius = side * VideoNote.corner;
    final ready = state == Xfer.ready || state == Xfer.uploading;
    final path = att.path;
    if (ready && path != null && !app.demo && _path != path) {
      // Файл появился (скачался) — открываем плеер после кадра.
      _path = path;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(path);
      });
    }
    final c = _c;
    final playing = c != null && c.value.isInitialized;

    Widget picture = playing
        ? FittedBox(
            fit: BoxFit.cover,
            clipBehavior: Clip.hardEdge,
            child: SizedBox(
              width: c.value.size.width,
              height: c.value.size.height,
              child: VideoPlayer(c),
            ),
          )
        : DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [acc.a.withValues(alpha: 0.6), acc.b.withValues(alpha: 0.4)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Icon(
                Icons.videocam_rounded,
                size: 42,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          );

    return Pressable(
      scale: 0.97,
      haptic: false,
      onTap: state == Xfer.ready
          ? _tap
          : (state == Xfer.needDownload || state == Xfer.failed)
          ? () => startTransfer(context, widget.chatId, m)
          : null,
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: ClipRRect(borderRadius: BorderRadius.circular(radius - 4), child: picture),
            ),
            // Обводка: прогресс воспроизведения со звуком, иначе тонкая рамка.
            if (playing && _sound)
              ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: c,
                builder: (_, v, _) {
                  final total = v.duration.inMilliseconds;
                  return CustomPaint(
                    painter: _EdgeProgressPainter(
                      progress: total > 0 ? v.position.inMilliseconds / total : 0,
                      colors: [acc.a, acc.b],
                      radius: radius,
                      width: 3.5,
                    ),
                  );
                },
              )
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: acc.mid.withValues(alpha: 0.55), width: 2),
                ),
              ),
            if (state != Xfer.ready)
              Center(
                child: TransferBadge(m: m, chatId: widget.chatId, state: state),
              )
            else if (_sound && playing && !c.value.isPlaying)
              Center(
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.45),
                  ),
                  child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
                ),
              ),
            Positioned(
              left: 12,
              bottom: 10,
              child: MetaPill(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_sound && state == Xfer.ready) ...[
                      const Icon(Icons.volume_off_rounded, color: Colors.white, size: 13),
                      const SizedBox(width: 4),
                    ],
                    if (playing && _sound)
                      ValueListenableBuilder<VideoPlayerValue>(
                        valueListenable: c,
                        builder: (_, v, _) => Text(
                          fmtDuration(
                            max(0, (v.duration - v.position).inMilliseconds / 1000).ceil(),
                          ),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11.5,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      )
                    else
                      Text(
                        [
                          fmtDuration(att.duration),
                          if (state != Xfer.ready) fmtSize(att.size),
                        ].join(' · '),
                        style: const TextStyle(color: Colors.white, fontSize: 11.5),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(right: 12, bottom: 10, child: MetaPill(child: widget.meta)),
          ],
        ),
      ),
    );
  }
}
