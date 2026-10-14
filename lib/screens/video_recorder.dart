import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart' show Geolocator;

import '../state/app_state.dart';
import '../utils.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';

/// Запись короткого видео прямо в чате: 480p и умеренный битрейт — минута
/// весит около 9 МБ и быстро уходит через ретрансляторы.
/// Возвращает путь к записанному файлу или null.
class VideoRecorderScreen extends StatefulWidget {
  const VideoRecorderScreen({super.key});

  static const maxLength = Duration(seconds: 60);

  static Route<String> route() => MaterialPageRoute(builder: (_) => const VideoRecorderScreen());

  @override
  State<VideoRecorderScreen> createState() => _VideoRecorderScreenState();
}

class _VideoRecorderScreenState extends State<VideoRecorderScreen> with WidgetsBindingObserver {
  List<CameraDescription> _cams = [];
  int _cam = 0;
  CameraController? _c;
  String? _error;
  bool _recording = false;
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    try {
      _cams = await availableCameras();
      if (_cams.isEmpty) {
        setState(() => _error = 'Камера не найдена');
        return;
      }
      final back = _cams.indexWhere((c) => c.lensDirection == CameraLensDirection.back);
      _cam = back < 0 ? 0 : back;
      await _open();
    } catch (e) {
      if (mounted) setState(() => _error = 'Нет доступа к камере');
    }
  }

  Future<void> _open() async {
    final old = _c;
    _c = null;
    if (mounted) setState(() {});
    await old?.dispose();
    final c = CameraController(
      _cams[_cam],
      ResolutionPreset.medium,
      enableAudio: true,
      fps: 30,
      videoBitrate: 1200000,
      audioBitrate: 64000,
    );
    try {
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() {
        _c = c;
        _error = null;
      });
    } on CameraException catch (e) {
      await c.dispose();
      if (mounted) {
        setState(
          () => _error = e.code.contains('ccess') || e.code.contains('ermission')
              ? 'Нужно разрешение на камеру и микрофон'
              : 'Камера недоступна',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_recording) _stop();
      final c = _c;
      _c = null;
      c?.dispose();
    } else if (state == AppLifecycleState.resumed && _c == null && _cams.isNotEmpty) {
      _open();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _c?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final c = _c;
    if (c == null || _recording) return;
    context.appRead.tick(HapticKind.medium);
    try {
      await c.startVideoRecording();
    } catch (_) {
      if (mounted) {
        showVeilToast(context, 'Не получилось начать запись', icon: Icons.error_outline_rounded);
      }
      return;
    }
    setState(() {
      _recording = true;
      _seconds = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _seconds++);
      if (_seconds >= VideoRecorderScreen.maxLength.inSeconds) _stop();
    });
  }

  Future<void> _stop() async {
    final c = _c;
    _timer?.cancel();
    if (c == null || !_recording) return;
    setState(() => _recording = false);
    try {
      final f = await c.stopVideoRecording();
      if (mounted) Navigator.of(context).pop(f.path);
    } catch (_) {
      if (mounted) {
        showVeilToast(context, 'Запись не сохранилась', icon: Icons.error_outline_rounded);
      }
    }
  }

  Future<void> _flip() async {
    if (_cams.length < 2 || _recording) return;
    context.appRead.tick(HapticKind.selection);
    _cam = (_cam + 1) % _cams.length;
    await _open();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    final acc = context.accent;
    final pad = MediaQuery.paddingOf(context);
    final left = VideoRecorderScreen.maxLength.inSeconds - _seconds;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (c != null && c.value.isInitialized)
            Positioned.fill(
              child: FittedBox(
                fit: BoxFit.cover,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  // Превью камеры отдаёт размер в «альбомной» ориентации.
                  width: c.value.previewSize?.height ?? 480,
                  height: c.value.previewSize?.width ?? 640,
                  child: CameraPreview(c),
                ),
              ),
            )
          else
            Center(
              child: _error == null
                  ? const CircularProgressIndicator(color: Colors.white)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_off_rounded, color: Colors.white54, size: 48),
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: Colors.white, fontSize: 16)),
                        const SizedBox(height: 16),
                        TextButton(
                          onPressed: Geolocator.openAppSettings,
                          child: const Text('Открыть настройки'),
                        ),
                      ],
                    ),
            ),
          Positioned(
            top: pad.top + 6,
            left: 6,
            right: 6,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                ),
                const Spacer(),
                AnimatedOpacity(
                  opacity: _recording ? 1 : 0,
                  duration: const Duration(milliseconds: 200).by(context),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 9,
                          height: 9,
                          decoration: const BoxDecoration(
                            color: Colors.redAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${fmtDuration(_seconds)}  ·  осталось ${fmtDuration(left)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 48),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: pad.bottom + 28,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                const SizedBox(width: 56),
                // Кнопка записи: круг → скруглённый квадрат, кольцо — сколько осталось.
                GestureDetector(
                  onTap: c == null ? null : (_recording ? _stop : _start),
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        SizedBox.expand(
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(
                              end: _recording
                                  ? _seconds / VideoRecorderScreen.maxLength.inSeconds
                                  : 0,
                            ),
                            duration: const Duration(milliseconds: 900).by(context),
                            builder: (_, v, _) => CircularProgressIndicator(
                              value: v,
                              strokeWidth: 4,
                              color: acc.b,
                              backgroundColor: Colors.white.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 220).by(context),
                          curve: Curves.easeOutCubic,
                          width: _recording ? 32 : 64,
                          height: _recording ? 32 : 64,
                          decoration: BoxDecoration(
                            color: Colors.redAccent,
                            borderRadius: BorderRadius.circular(_recording ? 8 : 32),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: _cams.length > 1 && !_recording
                      ? IconButton(
                          onPressed: _flip,
                          icon: const Icon(
                            Icons.flip_camera_android_rounded,
                            color: Colors.white,
                            size: 30,
                          ),
                        )
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
