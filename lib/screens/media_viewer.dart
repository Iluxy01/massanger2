import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../core/media_tools.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../utils.dart';
import '../widgets/effects.dart';

/// Фото или видео на весь экран: масштаб жестами, плеер, «поделиться».
class MediaViewer extends StatefulWidget {
  const MediaViewer({super.key, required this.m, required this.chatId});

  final Message m;
  final String chatId;

  static Route<void> route(Message m, String chatId) => PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black,
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => MediaViewer(m: m, chatId: chatId),
    transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
  );

  @override
  State<MediaViewer> createState() => _MediaViewerState();
}

class _MediaViewerState extends State<MediaViewer> {
  bool _chrome = true;
  VideoPlayerController? _video;
  double _drag = 0;

  bool get isVideo => widget.m.kind == MsgKind.video;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (isVideo) {
      final c = _video = VideoPlayerController.file(File(widget.m.att!.path!));
      c.addListener(() {
        if (mounted) setState(() {});
      });
      c
          .initialize()
          .then((_) {
            if (mounted) c.play();
          })
          .catchError((Object _) {
            if (mounted) {
              showVeilToast(
                context,
                'Не получилось воспроизвести',
                icon: Icons.error_outline_rounded,
              );
            }
          });
    }
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _video?.dispose();
    super.dispose();
  }

  void _togglePlay() {
    final c = _video;
    if (c == null || !c.value.isInitialized) return;
    c.value.isPlaying ? c.pause() : c.play();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final c = _video;
    final contact = context.app.contact(widget.chatId);
    final who = m.mine ? 'Вы' : contact?.name ?? '';

    Widget body;
    if (isVideo) {
      body = c != null && c.value.isInitialized
          ? AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))
          : const CircularProgressIndicator(color: Colors.white);
    } else {
      body = InteractiveViewer(
        minScale: 1,
        maxScale: 5,
        child: Image.file(File(m.att!.path!), fit: BoxFit.contain),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black.withValues(alpha: (1 - _drag.abs() / 400).clamp(0.3, 1)),
      body: GestureDetector(
        onTap: () => isVideo ? _togglePlay() : setState(() => _chrome = !_chrome),
        // Смахнуть вниз — закрыть.
        onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
        onVerticalDragEnd: (d) {
          if (_drag.abs() > 120 || (d.primaryVelocity ?? 0).abs() > 900) {
            Navigator.of(context).pop();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: Transform.translate(
                offset: Offset(0, _drag),
                child: Center(
                  child: Hero(tag: 'media-${m.id}', child: body),
                ),
              ),
            ),
            if (isVideo && c != null && c.value.isInitialized && !c.value.isPlaying)
              Center(
                child: IgnorePointer(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.black.withValues(alpha: 0.45),
                    ),
                    child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 44),
                  ),
                ),
              ),
            AnimatedPositioned(
              duration: const Duration(milliseconds: 220),
              top: _chrome ? 0 : -120,
              left: 0,
              right: 0,
              child: Container(
                padding: EdgeInsets.fromLTRB(8, MediaQuery.paddingOf(context).top + 6, 8, 12),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            who,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            '${fmtDay(m.time)}, ${fmtTime(m.time)}',
                            style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Поделиться',
                      onPressed: () => shareFile(m.att!.path!),
                      icon: const Icon(Icons.ios_share_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
            if (isVideo && c != null && c.value.isInitialized)
              Positioned(
                left: 16,
                right: 16,
                bottom: MediaQuery.paddingOf(context).bottom + 18,
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _togglePlay,
                      icon: Icon(
                        c.value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      fmtDuration(c.value.position.inSeconds),
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    ),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: SliderComponentShape.noOverlay,
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: c.value.position.inMilliseconds
                              .clamp(0, c.value.duration.inMilliseconds)
                              .toDouble(),
                          max: c.value.duration.inMilliseconds.toDouble().clamp(1, double.infinity),
                          onChanged: (v) => c.seekTo(Duration(milliseconds: v.round())),
                        ),
                      ),
                    ),
                    Text(
                      fmtDuration(c.value.duration.inSeconds),
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            if (!isVideo && m.text.isNotEmpty && _chrome)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    24,
                    20,
                    MediaQuery.paddingOf(context).bottom + 20,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Text(m.text, style: const TextStyle(color: Colors.white, fontSize: 15.5)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
