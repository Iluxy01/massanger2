import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../core/media_tools.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/media_engine.dart';
import '../theme/palette.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';
import 'attach_flows.dart';
import 'chat_screen.dart';
import 'video_recorder.dart';

/// Фоны текстовых историй.
const storyBackgrounds = [
  [Color(0xFF7C5CFF), Color(0xFF00C2FF)],
  [Color(0xFFFF4F8B), Color(0xFFFFA45C)],
  [Color(0xFF00C896), Color(0xFF0098E6)],
  [Color(0xFF8E2DE2), Color(0xFFFF4F8B)],
  [Color(0xFF232526), Color(0xFF414345)],
  [Color(0xFF0F2027), Color(0xFF2C5364)],
  [Color(0xFFFFC145), Color(0xFFFF5F6D)],
  [Color(0xFF11998E), Color(0xFF38EF7D)],
];

List<Color> storyBg(int i) => storyBackgrounds[i.abs() % storyBackgrounds.length];

/// Загрузка своей истории (0..1), null — ничего не грузится.
final storyUpload = ValueNotifier<double?>(null);

String _ago(DateTime t) {
  final m = DateTime.now().difference(t).inMinutes;
  if (m < 1) return 'только что';
  if (m < 60) return '$m мин';
  return '${m ~/ 60} ч';
}

// ───────────────────────────── лента в списке чатов ─────────────────────────────

/// «Моя история», истории друзей (непросмотренные — первыми) и друзья в сети.
class StoriesRow extends StatelessWidget {
  const StoriesRow({super.key, required this.online});

