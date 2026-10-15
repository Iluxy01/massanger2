import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';

import '../core/media_tools.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/media_engine.dart';
import '../widgets/attachments.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';
import 'video_recorder.dart';
import 'wifi_hint.dart';

/// Сценарии отправки вложений из меню «＋» в чате.
class AttachFlows {
  AttachFlows(this.context, this.chatId, {this.replyTo});

  final BuildContext context;
  final String chatId;
  final Message? replyTo;

  AppState get app => context.appRead;

  bool _demoBlocked() {
    if (!app.demo) return false;
    showVeilToast(context, 'В демо-версии файлы не отправляются', icon: Icons.cloud_off_rounded);
    return true;
  }

  /// Нельзя отправлять (демо) или передумали после подсказки про Wi-Fi.
  Future<bool> _blocked() async => _demoBlocked() || !await wifiHint(context);

  bool _tooBig(int size) {
    if (size <= MediaEngine.maxBytes) return false;
    showVeilToast(
      context,
      'Файл больше ${fmtSize(MediaEngine.maxBytes)} — слишком большой для передачи',
      icon: Icons.block_rounded,
    );
    return true;
  }

  // ── Фото ──

  Future<void> photos({bool camera = false}) async {
    if (await _blocked() || !context.mounted) return;
    final picker = ImagePicker();
    List<XFile> files;
    try {
      if (camera) {
        final f = await picker.pickImage(
          source: ImageSource.camera,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 78,
        );
        files = f == null ? [] : [f];
      } else {
        files = await picker.pickMultiImage(
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 78,
          limit: 10,
        );
      }
    } catch (e) {
      if (context.mounted) {
        showVeilToast(context, 'Нет доступа к фото', icon: Icons.no_photography_rounded);
      }
      return;
    }
    if (files.isEmpty || !context.mounted) return;
    final caption = await Navigator.of(
      context,
    ).push<String>(SendPreview.route(kind: MsgKind.photo, paths: [for (final f in files) f.path]));
    if (caption == null) return;
    for (final (i, f) in files.indexed) {
      final size = await File(f.path).length();
      if (!context.mounted) return;
      if (_tooBig(size)) continue;
      final meta = await imageMeta(f.path);
      await app.sendFile(
        chatId,
        kind: MsgKind.photo,
        path: f.path,
        name: 'photo_${DateTime.now().millisecondsSinceEpoch}_$i.jpg',
        mime: mimeFor(f.path).startsWith('image/') ? mimeFor(f.path) : 'image/jpeg',
        size: size,
        caption: i == 0 ? caption : '',
        width: meta.width,
        height: meta.height,
        thumb: meta.thumb,
        replyTo: i == 0 ? replyTo : null,
      );
    }
  }

  // ── Видео ──

