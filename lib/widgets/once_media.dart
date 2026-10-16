import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../utils.dart';
import 'attachments.dart';
import 'effects.dart';
import 'video_note.dart';

/// Одноразовое фото / видео / голосовое / квадратик в пузыре: превью нет,
/// только «🔥 откроется один раз». У отправителя — «отправлено / просмотрено».
class OnceContent extends StatelessWidget {
  const OnceContent({
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

  IconData get _icon => switch (m.kind) {
    MsgKind.video => Icons.videocam_rounded,
    MsgKind.voice => Icons.mic_rounded,
    MsgKind.note => Icons.video_camera_front_rounded,
    _ => Icons.photo_rounded,
  };

  String get _what => switch (m.kind) {
    MsgKind.video => 'Одноразовое видео',
    MsgKind.voice => 'Одноразовое голосовое',
    MsgKind.note => 'Одноразовое видеосообщение',
    _ => 'Одноразовое фото',
  };

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final state = xferOf(app, m);
    final String status;
    if (m.mine) {
      status = m.opened
          ? 'Просмотрено'
          : (m.att?.uploaded ?? false)
          ? 'Отправлено'
          : 'Отправляется…';
    } else if (m.opened) {
      status = 'Просмотрено';
    } else if (state == Xfer.ready) {
      status = 'Нажми, чтобы открыть';
    } else if (state == Xfer.downloading) {
      status = 'Загружается…';
    } else {
      status = 'Нажми, чтобы загрузить';
    }
    final canOpen = !m.mine && !m.opened && state == Xfer.ready;
    return Pressable(
      scale: 0.97,
      onTap: m.mine || m.opened
          ? null
          : canOpen
          ? () => openOnce(context, chatId, m)
          : (state == Xfer.needDownload || state == Xfer.failed)
          ? () => startTransfer(context, chatId, m)
          : null,
      child: SizedBox(
        width: 230,
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fg.withValues(alpha: m.opened ? 0.08 : 0.16),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Icon(_icon, color: fg.withValues(alpha: m.opened ? 0.4 : 0.9), size: 22),
                  if (!m.opened)
                    const Positioned(
                      right: 2,
                      bottom: 0,
                      child: Text('🔥', style: TextStyle(fontSize: 14)),
                    ),
                  if (state == Xfer.downloading)
                    Positioned.fill(child: CircularProgressIndicator(strokeWidth: 2, color: fg)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _what,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14.5),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          status,
                          style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12.5),
                        ),
                      ),
                      meta,
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Открыть одноразовое: на весь экран, без скриншотов; после закрытия — стереть.
Future<void> openOnce(BuildContext context, String chatId, Message m) async {
  final app = context.appRead;
  final path = m.att?.path;
  if (path == null || (!app.demo && !File(path).existsSync())) return;
  app.secureFor(true);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => _OnceViewer(m: m, path: path),
    ),
  );
  app.secureFor(false);
  await app.openedOnce(chatId, m);
}

class _OnceViewer extends StatefulWidget {
  const _OnceViewer({required this.m, required this.path});
  final Message m;
  final String path;

  @override
  State<_OnceViewer> createState() => _OnceViewerState();
}

class _OnceViewerState extends State<_OnceViewer> {
  VideoPlayerController? _c;

  bool get _playable => widget.m.kind != MsgKind.photo;

  @override
  void initState() {
    super.initState();
    if (_playable && !context.appRead.demo) {
      final c = _c = VideoPlayerController.file(File(widget.path));
      c
          .initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
            c.play();
            c.addListener(_tick);
          })
          .catchError((_) {});
    }
  }

  void _tick() {
    final c = _c;
    if (c == null || !mounted) return;
    final v = c.value;
    // Досмотрели — закрываем: второй раз не посмотреть.
    if (v.duration > Duration.zero && v.position >= v.duration && !v.isPlaying) {
      c.removeListener(_tick);
      Navigator.of(context).maybePop();
    } else {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _c?.removeListener(_tick);
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final c = _c;
    final ready = c != null && c.value.isInitialized;
    Widget body;
    if (m.kind == MsgKind.photo) {
      body = InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: context.appRead.demo
              ? const Icon(Icons.photo_rounded, color: Colors.white38, size: 96)
              : Image.file(File(widget.path), fit: BoxFit.contain),
        ),
      );
    } else if (m.kind == MsgKind.voice) {
      final v = c?.value;
      final total = v?.duration.inMilliseconds ?? 0;
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 96),
            const SizedBox(height: 20),
            SizedBox(
              width: 240,
              child: LinearProgressIndicator(
                value: total > 0 ? v!.position.inMilliseconds / total : null,
                color: Colors.white,
                backgroundColor: Colors.white24,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              v == null ? '' : fmtDuration((v.duration - v.position).inSeconds.clamp(0, 3600)),
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    } else if (ready) {
      final video = FittedBox(
        fit: m.kind == MsgKind.note ? BoxFit.cover : BoxFit.contain,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: c.value.size.width,
          height: c.value.size.height,
          child: VideoPlayer(c),
        ),
      );
      final side = MediaQuery.sizeOf(context).width * 0.86;
      body = Center(
        child: m.kind == MsgKind.note
            ? ClipRRect(
                borderRadius: BorderRadius.circular(side * VideoNote.corner),
                child: SizedBox(width: side, height: side, child: video),
              )
            : AspectRatio(aspectRatio: c.value.aspectRatio, child: video),
      );
    } else {
      body = const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(child: body),
            Positioned(
              top: 4,
              left: 4,
              right: 4,
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white, size: 28),
                  ),
                  const Expanded(
                    child: Text(
                      '🔥 Откроется только один раз',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