  final List<Contact> online;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final withStories = app.storyContacts;
    final rest = [
      for (final c in online)
        if (!withStories.contains(c)) c,
    ];
    final count = 1 + withStories.length + rest.length;
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 20, right: 20, bottom: 10),
            child: Row(
              children: [
                Text(
                  'ИСТОРИИ',
                  style: TextStyle(
                    color: vc.textFaint,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.4,
                  ),
                ),
                const Spacer(),
                if (online.isNotEmpty) ...[
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: VeilColors.success,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'В СЕТИ: ${online.length}',
                    style: TextStyle(
                      color: vc.textFaint,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(
            height: 96,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: count,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (_, i) {
                if (i == 0) return const _MyStory();
                final story = i <= withStories.length;
                final c = story ? withStories[i - 1] : rest[i - 1 - withStories.length];
                return Reveal(
                  index: i,
                  offset: 12,
                  child: Pressable(
                    key: ValueKey('story-${c.id}'),
                    onTap: () {
                      if (story) {
                        final authors = [for (final x in app.storyContacts) x.id];
                        final at = authors.indexOf(c.id);
                        if (at >= 0) {
                          Navigator.of(context).push(StoryViewer.route(authors, at));
                          return;
                        }
                      }
                      Navigator.of(context).push(ChatScreen.route(c));
                    },
                    child: SizedBox(
                      width: 76,
                      child: Column(
                        children: [
                          SizedBox(
                            width: 66,
                            height: 66,
                            child: Center(child: Avatar.contact(c, size: 58, ring: true)),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            c.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: story && c.storyUnseen ? vc.text : vc.textDim,
                              fontSize: 12,
                              fontWeight: story && c.storyUnseen ? FontWeight.w600 : null,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _MyStory extends StatelessWidget {
  const _MyStory();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final p = app.profile;
    final mine = app.myStories;
    return Pressable(
      key: const ValueKey('story-me'),
      onTap: () => mine.isEmpty
          ? composeStory(context)
          : Navigator.of(context).push(StoryViewer.route([app.myKey], 0)),
      onLongPress: () => composeStory(context),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            SizedBox(
              width: 66,
              height: 66,
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  Avatar(
                    emoji: p?.emoji ?? '🙂',
                    colors: p?.colors ?? acc.gradient.colors,
                    size: 58,
                    ring: mine.isNotEmpty,
                  ),
                  ValueListenableBuilder<double?>(
                    valueListenable: storyUpload,
                    builder: (_, v, _) => v == null
                        ? const SizedBox.shrink()
                        : SizedBox(
                            width: 66,
                            height: 66,
                            child: CircularProgressIndicator(
                              value: v <= 0 ? null : v,
                              strokeWidth: 3,
                              color: acc.mid,
                            ),
                          ),
                  ),
                  if (mine.isEmpty)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          gradient: acc.gradient,
                          shape: BoxShape.circle,
                          border: Border.all(color: vc.bg, width: 2.5),
                        ),
                        child: Icon(Icons.add_rounded, size: 15, color: acc.onAccent),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 5),
            Text(
              'Моя история',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: vc.textDim, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── создание ─────────────────────────────

/// Новая история: текст, фото или видео.
Future<void> composeStory(BuildContext context) async {
  final vc = context.vc;
  if (storyUpload.value != null) {
    showVeilToast(context, 'Предыдущая история ещё загружается', icon: Icons.upload_rounded);
    return;
  }
  final choice = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 24,
          color: vc.elevated,
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
                  child: Text(
                    'Новая история',
                    style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(
                    'Видят друзья 24 часа, потом она исчезнет сама',
                    style: TextStyle(color: vc.textDim, fontSize: 13),
                  ),
                ),
                for (final (id, icon, title) in const [
                  ('text', Icons.text_fields_rounded, 'Текст'),
                  ('photo', Icons.photo_rounded, 'Фото из галереи'),
                  ('camera', Icons.photo_camera_rounded, 'Снять фото'),
                  ('video', Icons.video_library_rounded, 'Видео из галереи (до минуты)'),
                  ('rec', Icons.videocam_rounded, 'Снять видео'),
                ])
                  ListTile(
                    key: ValueKey('compose-$id'),
                    leading: GradientIcon(icon, size: 24),
                    title: Text(title, style: TextStyle(color: vc.text)),
                    onTap: () => Navigator.pop(ctx, id),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final app = context.appRead;
  if (choice == 'text') {
    final r = await Navigator.of(context).push<(String, int)>(TextStoryScreen.route());
    if (r == null || !context.mounted) return;
    await _publish(context, app, kind: 't', text: r.$1, bg: r.$2);
    return;
  }
  String? path;
  final video = choice == 'video' || choice == 'rec';
  try {
    if (choice == 'rec') {
      path = await Navigator.of(context).push<String>(VideoRecorderScreen.route());
    } else if (video) {
      path = (await ImagePicker().pickVideo(source: ImageSource.gallery))?.path;
    } else {
      path = (await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 80,
      ))?.path;
    }
  } catch (_) {
    if (context.mounted) {
      showVeilToast(context, 'Нет доступа', icon: Icons.no_photography_rounded);
    }
    return;
  }
  if (path == null || !context.mounted) return;
  final size = await File(path).length();
  if (!context.mounted) return;
  if (size > MediaEngine.maxBytes) {
    showVeilToast(context, 'Слишком большой файл — до 20 МБ', icon: Icons.error_outline_rounded);
    return;
  }
  final caption = await Navigator.of(
    context,
  ).push<String>(SendPreview.route(kind: video ? MsgKind.video : MsgKind.photo, paths: [path]));
  if (caption == null || !context.mounted) return;
  final Attachment meta;
  if (video) {
    final v = await videoMeta(path);
    if (v.seconds > 62) {
      if (context.mounted) {
        showVeilToast(context, 'Видео для истории — до минуты', icon: Icons.timer_rounded);
      }
      return;
    }
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'mp4';
    meta = Attachment(
      name: 'story.$ext',
      mime: mimeFor('x.$ext').startsWith('video/') ? mimeFor('x.$ext') : 'video/mp4',
      size: size,
      width: v.width,
      height: v.height,
      duration: v.seconds,
    );
  } else {
    final m = await imageMeta(path);
    meta = Attachment(
      name: 'story.jpg',
      mime: mimeFor(path).startsWith('image/') ? mimeFor(path) : 'image/jpeg',
      size: size,
      width: m.width,
      height: m.height,
      thumb: m.thumb,
    );
  }
  if (!context.mounted) return;
  await _publish(
    context,
    app,
    kind: video ? 'v' : 'p',
    text: caption.trim(),
    path: path,
    meta: meta,
  );
}

Future<void> _publish(
  BuildContext context,
  AppState app, {
  required String kind,
  String text = '',
  int bg = 0,
  String? path,
  Attachment? meta,
}) async {
  final progress = ValueNotifier<double>(0);
  void sync() => storyUpload.value = progress.value;
  progress.addListener(sync);
  storyUpload.value = 0;
  Story? st;
  try {
    st = await app.postStory(
      kind: kind,
      text: text,
      bg: bg,
      path: path,
      meta: meta,
      progress: progress,
    );
  } catch (_) {
    st = null;
  } finally {
    progress.removeListener(sync);
    progress.dispose();
    storyUpload.value = null;
  }
  if (!context.mounted) return;
  showVeilToast(
    context,
    st != null ? 'История опубликована на 24 часа' : 'Не получилось — нет связи',
    icon: st != null ? Icons.auto_awesome_rounded : Icons.cloud_off_rounded,
  );
}

/// Текстовая история: крупный текст на градиенте.
class TextStoryScreen extends StatefulWidget {
  const TextStoryScreen({super.key});

  static Route<(String, int)> route() =>
      MaterialPageRoute(builder: (_) => const TextStoryScreen(), fullscreenDialog: true);

  @override
  State<TextStoryScreen> createState() => _TextStoryScreenState();
}

class _TextStoryScreenState extends State<TextStoryScreen> {
  final _text = TextEditingController();
  int _bg = Random().nextInt(storyBackgrounds.length);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = storyBg(_bg);
    return Scaffold(
      backgroundColor: colors.first,
      resizeToAvoidBottomInset: true,
      body: AnimatedContainer(
        duration: const Duration(milliseconds: 300).by(context),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                  const Spacer(),
                  ListenableBuilder(
                    listenable: _text,
                    builder: (_, _) => TextButton(
                      key: const ValueKey('story-publish'),
                      onPressed: _text.text.trim().isEmpty
                          ? null
                          : () => Navigator.pop(context, (_text.text.trim(), _bg)),
                      child: Text(
                        'Опубликовать',
                        style: TextStyle(
                          color: Colors.white.withValues(
                            alpha: _text.text.trim().isEmpty ? 0.5 : 1,
                          ),
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: TextField(
                      key: const ValueKey('story-text'),
                      controller: _text,
                      autofocus: true,
                      maxLines: null,
                      maxLength: 300,
                      textAlign: TextAlign.center,
                      cursorColor: Colors.white,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        height: 1.25,
                      ),
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        counterText: '',
                        hintText: 'Что нового?',
                        hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 56,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  itemCount: storyBackgrounds.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => setState(() => _bg = i),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: storyBg(i)),
                        border: Border.all(color: Colors.white, width: i == _bg ? 3 : 1.2),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── просмотр ─────────────────────────────

/// Просмотр историй: авторы листаются вбок, истории автора — касанием.
/// Удержание — пауза, смахивание вниз — закрыть.
class StoryViewer extends StatefulWidget {
  const StoryViewer({super.key, required this.authors, required this.start});

  /// Ключи авторов по порядку.
  final List<String> authors;
  final int start;

  static Route<void> route(List<String> authors, int start) => PageRouteBuilder(
    opaque: true,
    transitionDuration: const Duration(milliseconds: 260),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, _, _) => StoryViewer(authors: authors, start: start),
    transitionsBuilder: (_, a, _, child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween(
          begin: 0.94,
          end: 1.0,
        ).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );

  @override
  State<StoryViewer> createState() => _StoryViewerState();
}

class _StoryViewerState extends State<StoryViewer> {
  late final _pages = PageController(initialPage: widget.start);
  late int _page = widget.start;
  double _drag = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_page + 1 < widget.authors.length) {
      _pages.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  void _prev() {
    if (_page > 0) {
      _pages.previousPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: GestureDetector(
        onVerticalDragUpdate: (d) => setState(() => _drag = max(0, _drag + d.delta.dy)),
        onVerticalDragEnd: (d) {
          if (_drag > 120 || (d.primaryVelocity ?? 0) > 700) {
            Navigator.of(context).maybePop();
          } else {
            setState(() => _drag = 0);
          }
        },
        child: Transform.translate(
          offset: Offset(0, _drag),
          child: Opacity(
            opacity: (1 - _drag / 600).clamp(0.4, 1),
            child: PageView.builder(
              controller: _pages,
              itemCount: widget.authors.length,
              onPageChanged: (i) => setState(() => _page = i),
              itemBuilder: (_, i) => _AuthorStories(
                key: ValueKey(widget.authors[i]),
                author: widget.authors[i],
                active: i == _page && _drag == 0,
                onDone: _next,
                onBack: _prev,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthorStories extends StatefulWidget {
  const _AuthorStories({
    super.key,
    required this.author,
    required this.active,
    required this.onDone,
    required this.onBack,
  });

  final String author;
  final bool active;
  final VoidCallback onDone;
  final VoidCallback onBack;

  @override
  State<_AuthorStories> createState() => _AuthorStoriesState();
}

class _AuthorStoriesState extends State<_AuthorStories> with SingleTickerProviderStateMixin {
  late final AppState _app = context.appRead;
  late final List<Story> _list = _app.storiesOf(widget.author);
  late final _progress = AnimationController(vsync: this)..addStatusListener(_onStatus);
  final _reply = TextEditingController();
  final _replyFocus = FocusNode();
  int _i = 0;

  /// Файл текущей истории (фото / видео), ошибка загрузки.
  String? _path;
  bool _failed = false;
  bool _loading = false;
  VideoPlayerController? _video;
  bool _holding = false;

  bool get _mine => widget.author == _app.myKey;

  @override
  void initState() {
    super.initState();
    // Чужие — с первой непросмотренной.
    if (!_mine) {
      final unseen = _list.indexWhere((s) => !s.seen);
      if (unseen > 0) _i = unseen;
    }
    _replyFocus.addListener(_syncPause);
    if (_list.isNotEmpty) _show(_i);
  }

  @override
  void didUpdateWidget(_AuthorStories old) {
    super.didUpdateWidget(old);
    if (old.active == widget.active) return;
    if (widget.active && _list.isNotEmpty) {
      // Вернулись к автору, чьи истории уже досмотрены, — показать заново.
      if (_progress.isCompleted) {
        _show(_i);
        return;
      }
      unawaited(_app.viewStory(_list[_i]));
    }
    _syncPause();
  }

  @override
  void dispose() {
    _progress.dispose();
    _video?.dispose();
    _reply.dispose();
    _replyFocus.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus s) {
    if (s == AnimationStatus.completed) _forward();
  }

  bool get _paused => !widget.active || _holding || _replyFocus.hasFocus || _loading;

  void _syncPause() {
    if (!mounted) return;
    if (_paused) {
      _progress.stop();
      _video?.pause();
    } else if (_list.isNotEmpty && _progress.duration != null) {
      _progress.forward();
      _video?.play();
    }
  }

  Future<void> _show(int i) async {
    final st = _list[i];
    _progress
      ..stop()
      ..value = 0;
    final old = _video;
    _video = null;
    unawaited(old?.dispose());
    setState(() {
      _i = i;
      _path = null;
      _failed = false;
      _loading = st.kind != 't';
    });
    if (widget.active) unawaited(_app.viewStory(st));
    if (st.kind == 't') {
      _progress.duration = Duration(milliseconds: 4000 + min(st.text.length, 200) * 25);
      _syncPause();
      return;
    }
    final path = await _app.storyFile(st);
    if (!mounted || _i != i) return;
    if (path == null) {
      setState(() {
        _failed = true;
        _loading = false;
      });
      _progress.duration = const Duration(seconds: 4);
      _syncPause();
      return;
    }
    if (st.kind == 'p') {
      final size = MediaQuery.sizeOf(context);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      try {
        await precacheImage(
          ResizeImage(FileImage(File(path)), width: (size.width * dpr).round()),
          context,
        );
      } catch (_) {}
      if (!mounted || _i != i) return;
      _progress.duration = const Duration(seconds: 6);
    } else {
      final v = VideoPlayerController.file(File(path));
      try {
        await v.initialize();
      } catch (_) {
        await v.dispose();
        if (!mounted || _i != i) return;
        setState(() {
          _failed = true;
          _loading = false;
        });
        _progress.duration = const Duration(seconds: 4);
        _syncPause();
        return;
      }
      if (!mounted || _i != i) {
        await v.dispose();
        return;
      }
      _video = v;
      final d = v.value.duration;
      _progress.duration = d.inMilliseconds < 1000 ? const Duration(seconds: 5) : d;
    }
    setState(() {
      _path = path;
      _loading = false;
    });
    _syncPause();
  }

  void _forward() {
    if (_i + 1 < _list.length) {
      _show(_i + 1);
    } else {
      widget.onDone();
    }
  }

  void _back() {
    if (_i > 0) {
      _show(_i - 1);
    } else {
      widget.onBack();
      _show(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_list.isEmpty) {
      return const Center(
        child: Text('Истории закончились', style: TextStyle(color: Colors.white70)),
      );
    }
    final st = _list[_i];
    final contact = _mine ? null : _app.contact(widget.author);
    final p = _app.profile;
    final pad = MediaQuery.paddingOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Содержимое и касания: слева — назад, справа — дальше, удержание — пауза.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            if (_replyFocus.hasFocus) {
              _replyFocus.unfocus();
              return;
            }
            d.localPosition.dx < MediaQuery.sizeOf(context).width / 3 ? _back() : _forward();
          },
          onLongPressStart: (_) {
            _holding = true;
            _syncPause();
          },
          onLongPressEnd: (_) {
            _holding = false;
            _syncPause();
          },
          child: _content(st),
        ),
        // Сверху: полоски, автор, время.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(10, pad.top + 8, 6, 16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x88000000), Color(0x00000000)],
              ),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 3,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: const Size(double.infinity, 3),
                      painter: _Segments(_list.length, _i, _progress),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (contact != null)
                      Avatar.contact(contact, size: 34, showOnline: false)
                    else
                      Avatar(
                        emoji: p?.emoji ?? '🙂',
                        colors: p?.colors ?? const [Colors.grey, Colors.grey],
                        size: 34,
                      ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        contact?.name ?? 'Моя история',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _ago(st.time),
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 13),
                    ),
                    const Spacer(),
                    if (_mine)
                      IconButton(
                        key: const ValueKey('story-add'),
                        tooltip: 'Ещё история',
                        onPressed: () async {
                          _holding = true;
                          _syncPause();
                          await composeStory(context);
                          _holding = false;
                          _syncPause();
                        },
                        icon: const Icon(Icons.add_circle_outline_rounded, color: Colors.white),
                      ),
                    IconButton(
                      tooltip: 'Закрыть',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: _mine ? _ownBar(st, pad) : _replyBar(st, contact, pad),
        ),
      ],
    );
  }

  Widget _content(Story st) {
    if (st.kind == 't') {
      final colors = storyBg(st.bg);
      final size = st.text.length > 160 ? 22.0 : (st.text.length > 60 ? 26.0 : 32.0);
      return DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              st.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: size,
                fontWeight: FontWeight.w800,
                height: 1.25,
              ),
            ),
          ),
        ),
      );
    }
    final Widget media;
    final path = _path, v = _video;
    if (_failed) {
      media = const Center(
        child: Text('Не удалось загрузить — нет связи', style: TextStyle(color: Colors.white70)),
      );
    } else if (path == null) {
      media = const Center(
        child: SizedBox(
          width: 34,
          height: 34,
          child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white70),
        ),
      );
    } else if (st.kind == 'v' && v != null) {
      media = Center(
        child: AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
      );
    } else {
      final size = MediaQuery.sizeOf(context);
      final dpr = MediaQuery.devicePixelRatioOf(context);
      media = Image.file(
        File(path),
        fit: BoxFit.contain,
        cacheWidth: (size.width * dpr).round(),
        gaplessPlayback: true,
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        media,
        if (st.text.isNotEmpty)
          Positioned(
            left: 0,
            right: 0,
            bottom: 96 + MediaQuery.paddingOf(context).bottom,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                st.text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.3),
              ),
            ),
          ),
      ],
    );
  }

  Widget _replyBar(Story st, Contact? c, EdgeInsets pad) {
    final bottom = max(pad.bottom, MediaQuery.viewInsetsOf(context).bottom);
    void send(String text) {
      final t = text.trim();
      if (t.isEmpty || c == null) return;
      _app.send(c.id, t, story: st.preview);
      _reply.clear();
      _replyFocus.unfocus();
      showVeilToast(context, 'Ответ отправлен в личку', icon: Icons.send_rounded);
    }

    return Container(
      padding: EdgeInsets.fromLTRB(12, 18, 12, bottom + 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0x88000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
              ),
              child: TextField(
                key: const ValueKey('story-reply'),
                controller: _reply,
                focusNode: _replyFocus,
                enabled: c != null,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                textInputAction: TextInputAction.send,
                onSubmitted: send,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  hintText: 'Ответить ${c?.name ?? ''}…',
                  hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          ListenableBuilder(
            listenable: _reply,
            builder: (_, _) => _reply.text.trim().isEmpty
                ? IconButton(
                    key: const ValueKey('story-heart'),
                    tooltip: 'Нравится',
                    onPressed: () => send('❤️'),
                    icon: const Text('❤️', style: TextStyle(fontSize: 26)),
                  )
                : IconButton(
                    tooltip: 'Отправить',
                    onPressed: () => send(_reply.text),
                    icon: const Icon(Icons.send_rounded, color: Colors.white),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _ownBar(Story st, EdgeInsets pad) {
    final n = st.viewers.length;
    return Container(
      padding: EdgeInsets.fromLTRB(12, 18, 12, pad.bottom + 10),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0x88000000), Color(0x00000000)],
        ),
      ),
      child: Row(
        children: [
          TextButton.icon(
            key: const ValueKey('story-viewers'),
            onPressed: () => _viewers(st),
            icon: const Icon(Icons.visibility_rounded, color: Colors.white),
            label: Text(
              n == 0 ? 'Пока никто' : 'Посмотрели: $n',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('story-delete'),
            tooltip: 'Удалить у всех',
            onPressed: () => _delete(st),
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Future<void> _viewers(Story st) async {
    _holding = true;
    _syncPause();
    final vc = _app.colors;
    final list = st.viewers.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Glass(
            radius: 24,
            color: vc.elevated,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.6),
              child: Material(
                type: MaterialType.transparency,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Кто посмотрел',
                      style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Видно, только если у друга включены отчёты о прочтении',
                      style: TextStyle(color: vc.textDim, fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    if (list.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text('Пока никто', style: TextStyle(color: vc.textDim)),
                      )
                    else
                      Flexible(
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            for (final e in list)
                              if (_app.contact(e.key) case final c?)
                                ListTile(
                                  leading: Avatar.contact(c, size: 40, showOnline: false),
                                  title: Text(c.name, style: TextStyle(color: vc.text)),
                                  trailing: Text(
                                    _ago(DateTime.fromMillisecondsSinceEpoch(e.value)),
                                    style: TextStyle(color: vc.textDim, fontSize: 12.5),
                                  ),
                                ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    _holding = false;
    _syncPause();
  }

  Future<void> _delete(Story st) async {
    _holding = true;
    _syncPause();
    final vc = _app.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        title: Text('Удалить историю?', style: TextStyle(color: vc.text)),
        content: Text('Она пропадёт и у друзей.', style: TextStyle(color: vc.textDim)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить', style: TextStyle(color: VeilColors.danger)),
          ),
        ],
      ),
    );
    _holding = false;
    if (ok != true || !mounted) {
      _syncPause();
      return;
    }
    await _app.deleteStory(st);
    if (!mounted) return;
    _list.remove(st);
    if (_list.isEmpty) {
      Navigator.of(context).maybePop();
      return;
    }
    _show(min(_i, _list.length - 1));
  }
}

/// Полоски сверху: просмотренные — полные, текущая — по ходу.
class _Segments extends CustomPainter {
  _Segments(this.count, this.index, this.t) : super(repaint: t);

  final int count;
  final int index;
  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 4.0;
    final w = (size.width - gap * (count - 1)) / count;
    final bg = Paint()..color = Colors.white.withValues(alpha: 0.35);
    final fg = Paint()..color = Colors.white;
    for (var i = 0; i < count; i++) {
      final x = i * (w + gap);
      final r = RRect.fromLTRBR(x, 0, x + w, size.height, const Radius.circular(2));
      canvas.drawRRect(r, bg);
      final f = i < index ? 1.0 : (i == index ? t.value : 0.0);
      if (f > 0) {
        canvas.drawRRect(
          RRect.fromLTRBR(x, 0, x + w * f, size.height, const Radius.circular(2)),
          fg,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Segments old) => old.count != count || old.index != index;
}