  Future<void> video() async {
    if (await _blocked() || !context.mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _ChoiceSheet(
        title: 'Видео',
        items: const [
          (
            Icons.videocam_rounded,
            'Записать короткое видео',
            'до 1 минуты, сжатое для быстрой отправки',
            'rec',
          ),
          (Icons.video_library_rounded, 'Выбрать из галереи', 'до 20 МБ', 'gallery'),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    String? path;
    if (choice == 'rec') {
      path = await Navigator.of(context).push<String>(VideoRecorderScreen.route());
    } else {
      try {
        final f = await ImagePicker().pickVideo(source: ImageSource.gallery);
        path = f?.path;
      } catch (_) {
        if (context.mounted) {
          showVeilToast(context, 'Нет доступа к видео', icon: Icons.videocam_off_rounded);
        }
      }
    }
    if (path == null || !context.mounted) return;
    final size = await File(path).length();
    if (!context.mounted || _tooBig(size)) return;
    final caption = await Navigator.of(
      context,
    ).push<String>(SendPreview.route(kind: MsgKind.video, paths: [path]));
    if (caption == null) return;
    final meta = await videoMeta(path);
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'mp4';
    await app.sendFile(
      chatId,
      kind: MsgKind.video,
      path: path,
      name: 'video_${DateTime.now().millisecondsSinceEpoch}.$ext',
      mime: mimeFor('x.$ext').startsWith('video/') ? mimeFor('x.$ext') : 'video/mp4',
      size: size,
      caption: caption,
      width: meta.width,
      height: meta.height,
      duration: meta.seconds,
      replyTo: replyTo,
    );
  }

  // ── Документ ──

  Future<void> file() async {
    if (await _blocked() || !context.mounted) return;
    PlatformFile? f;
    try {
      f = await FilePicker.pickFile();
    } catch (_) {
      if (context.mounted) {
        showVeilToast(context, 'Не получилось открыть файлы', icon: Icons.error_outline_rounded);
      }
      return;
    }
    if (f == null || !context.mounted) return;
    final size = f.lengthSync() ?? await f.length() ?? 0;
    if (_tooBig(size)) return;
    // Путь есть не всегда (файл из облака и т. п.) — тогда копируем поток.
    var path = f.path;
    if (path == null || !File(path).existsSync()) {
      final tmp = await getTemporaryDirectory();
      final out = File('${tmp.path}/${DateTime.now().millisecondsSinceEpoch}_${f.name}');
      final sink = out.openWrite();
      await sink.addStream(f.readAsByteStream());
      await sink.close();
      path = out.path;
    }
    final real = await File(path).length();
    if (!context.mounted || _tooBig(real)) return;
    await app.sendFile(
      chatId,
      kind: MsgKind.file,
      path: path,
      name: f.name,
      mime: mimeFor(f.name),
      size: real,
      replyTo: replyTo,
    );
  }

  // ── Место ──

  Future<void> location() async {
    final point = await showModalBottomSheet<GeoPoint>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const LocationSheet(),
    );
    if (point == null) return;
    app.sendLocation(chatId, point, replyTo: replyTo);
  }

  // ── Опрос ──

  Future<void> poll() async {
    final p = await Navigator.of(context).push<Poll>(PollComposer.route());
    if (p == null) return;
    app.sendPoll(chatId, p);
  }
}

// ───────────────────────────── Выбор варианта ─────────────────────────────

class _ChoiceSheet extends StatelessWidget {
  const _ChoiceSheet({required this.title, required this.items});

  final String title;
  final List<(IconData, String, String, String)> items;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 26,
          color: vc.elevated,
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: TextStyle(color: vc.text, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              for (final (icon, label, hint, value) in items)
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  leading: GradientIcon(icon, size: 26),
                  title: Text(
                    label,
                    style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(hint, style: TextStyle(color: vc.textDim, fontSize: 12.5)),
                  onTap: () => Navigator.of(context).pop(value),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Предпросмотр с подписью ─────────────────────────────

/// Фото (одно или несколько) или видео перед отправкой: можно добавить подпись.
/// Возвращает подпись ('' — без неё) или null, если передумали.
class SendPreview extends StatefulWidget {
  const SendPreview({super.key, required this.kind, required this.paths});

  final MsgKind kind;
  final List<String> paths;

  static Route<String> route({required MsgKind kind, required List<String> paths}) =>
      MaterialPageRoute(
        builder: (_) => SendPreview(kind: kind, paths: paths),
      );

  @override
  State<SendPreview> createState() => _SendPreviewState();
}

class _SendPreviewState extends State<SendPreview> {
  final _caption = TextEditingController();
  final _page = PageController();
  int _index = 0;
  VideoPlayerController? _video;

  @override
  void initState() {
    super.initState();
    if (widget.kind == MsgKind.video) {
      final c = _video = VideoPlayerController.file(File(widget.paths.first));
      c.addListener(() {
        if (mounted) setState(() {});
      });
      c
          .initialize()
          .then((_) {
            if (mounted) {
              c.setLooping(true);
              c.play();
            }
          })
          .catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    _caption.dispose();
    _page.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final bottom = MediaQuery.viewInsetsOf(context).bottom + MediaQuery.paddingOf(context).bottom;
    final n = widget.paths.length;
    final v = _video;

    Widget media;
    if (widget.kind == MsgKind.video) {
      media = v != null && v.value.isInitialized
          ? GestureDetector(
              onTap: () => v.value.isPlaying ? v.pause() : v.play(),
              child: Center(
                child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
              ),
            )
          : const Center(child: CircularProgressIndicator(color: Colors.white));
    } else {
      media = PageView.builder(
        controller: _page,
        itemCount: n,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (_, i) => InteractiveViewer(
          maxScale: 4,
          child: Image.file(File(widget.paths[i]), fit: BoxFit.contain),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(child: media),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 4,
            left: 4,
            right: 4,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
                const Spacer(),
                if (n > 1)
                  MetaPill(
                    child: Text(
                      '${_index + 1} из $n',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                const SizedBox(width: 12),
              ],
            ),
          ),
          Positioned(
            left: 10,
            right: 10,
            bottom: bottom + 10,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _caption,
                      minLines: 1,
                      maxLines: 4,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        hintText: 'Подпись…',
                        hintStyle: TextStyle(color: Colors.white54),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Pressable(
                  scale: 0.85,
                  onTap: () => Navigator.of(context).pop(_caption.text.trim()),
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: acc.gradient,
                      boxShadow: [BoxShadow(color: acc.mid.withValues(alpha: 0.5), blurRadius: 16)],
                    ),
                    child: Icon(Icons.arrow_upward_rounded, color: acc.onAccent),
                  ),
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

enum _Loc { searching, found, serviceOff, denied, deniedForever, failed }

/// Определить место и подтвердить отправку. Возвращает точку или null.
class LocationSheet extends StatefulWidget {
  const LocationSheet({super.key});

  @override
  State<LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends State<LocationSheet> {
  _Loc _state = _Loc.searching;
  GeoPoint? _point;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  Future<void> _locate() async {
    final app = context.appRead;
    setState(() => _state = _Loc.searching);
    if (app.demo) {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (mounted) {
        setState(() {
          _point = const GeoPoint(55.7539, 37.6208, accuracy: 15);
          _state = _Loc.found;
        });
      }
      return;
    }
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) setState(() => _state = _Loc.serviceOff);
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.deniedForever) {
        if (mounted) setState(() => _state = _Loc.deniedForever);
        return;
      }
      if (perm == LocationPermission.denied) {
        if (mounted) setState(() => _state = _Loc.denied);
        return;
      }
      // Сначала быстро — последнее известное, потом уточняем.
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted && _point == null) {
        setState(() {
          _point = GeoPoint(last.latitude, last.longitude, accuracy: last.accuracy);
          _state = _Loc.found;
        });
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (mounted) {
        setState(() {
          _point = GeoPoint(pos.latitude, pos.longitude, accuracy: pos.accuracy);
          _state = _Loc.found;
        });
      }
    } catch (_) {
      if (mounted && _point == null) setState(() => _state = _Loc.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final p = _point;
    final width = MediaQuery.sizeOf(context).width - 24;

    Widget body;
    switch (_state) {
      case _Loc.found when p != null:
        body = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: MapPreview(point: p, width: width - 16, height: 200),
            ),
            const SizedBox(height: 12),
            Text(
              p.accuracy > 0 ? 'Точность ±${p.accuracy.round()} м' : 'Ваше местоположение',
              style: TextStyle(color: vc.textDim, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Отправится одна точка — следить за вами друг не сможет',
              textAlign: TextAlign.center,
              style: TextStyle(color: vc.textFaint, fontSize: 12),
            ),
            const SizedBox(height: 12),
            AccentButton(
              label: 'Отправить геопозицию',
              icon: Icons.near_me_rounded,
              onTap: () => Navigator.of(context).pop(p),
            ),
          ],
        );
      case _Loc.serviceOff:
        body = _LocProblem(
          text: 'Геолокация на телефоне выключена',
          action: 'Включить',
          onAction: () async {
            await Geolocator.openLocationSettings();
            if (mounted) _locate();
          },
        );
      case _Loc.denied:
        body = _LocProblem(
          text: 'Нужно разрешение на геопозицию',
          action: 'Разрешить',
          onAction: _locate,
        );
      case _Loc.deniedForever:
        body = _LocProblem(
          text: 'Доступ к геопозиции запрещён в настройках',
          action: 'Открыть настройки',
          onAction: Geolocator.openAppSettings,
        );
      case _Loc.failed:
        body = _LocProblem(
          text: 'Не удалось определить место',
          action: 'Ещё раз',
          onAction: _locate,
        );
      default:
        body = Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(height: 14),
              Text('Определяю местоположение…', style: TextStyle(color: vc.textDim)),
            ],
          ),
        );
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 28,
          color: vc.elevated,
          padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Геопозиция',
                style: TextStyle(color: vc.text, fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              AnimatedSize(
                duration: const Duration(milliseconds: 280).by(context),
                curve: Curves.easeOutCubic,
                child: body,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocProblem extends StatelessWidget {
  const _LocProblem({required this.text, required this.action, required this.onAction});

  final String text;
  final String action;
  final FutureOr<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.location_off_rounded, size: 40, color: vc.textFaint),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: vc.text, fontSize: 15),
          ),
          const SizedBox(height: 14),
          AccentButton(label: action, onTap: () => onAction()),
        ],
      ),
    );
  }
}

// ───────────────────────────── Опрос ─────────────────────────────

class PollComposer extends StatefulWidget {
  const PollComposer({super.key});

  static Route<Poll> route() => MaterialPageRoute(builder: (_) => const PollComposer());

  @override
  State<PollComposer> createState() => _PollComposerState();
}

class _PollComposerState extends State<PollComposer> {
  final _question = TextEditingController();
  final List<TextEditingController> _options = [TextEditingController(), TextEditingController()];
  bool _multi = false;

  @override
  void initState() {
    super.initState();
    _question.addListener(() => setState(() {}));
    for (final o in _options) {
      o.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    _question.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  List<String> get _filled => [
    for (final o in _options)
      if (o.text.trim().isNotEmpty) o.text.trim(),
  ];

  bool get _ready => _question.text.trim().isNotEmpty && _filled.length >= 2;

  void _add() {
    if (_options.length >= 10) return;
    final c = TextEditingController()..addListener(() => setState(() {}));
    setState(() => _options.add(c));
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;

    InputDecoration deco(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: vc.textFaint),
      filled: true,
      fillColor: vc.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );

    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        surfaceTintColor: Colors.transparent,
        title: Text(
          'Новый опрос',
          style: TextStyle(color: vc.text, fontWeight: FontWeight.w700),
        ),
        iconTheme: IconThemeData(color: vc.text),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          TextField(
            controller: _question,
            maxLength: 300,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            style: TextStyle(color: vc.text, fontSize: 17, fontWeight: FontWeight.w600),
            decoration: deco('Вопрос'),
          ),
          const SizedBox(height: 8),
          Text(
            'Варианты',
            style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final (i, o) in _options.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: o,
                      maxLength: 100,
                      buildCounter: (_, {required currentLength, required isFocused, maxLength}) =>
                          null,
                      textCapitalization: TextCapitalization.sentences,
                      style: TextStyle(color: vc.text, fontSize: 15.5),
                      decoration: deco('Вариант ${i + 1}'),
                    ),
                  ),
                  if (_options.length > 2)
                    IconButton(
                      onPressed: () => setState(() => _options.removeAt(i).dispose()),
                      icon: Icon(Icons.remove_circle_outline_rounded, color: vc.textFaint),
                    ),
                ],
              ),
            ),
          if (_options.length < 10)
            TextButton.icon(
              onPressed: _add,
              icon: const GradientIcon(Icons.add_rounded, size: 22),
              label: Text('Добавить вариант', style: TextStyle(color: context.accent.a)),
            ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _multi,
            onChanged: (v) => setState(() => _multi = v),
            title: Text('Несколько ответов', style: TextStyle(color: vc.text)),
            subtitle: Text(
              'Можно выбрать больше одного варианта',
              style: TextStyle(color: vc.textDim, fontSize: 12.5),
            ),
          ),
          const SizedBox(height: 16),
          AnimatedOpacity(
            opacity: _ready ? 1 : 0.4,
            duration: const Duration(milliseconds: 200).by(context),
            child: AccentButton(
              label: 'Отправить опрос',
              icon: Icons.poll_rounded,
              onTap: _ready
                  ? () => Navigator.of(
                      context,
                    ).pop(Poll(question: _question.text.trim(), options: _filled, multi: _multi))
                  : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Голосовые ─────────────────────────────

/// Запись голосового: AAC, моно, ~4 КБ в секунду. Собирает громкость для волны.
class VoiceRecorder {
  final _rec = AudioRecorder();
  final List<double> _levels = [];
  StreamSubscription<Amplitude>? _amp;
  String? _path;
  DateTime? _start;

  /// Последняя громкость 0..1 — для «живой» волны при записи.
  final level = ValueNotifier<double>(0);

  bool get recording => _start != null;

  /// false — нет разрешения на микрофон (системный запрос показан).
  Future<bool> start() async {
    if (!await _rec.hasPermission()) return false;
    final dir = await getTemporaryDirectory();
    _path = '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    _levels.clear();
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 32000,
        sampleRate: 24000,
        numChannels: 1,
      ),
      path: _path!,
    );
    _start = DateTime.now();
    _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 100)).listen((a) {
      _levels.add(a.current);
      level.value = ((a.current + 50) / 50).clamp(0.0, 1.0);
    });
    return true;
  }

  /// Остановить. null — отменено или слишком коротко.
  Future<({String path, int seconds, List<int> wave})?> stop({bool cancel = false}) async {
    final started = _start;
    _start = null;
    await _amp?.cancel();
    _amp = null;
    level.value = 0;
    if (started == null) return null;
    final ms = DateTime.now().difference(started).inMilliseconds;
    if (cancel || ms < 800) {
      await _rec.cancel();
      return null;
    }
    final path = await _rec.stop();
    if (path == null || !File(path).existsSync()) return null;
    return (path: path, seconds: (ms / 1000).round().clamp(1, 3600), wave: compressWave(_levels));
  }

  Future<void> dispose() async {
    await _amp?.cancel();
    level.dispose();
    await _rec.dispose();
  }
}
