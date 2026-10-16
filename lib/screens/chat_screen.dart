import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/media_tools.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../state/mock_data.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import '../widgets/attachments.dart';
import '../widgets/effects.dart';
import '../widgets/rich_text.dart';
import '../widgets/video_note.dart';
import '../widgets/visual.dart';
import 'attach_flows.dart';
import 'contact_screen.dart';
import 'group_screens.dart';
import 'wifi_hint.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.contact, this.jumpTo});

  final Contact contact;

  /// Сразу показать это сообщение (из «Избранного»).
  final String? jumpTo;

  static Route<void> route(Contact c, {String? jumpTo}) => MaterialPageRoute(
    builder: (_) => ChatScreen(contact: c, jumpTo: jumpTo),
  );

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// Элемент ленты: дата, сообщение, баннер шифрования или «печатает».
sealed class _Item {}

class _DateItem extends _Item {
  _DateItem(this.time);
  final DateTime time;
}

class _MsgItem extends _Item {
  _MsgItem(this.m, {required this.first, required this.last});
  final Message m;
  final bool first;
  final bool last;
}

class _BannerItem extends _Item {}

class _TypingItem extends _Item {}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  late final AppState _app;
  late final Set<String> _animated;

  Message? _replyTo;

  /// Редактируем своё сообщение (поле ввода — его текст).
  Message? _editing;
  bool _secret = false;

  // Поиск по чату: совпадения (новые первыми) и текущее.
  bool _searching = false;
  final _searchInput = TextEditingController();
  List<String> _hits = const [];
  int _hit = 0;

  // Переход к сообщению: ключи плиток и подсветка найденного.
  final Map<String, GlobalKey> _tileKeys = {};
  String? _flash;
  Timer? _flashTimer;
  List<_Item> _items = const [];
  bool _attachOpen = false;
  bool _showDown = false;
  int _seen = 0;

  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;
  VoiceRecorder? _voice;

  /// Кнопка в режиме видеосообщения («квадратик»), а не голосового.
  bool _noteMode = false;
  NoteRecorder? _noteRec;

  /// Камера для видеосообщения открывается (запись ещё не началась).
  bool _noteOpening = false;

  /// Идёт запись именно видеосообщения.
  bool _recNote = false;

  /// Палец увели влево во время записи — отпустит, и запись отменится.
  bool _cancelArmed = false;

  /// Палец всё ещё на кнопке микрофона (запуск записи асинхронный: пока
  /// спрашиваем разрешение, кнопку могли уже отпустить).
  bool _holding = false;

  Contact get c => widget.contact;

  @override
  void initState() {
    super.initState();
    _app = context.appRead;
    _input.text = _app.drafts[c.id] ?? '';
    var last = _input.text;
    // Без setState: иначе каждая буква перестраивала весь экран со списком
    // сообщений. Кнопка «отправить/микрофон» слушает поле сама.
    _input.addListener(() {
      if (_input.text.isNotEmpty && _input.text != last) _app.userTyping(c.id);
      last = _input.text;
    });
    _animated = _app.messagesOf(c.id).map((m) => m.id).toSet();
    _seen = _app.messagesOf(c.id).length;
    _app.openChat = c.id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _app.markRead(c.id);
      final j = widget.jumpTo;
      if (j != null) _jumpTo(j);
    });
    _scroll.addListener(_onScroll);
    _focus.addListener(() {
      if (_focus.hasFocus && _attachOpen) setState(() => _attachOpen = false);
    });
  }

  void _onScroll() {
    final down = _scroll.offset > 280;
    if (!down) _seen = _app.messagesOf(c.id).length;
    if (down != _showDown) setState(() => _showDown = down);
  }

  @override
  void dispose() {
    if (_app.openChat == c.id) _app.openChat = null;
    _app.saveDraft(c.id, _input.text);
    _recTimer?.cancel();
    _voice?.stop(cancel: true).whenComplete(() => _voice?.dispose());
    _noteRec?.stop(cancel: true);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    _searchInput.dispose();
    _flashTimer?.cancel();
    super.dispose();
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
  }

  void _send({bool silent = false}) {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _app.tick(HapticKind.light);
    final editing = _editing;
    if (editing != null) {
      _app.editMessage(c.id, editing, text);
      _input.clear();
      setState(() => _editing = null);
      return;
    }
    _app.send(c.id, text, replyTo: _replyTo, secret: _secret, silent: silent);
    if (silent) {
      showVeilToast(context, 'Отправлено без звука', icon: Icons.notifications_off_rounded);
    }
    _input.clear();
    setState(() {
      _replyTo = null;
      _secret = false;
    });
    _toBottom();
  }

  void _setReply(Message m) {
    _app.tick(HapticKind.medium);
    setState(() {
      _replyTo = m;
      if (_editing != null) {
        _editing = null;
        _input.clear();
      }
    });
    _focus.requestFocus();
  }

  // ───────────── действия с сообщением ─────────────

  void _onAction(Message m, String action) {
    switch (action) {
      case 'reply':
        _setReply(m);
      case 'edit':
        setState(() {
          _editing = m;
          _replyTo = null;
          _secret = false;
        });
        _input.text = m.text;
        _input.selection = TextSelection.collapsed(offset: m.text.length);
        _focus.requestFocus();
      case 'forward':
        _forward(m);
      case 'pin':
        final pinned = c.pinnedMsg == m.id;
        _app.pinMessage(c.id, pinned ? null : m);
        showVeilToast(
          context,
          pinned ? 'Откреплено' : 'Закреплено вверху чата',
          icon: Icons.push_pin_rounded,
        );
      case 'star':
        _app.toggleStar(c.id, m);
        showVeilToast(
          context,
          _app.isStarred(c.id, m) ? 'Добавлено в избранное' : 'Убрано из избранного',
          icon: Icons.star_rounded,
        );
      case 'deleteAll':
        _app.deleteForAll(c.id, m);
      case 'jumpReply':
        final r = m.replyTo;
        if (r != null) _jumpTo(r.id);
    }
  }

  Future<void> _forward(Message m) async {
    final target = await pickChat(context, title: 'Переслать в…');
    if (target == null || !mounted) return;
    final sent = await _app.forward(c.id, m, target.id);
    if (!mounted) return;
    showVeilToast(
      context,
      sent == null
          ? 'Сначала скачай файл — потом его можно переслать'
          : 'Переслано: ${target.name}',
      icon: sent == null ? Icons.download_rounded : Icons.forward_rounded,
    );
  }

  /// Прокрутить к сообщению и подсветить его.
  Future<void> _jumpTo(String id) async {
    var idx = _items.indexWhere((i) => i is _MsgItem && i.m.id == id);
    if (idx < 0) {
      showVeilToast(context, 'Сообщение не найдено', icon: Icons.search_off_rounded);
      return;
    }
    for (var attempt = 0; attempt < 30 && mounted; attempt++) {
      final ctx = _tileKeys[id]?.currentContext;
      if (ctx != null && ctx.mounted) {
        await Scrollable.ensureVisible(
          ctx,
          alignment: 0.45,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
        );
        if (!mounted) return;
        _flashTimer?.cancel();
        setState(() => _flash = id);
        _flashTimer = Timer(const Duration(milliseconds: 1400), () {
          if (mounted) setState(() => _flash = null);
        });
        return;
      }
      if (!_scroll.hasClients) return;
      // Плитка ещё не построена — едем в её сторону (лента перевёрнута).
      final built = [
        for (final (i, it) in _items.indexed)
          if (it is _MsgItem && _tileKeys[it.m.id]?.currentContext != null) i,
      ];
      final pos = _scroll.position;
      final step = pos.viewportDimension * 0.8;
      final dir = built.isEmpty ? 1 : (idx > built.last ? 1 : (idx < built.first ? -1 : 1));
      final next = (pos.pixels + dir * step).clamp(0.0, pos.maxScrollExtent);
      if (next == pos.pixels) break;
      _scroll.jumpTo(next);
      await WidgetsBinding.instance.endOfFrame;
      idx = _items.indexWhere((i) => i is _MsgItem && i.m.id == id);
    }
  }

  // ───────────── поиск ─────────────

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      _searchInput.clear();
      _hits = const [];
      _hit = 0;
    });
  }

  void _runSearch(String q) {
    final query = q.trim().toLowerCase();
    final hits = query.isEmpty
        ? <String>[]
        : [
            for (final m in _app.messagesOf(c.id).reversed)
              if (!m.secret && _app.previewOf(c.id, m).toLowerCase().contains(query)) m.id,
          ];
    setState(() {
      _hits = hits;
      _hit = 0;
    });
    if (hits.isNotEmpty) _jumpTo(hits.first);
  }

  void _nextHit(int delta) {
    if (_hits.isEmpty) return;
    setState(() => _hit = (_hit + delta) % _hits.length);
    _jumpTo(_hits[_hit]);
  }

  Future<void> _startRecording() async {
    // Первая отправка с Wi-Fi — сначала подсказка (запись не начинаем).
    if (!_app.demo && !_app.wifiHintShown && await onWifi()) {
      _holding = false;
      if (mounted) await wifiHint(context);
      return;
    }
    if (!mounted) return;
    if (_noteMode) return _startNote();
    _app.tick(HapticKind.medium);
    if (!_app.demo) {
      final v = _voice ??= VoiceRecorder();
      bool ok;
      try {
        ok = await v.start();
      } catch (_) {
        ok = false;
      }
      if (!ok) {
        if (mounted) {
          showVeilToast(
            context,
            'Разреши доступ к микрофону и удерживай снова',
            icon: Icons.mic_off_rounded,
          );
        }
        return;
      }
      if (!_holding || !mounted) {
        // Отпустили, пока система спрашивала разрешение, — не пишем «в пустоту».
        await v.stop(cancel: true);
        if (mounted) {
          showVeilToast(
            context,
            'Удерживай кнопку, чтобы записать голосовое',
            icon: Icons.mic_rounded,
          );
        }
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _recording = true;
      _recSeconds = 0;
      _cancelArmed = false;
      _attachOpen = false;
    });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _recSeconds++);
      if (_recSeconds >= 300) _stopRecording(); // не длиннее 5 минут
    });
  }

  /// Долгое нажатие на «отправить»: варианты отправки.
  Future<void> _sendMenu() async {
    _app.tick(HapticKind.medium);
    final vc = _app.colors;
    final silent = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Glass(
            radius: 24,
            color: vc.elevated,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: ListTile(
              leading: const GradientIcon(Icons.notifications_off_rounded, size: 24),
              title: Text('Отправить без звука', style: TextStyle(color: vc.text)),
              subtitle: Text(
                'Придёт тихо, без уведомления',
                style: TextStyle(color: vc.textDim, fontSize: 12.5),
              ),
              onTap: () => Navigator.pop(ctx, true),
            ),
          ),
        ),
      ),
    );
    if (silent == true && mounted) _send(silent: true);
  }

  Future<void> _startNote() async {
    if (_app.demo) {
      showVeilToast(
        context,
        'В демо-версии видеосообщения не отправляются',
        icon: Icons.cloud_off_rounded,
      );
      return;
    }
    _app.tick(HapticKind.medium);
    final r = _noteRec ??= NoteRecorder();
    setState(() {
      _noteOpening = true;
      _attachOpen = false;
      _cancelArmed = false;
    });
    FocusScope.of(context).unfocus();
    final ok = await r.start(back: _app.noteCamera == 1);
    if (!mounted) {
      await r.stop(cancel: true);
      return;
    }
    if (!ok) {
      setState(() => _noteOpening = false);
      showVeilToast(
        context,
        'Разреши доступ к камере и микрофону и удерживай снова',
        icon: Icons.videocam_off_rounded,
      );
      return;
    }
    if (!_holding) {
      // Отпустили, пока камера открывалась (или система спрашивала разрешение).
      await r.stop(cancel: true);
      if (!mounted) return;
      setState(() => _noteOpening = false);
      showVeilToast(
        context,
        'Удерживай кнопку, чтобы записать видеосообщение',
        icon: Icons.videocam_rounded,
      );
      return;
    }
    setState(() {
      _noteOpening = false;
      _recNote = true;
      _recording = true;
      _recSeconds = 0;
    });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _recSeconds++);
      if (_recSeconds >= VideoNote.maxSeconds) _stopRecording();
    });
  }

  Future<void> _flipNote() async {
    final r = _noteRec;
    if (r == null) return;
    _app.tick(HapticKind.selection);
    if (await r.flip() && mounted) setState(() {});
  }

  void _toggleNoteMode() {
    _app.tick(HapticKind.selection);
    setState(() => _noteMode = !_noteMode);
    showVeilToast(
      context,
      _noteMode
          ? 'Видеосообщение: удерживай кнопку и говори в камеру'
          : 'Голосовое: удерживай кнопку и говори',
      icon: _noteMode ? Icons.videocam_rounded : Icons.mic_rounded,
    );
  }

  Future<void> _stopNote({required bool cancelled, required int secs}) async {
    final replyTo = _replyTo;
    final path = await _noteRec?.stop(cancel: cancelled || secs < 1);
    if (!mounted) return;
    setState(() => _recNote = false);
    if (path == null) {
      if (!cancelled) {
        showVeilToast(
          context,
          'Удерживай кнопку, чтобы записать видеосообщение',
          icon: Icons.videocam_rounded,
        );
      }
      return;
    }
    _app.tick(HapticKind.light);
    await _app.sendFile(
      c.id,
      kind: MsgKind.note,
      path: path,
      name: 'note.mp4',
      mime: 'video/mp4',
      size: File(path).lengthSync(),
      width: 1,
      height: 1,
      duration: secs,
      replyTo: replyTo,
    );
    if (!mounted) return;
    setState(() => _replyTo = null);
    _toBottom();
  }

  void _dragRecording(double dx) {
    final armed = dx < -90;
    if (armed != _cancelArmed && _recording) {
      if (armed) _app.tick(HapticKind.selection);
      setState(() => _cancelArmed = armed);
    }
  }

  Future<void> _stopRecording({bool cancel = false}) async {
    if (!_recording) return;
    _recTimer?.cancel();
    final secs = _recSeconds;
    final cancelled = cancel || _cancelArmed;
    setState(() {
      _recording = false;
      _cancelArmed = false;
    });
    if (_recNote) return _stopNote(cancelled: cancelled, secs: secs);
    final replyTo = _replyTo;
    if (_app.demo) {
      if (cancelled || secs < 1) {
        if (!cancelled) {
          showVeilToast(
            context,
            'Удерживай кнопку, чтобы записать голосовое',
            icon: Icons.mic_rounded,
          );
        }
        return;
      }
      _app.tick(HapticKind.light);
      _app.send(c.id, '', kind: MsgKind.voice, voiceSeconds: secs, replyTo: replyTo);
    } else {
      final rec = await _voice?.stop(cancel: cancelled);
      if (!mounted) return;
      if (rec == null) {
        if (!cancelled) {
          showVeilToast(
            context,
            'Удерживай кнопку, чтобы записать голосовое',
            icon: Icons.mic_rounded,
          );
        }
        return;
      }
      _app.tick(HapticKind.light);
      await _app.sendFile(
        c.id,
        kind: MsgKind.voice,
        path: rec.path,
        name: 'voice.m4a',
        mime: 'audio/mp4',
        size: File(rec.path).lengthSync(),
        duration: rec.seconds,
        wave: rec.wave,
        replyTo: replyTo,
      );
    }
    if (!mounted) return;
    setState(() => _replyTo = null);
    _toBottom();
  }

  Future<void> _attach(String what) async {
    setState(() => _attachOpen = false);
    final flows = AttachFlows(context, c.id, replyTo: _replyTo);
    switch (what) {
      case 'photo':
        await flows.photos();
      case 'camera':
        await flows.photos(camera: true);
      case 'video':
        await flows.video();
      case 'file':
        await flows.file();
      case 'geo':
        await flows.location();
      case 'poll':
        await flows.poll();
    }
    if (!mounted) return;
    if (_replyTo != null && _app.lastMessage(c.id)?.replyTo == _replyTo) {
      setState(() => _replyTo = null);
    }
    _toBottom();
  }

  List<_Item> _buildItems(List<Message> msgs, bool typing) {
    final items = <_Item>[_BannerItem()];
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      final prev = i > 0 ? msgs[i - 1] : null;
      final next = i < msgs.length - 1 ? msgs[i + 1] : null;
      if (prev == null || !sameDay(prev.time, m.time)) items.add(_DateItem(m.time));
      bool joined(Message? a, Message b) =>
          a != null &&
          a.mine == b.mine &&
          a.from == b.from &&
          a.kind != MsgKind.event &&
          b.kind != MsgKind.event &&
          sameDay(a.time, b.time) &&
          a.time.difference(b.time).inMinutes.abs() < 3;
      items.add(_MsgItem(m, first: !joined(prev, m), last: !joined(next, m)));
    }
    if (typing) items.add(_TypingItem());
    return items.reversed.toList();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final msgs = app.messagesOf(c.id);
    final typing = app.typingIndicators && app.typing.contains(c.id);
    final items = _items = _buildItems(msgs, typing);
    final pinnedMsg = app.pinnedOf(c.id);
    final top = MediaQuery.paddingOf(context).top;
    final newBelow = _showDown ? max(0, msgs.length - _seen) : 0;

    return Scaffold(
      backgroundColor: vc.bg,
      body: Stack(
        children: [
          const Positioned.fill(child: _ChatBackground()),
          Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _messageList(items, top + (pinnedMsg != null ? 50 : 0)),
                    if (_noteOpening || _recNote)
                      NoteRecordingOverlay(
                        recorder: _noteRec!,
                        seconds: _recSeconds,
                        recording: _recNote,
                        cancel: _cancelArmed,
                        onFlip: _recNote ? _flipNote : null,
                      ),
                  ],
                ),
              ),
              if (c.request && !c.blocked) _RequestBar(contact: c),
              if (c.blocked)
                _BlockedBar(onUnblock: () => app.toggleBlocked(c.id))
              else if (c.group?.left ?? false)
                const _LeftGroupBar()
              else
                _composer(context),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(
              contact: c,
              typing: typing,
              onSearch: _toggleSearch,
              search: _searching
                  ? _SearchRow(
                      input: _searchInput,
                      hits: _hits.length,
                      hit: _hit,
                      onChanged: _runSearch,
                      onNext: () => _nextHit(1),
                      onPrev: () => _nextHit(-1),
                      onClose: _toggleSearch,
                    )
                  : null,
              pinned: pinnedMsg == null
                  ? null
                  : _PinnedBar(
                      text: app.previewOf(c.id, pinnedMsg),
                      onTap: () => _jumpTo(pinnedMsg.id),
                      onClose: () => app.pinMessage(c.id, null),
                    ),
            ),
          ),
          Positioned(
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + (_replyTo != null ? 150 : 96),
            child: AnimatedScale(
              scale: _showDown ? 1 : 0,
              duration: const Duration(milliseconds: 260).by(context),
              curve: Curves.easeOutBack,
              child: _ScrollDownButton(count: newBelow, onTap: _toBottom),
            ),
          ),
        ],
      ),
    );
  }

  Widget _messageList(List<_Item> items, double top) => GestureDetector(
    onTap: () {
      FocusScope.of(context).unfocus();
      if (_attachOpen) setState(() => _attachOpen = false);
    },
    child: ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(12, 12, 12, top + 76),
      itemCount: items.length,
      itemBuilder: (_, i) => switch (items[i]) {
        _DateItem(:final time) => _DateChip(time: time),
        _BannerItem() => _EncryptionBanner(contact: c),
        _TypingItem() => const _TypingBubble(),
        _MsgItem(:final m) when m.kind == MsgKind.event => _EventChip(m: m, chatId: c.id),
        _MsgItem(:final m, :final first, :final last) => KeyedSubtree(
          key: _tileKeys.putIfAbsent(m.id, GlobalKey.new),
          child: _MessageTile(
            key: ValueKey(m.id),
            m: m,
            contact: c,
            first: first,
            last: last,
            animate: !_animated.contains(m.id),
            highlight: _flash == m.id,
            onAnimated: () => _animated.add(m.id),
            onReply: () => _setReply(m),
            onAction: (a) => _onAction(m, a),
          ),
        ),
      },
    ),
  );

  Widget _composer(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, bottom + 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 280).by(context),
            curve: Curves.easeOutCubic,
            child: _attachOpen
                ? _AttachMenu(onPick: _attach)
                : const SizedBox(width: double.infinity),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250).by(context),
            curve: Curves.easeOutCubic,
            child: _editing != null
                ? _ReplyPreview(
                    m: _editing!,
                    contact: c,
                    editing: true,
                    onClose: () {
                      _input.clear();
                      setState(() => _editing = null);
                    },
                  )
                : _replyTo == null
                ? const SizedBox(width: double.infinity)
                : _ReplyPreview(
                    m: _replyTo!,
                    contact: c,
                    onClose: () => setState(() => _replyTo = null),
                  ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300).by(context),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              boxShadow: _secret
                  ? [
                      BoxShadow(
                        color: acc.mid.withValues(alpha: 0.5),
                        blurRadius: 22,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Glass(
              blur: 20,
              radius: 28,
              padding: const EdgeInsets.all(5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Pressable(
                    scale: 0.85,
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      setState(() => _attachOpen = !_attachOpen);
                    },
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: AnimatedRotation(
                        turns: _attachOpen ? 0.125 : 0,
                        duration: const Duration(milliseconds: 300).by(context),
                        curve: Curves.easeOutBack,
                        child: Icon(Icons.add_rounded, color: vc.textDim, size: 28),
                      ),
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220).by(context),
                      child: _recording
                          ? _RecordingRow(
                              seconds: _recSeconds,
                              cancel: _cancelArmed,
                              level: _voice?.level,
                            )
                          : TextField(
                              key: const ValueKey('field'),
                              controller: _input,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: 5,
                              textCapitalization: TextCapitalization.sentences,
                              style: TextStyle(color: vc.text, fontSize: 16, height: 1.3),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                  horizontal: 4,
                                ),
                                hintText: _secret ? 'Секретное сообщение…' : 'Сообщение',
                                hintStyle: TextStyle(color: _secret ? acc.mid : vc.textFaint),
                              ),
                            ),
                    ),
                  ),
                  if (!_recording)
                    Pressable(
                      scale: 0.85,
                      onTap: () {
                        setState(() => _secret = !_secret);
                        if (_secret) {
                          showVeilToast(
                            context,
                            'Секретный режим: сообщение будет размыто, пока друг его не коснётся',
                            icon: Icons.visibility_off_rounded,
                          );
                        }
                      },
                      child: SizedBox(
                        width: 40,
                        height: 44,
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250).by(context),
                          transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                          child: _secret
                              ? const GradientIcon(
                                  Icons.visibility_off_rounded,
                                  key: ValueKey('on'),
                                  size: 22,
                                )
                              : Icon(
                                  Icons.visibility_outlined,
                                  key: const ValueKey('off'),
                                  color: vc.textFaint,
                                  size: 22,
                                ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 2),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _input,
                    builder: (_, v, _) => _SendMicButton(
                      hasText: v.text.trim().isNotEmpty,
                      recording: _recording || _noteOpening,
                      note: _noteMode,
                      onSend: _send,
                      onSendMenu: _editing == null ? _sendMenu : null,
                      onToggleMode: _toggleNoteMode,
                      onRecordStart: () {
                        _holding = true;
                        _startRecording();
                      },
                      onRecordEnd: () {
                        _holding = false;
                        _stopRecording();
                      },
                      onRecordDrag: _dragRecording,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────── Верхняя панель ─────────────────────────────

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.contact,
    required this.typing,
    required this.onSearch,
    this.search,
    this.pinned,
  });

  final Contact contact;
  final bool typing;
  final VoidCallback onSearch;

  /// Строка поиска (вместо имени), если ищем.
  final Widget? search;

  /// Полоска закреплённого сообщения.
  final Widget? pinned;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final c = contact;
    final top = MediaQuery.paddingOf(context).top;

    final app = context.app;
    final group = c.group;
    final Widget status;
    if (typing) {
      final who = group == null ? null : app.typingBy[c.id];
      status = Row(
        key: const ValueKey('t'),
        mainAxisSize: MainAxisSize.min,
        children: [
          GradientText(
            who == null ? 'печатает' : '${app.memberName(c.id, who)} печатает',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 5),
          const TypingDots(size: 4),
        ],
      );
    } else if (group != null) {
      status = Text(
        group.left ? 'ты больше не участник' : membersLabel(group.members.length),
        key: const ValueKey('g'),
        style: TextStyle(color: vc.textDim, fontSize: 13),
      );
    } else if (c.online) {
      status = const Text(
        'в сети',
        key: ValueKey('o'),
        style: TextStyle(color: VeilColors.success, fontSize: 13),
      );
    } else {
      status = Text(
        fmtLastSeen(c.lastSeen),
        key: const ValueKey('l'),
        style: TextStyle(color: vc.textDim, fontSize: 13),
      );
    }

    void openProfile() => Navigator.of(
      context,
    ).push(group != null ? GroupInfoScreen.route(c) : ContactScreen.route(c));

    return Glass(
      blur: 20,
      radius: 0,
      border: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: vc.border)),
        ),
        padding: EdgeInsets.fromLTRB(4, top + 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            search ??
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(Icons.arrow_back_ios_new_rounded, color: vc.text, size: 20),
                    ),
                    Pressable(
                      onTap: openProfile,
                      child: Hero(tag: 'avatar-${c.id}', child: Avatar.contact(c, size: 42)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: openProfile,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: vc.text,
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (c.verified) ...[
                                  const SizedBox(width: 4),
                                  const GradientIcon(Icons.verified_rounded, size: 16),
                                ],
                                if (c.disappearing > 0) ...[
                                  const SizedBox(width: 6),
                                  Icon(Icons.timer_outlined, size: 15, color: vc.textDim),
                                ],
                              ],
                            ),
                            const SizedBox(height: 1),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250).by(context),
                              transitionBuilder: (ch, a) => FadeTransition(
                                opacity: a,
                                child: SlideTransition(
                                  position: Tween(
                                    begin: const Offset(0, 0.4),
                                    end: Offset.zero,
                                  ).animate(a),
                                  child: ch,
                                ),
                              ),
                              layoutBuilder: (cur, prev) =>
                                  Stack(alignment: Alignment.centerLeft, children: [...prev, ?cur]),
                              child: status,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (group == null)
                      IconButton(
                        onPressed: () => showVeilToast(
                          context,
                          'Зашифрованные звонки — в следующей версии',
                          icon: Icons.call_rounded,
                        ),
                        icon: Icon(Icons.call_outlined, color: vc.text),
                      ),
                    IconButton(
                      tooltip: 'Поиск в чате',
                      onPressed: onSearch,
                      icon: Icon(Icons.search_rounded, color: vc.text),
                    ),
                  ],
                ),
            ?pinned,
          ],
        ),
      ),
    );
  }
}

/// Поиск в чате: поле, «3 из 7», вверх/вниз.
class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.input,
    required this.hits,
    required this.hit,
    required this.onChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
  });

  final TextEditingController input;
  final int hits;
  final int hit;
  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: Icon(Icons.close_rounded, color: vc.text),
          ),
          Expanded(
            child: TextField(
              controller: input,
              autofocus: true,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(color: vc.text, fontSize: 16),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: 'Поиск в чате',
                hintStyle: TextStyle(color: vc.textFaint),
              ),
            ),
          ),
          if (input.text.trim().isNotEmpty)
            Text(
              hits == 0 ? 'нет' : '${hit + 1} из $hits',
              style: TextStyle(color: vc.textDim, fontSize: 13),
            ),
          IconButton(
            tooltip: 'Раньше',
            onPressed: hits > 1 ? onNext : null,
            icon: Icon(Icons.keyboard_arrow_up_rounded, color: vc.text),
          ),
          IconButton(
            tooltip: 'Позже',
            onPressed: hits > 1 ? onPrev : null,
            icon: Icon(Icons.keyboard_arrow_down_rounded, color: vc.text),
          ),
        ],
      ),
    );
  }
}

/// Закреплённое сообщение под шапкой чата.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({required this.text, required this.onTap, required this.onClose});

  final String text;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Pressable(
      scale: 0.98,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 32,
              decoration: BoxDecoration(
                gradient: acc.gradient,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Закреплено',
                    style: TextStyle(color: acc.a, fontSize: 12.5, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: vc.textDim, fontSize: 13.5),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Открепить',
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, size: 20, color: vc.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── Фон ─────────────────────────────

class _ChatBackground extends StatelessWidget {
  const _ChatBackground();

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return RepaintBoundary(
      child: CustomPaint(painter: _PatternPainter(vc.bg, vc.text, acc.a, acc.b, vc.dark)),
    );
  }
}

class _PatternPainter extends CustomPainter {
  _PatternPainter(this.bg, this.ink, this.a, this.b, this.dark);

  final Color bg;
  final Color ink;
  final Color a;
  final Color b;
  final bool dark;

  @override
  void paint(Canvas canvas, Size s) {
    canvas.drawRect(Offset.zero & s, Paint()..color = bg);
    for (final (center, color) in [
      (Offset(s.width * 1.1, s.height * 0.15), a),
      (Offset(-s.width * 0.1, s.height * 0.85), b),
    ]) {
      final r = s.width * 0.9;
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: dark ? 0.16 : 0.10),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
    // Мелкие «звёздочки» по диагональной сетке.
    final dot = Paint()..color = ink.withValues(alpha: dark ? 0.05 : 0.06);
    const step = 26.0;
    for (var y = 0.0; y < s.height; y += step) {
      final shift = ((y / step).floor().isEven) ? 0.0 : step / 2;
      for (var x = shift; x < s.width; x += step) {
        canvas.drawCircle(Offset(x, y), 1.1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_PatternPainter old) =>
      old.bg != bg || old.a != a || old.b != b || old.ink != ink;
}

// ───────────────────────────── Служебные элементы ленты ─────────────────────────────

class _DateChip extends StatelessWidget {
  const _DateChip({required this.time});
  final DateTime time;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Glass(
          radius: 12,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          child: Text(
            fmtDay(time),
            style: TextStyle(color: vc.textDim, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

class _EncryptionBanner extends StatelessWidget {
  const _EncryptionBanner({required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
      child: Pressable(
        onTap: () => Navigator.of(
          context,
        ).push(contact.isGroup ? GroupInfoScreen.route(contact) : ContactScreen.route(contact)),
        child: Glass(
          radius: 18,
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              const GradientIcon(Icons.lock_rounded, size: 22),
              const SizedBox(height: 8),
              Text(
                contact.isGroup
                    ? 'Сообщения группы шифруются для каждого участника отдельно и хранятся '
                          'только на ваших телефонах. Нажми, чтобы увидеть участников.'
                    : 'Сообщения защищены сквозным шифрованием и хранятся только на ваших с ${contact.name} телефонах. Нажми, чтобы сверить код безопасности.',
                textAlign: TextAlign.center,
                style: TextStyle(color: vc.textDim, fontSize: 12.5, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Align(
      alignment: Alignment.centerLeft,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 380).by(context),
        curve: Curves.easeOutBack,
        builder: (_, t, c) => Transform.scale(
          scale: t,
          alignment: Alignment.bottomLeft,
          child: Opacity(opacity: t.clamp(0, 1), child: c),
        ),
        child: Container(
          margin: const EdgeInsets.only(top: 6, bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: vc.bubbleIn,
            border: Border.all(color: vc.border),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomRight: Radius.circular(20),
              bottomLeft: Radius.circular(6),
            ),
          ),
          child: TypingDots(color: vc.textDim, size: 7),
        ),
      ),
    );
  }
}

// ───────────────────────────── Сообщение ─────────────────────────────

class _MessageTile extends StatefulWidget {
  const _MessageTile({
    super.key,
    required this.m,
    required this.contact,
    required this.first,
    required this.last,
    required this.animate,
    required this.onAnimated,
    required this.onReply,
    required this.onAction,
    this.highlight = false,
  });

  final Message m;
  final Contact contact;
  final bool first;
  final bool last;
  final bool animate;
  final VoidCallback onAnimated;
  final VoidCallback onReply;

  /// Действие из меню сообщения (edit, forward, pin, star, deleteAll, jumpReply).
  final ValueChanged<String> onAction;

  /// Подсветить (нашли поиском / перешли из ответа).
  final bool highlight;

  @override
  State<_MessageTile> createState() => _MessageTileState();
}

class _MessageTileState extends State<_MessageTile> with TickerProviderStateMixin {
  static const _maxDrag = 80.0;
  static const _trigger = 56.0;

  late final _drag = AnimationController(vsync: this, upperBound: _maxDrag);
  final _bubbleKey = GlobalKey();
  int _burst = 0;
  bool _armed = false;

  @override
  void dispose() {
    _drag.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails d) {
    // Сопротивление ближе к краю — «резиновое» ощущение.
    final resist = 1 - (_drag.value / _maxDrag) * 0.6;
    _drag.value = (_drag.value + d.delta.dx * resist).clamp(0, _maxDrag);
    final armed = _drag.value >= _trigger;
    if (armed != _armed) {
      _armed = armed;
      if (armed) context.appRead.tick(HapticKind.selection);
    }
  }

  void _onDragEnd([DragEndDetails? _]) {
    if (_armed) widget.onReply();
    _armed = false;
    _drag.animateTo(0, duration: const Duration(milliseconds: 380), curve: Curves.easeOutBack);
  }

  void _toggleSecret() {
    final app = context.appRead;
    app.tick(HapticKind.light);
    app.reveal(widget.m, !widget.m.revealed);
  }

  void _doubleTap() {
    final app = context.appRead;
    app.tick(HapticKind.medium);
    if (widget.m.reaction != '❤️') app.react(widget.contact.id, widget.m, '❤️');
    setState(() => _burst++);
  }

  void _openMenu() {
    final box = _bubbleKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'menu',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, _, _) => _MessageMenu(
        m: widget.m,
        contact: widget.contact,
        rect: rect,
        onReply: widget.onReply,
        onAction: widget.onAction,
      ),
      transitionBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final mine = m.mine;
    final vc = context.vc;
    final spoiler = m.kind == MsgKind.text && Fmt.hasSpoiler(m.text);

    Widget tile = Padding(
      padding: EdgeInsets.only(top: widget.first ? 8 : 2, bottom: m.reaction != null ? 14 : 0),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: GestureDetector(
            // Секретное: касание открывает/скрывает. Двойной тап для «❤️» тут
            // отключён — иначе одиночное касание ждёт, не будет ли второго, и
            // срабатывает через раз.
            onTap: m.secret || spoiler ? _toggleSecret : null,
            // У вложений, опросов и голосовых свои касания — без задержки.
            onDoubleTap: m.secret || spoiler || m.kind != MsgKind.text ? null : _doubleTap,
            onLongPress: () {
              context.appRead.tick(HapticKind.medium);
              _openMenu();
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                KeyedSubtree(
                  key: _bubbleKey,
                  child: BubbleBody(
                    m: m,
                    contact: widget.contact,
                    tail: widget.last,
                    showName: widget.first,
                    onQuoteTap: () => widget.onAction('jumpReply'),
                  ),
                ),
                if (m.reaction != null)
                  Positioned(bottom: -16, left: 12, child: _ReactionChip(emoji: m.reaction!)),
                if (_burst > 0)
                  Positioned.fill(
                    child: IgnorePointer(child: _HeartBurst(key: ValueKey(_burst))),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    // Свайп вправо — ответить.
    tile = GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: _onDragEnd,
      onHorizontalDragCancel: _onDragEnd,
      child: AnimatedBuilder(
        animation: _drag,
        builder: (_, child) {
          final p = (_drag.value / _trigger).clamp(0.0, 1.0);
          return Stack(
            alignment: Alignment.centerLeft,
            children: [
              Positioned(
                left: 4,
                child: Opacity(
                  opacity: p,
                  child: Transform.scale(
                    scale: 0.5 + 0.5 * p,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _drag.value >= _trigger ? context.accent.a : vc.elevated,
                      ),
                      child: Icon(
                        Icons.reply_rounded,
                        size: 18,
                        color: _drag.value >= _trigger ? context.accent.onAccent : vc.textDim,
                      ),
                    ),
                  ),
                ),
              ),
              Transform.translate(offset: Offset(_drag.value, 0), child: child),
            ],
          );
        },
        child: tile,
      ),
    );

    // Подсветка найденного сообщения.
    tile = AnimatedContainer(
      duration: const Duration(milliseconds: 300).by(context),
      decoration: BoxDecoration(
        color: widget.highlight ? context.accent.a.withValues(alpha: 0.18) : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
      ),
      child: tile,
    );

    if (!widget.animate) return tile;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420).by(context),
      curve: Curves.easeOutCubic,
      onEnd: widget.onAnimated,
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 28),
          child: Transform.scale(
            scale: 0.88 + 0.12 * t,
            alignment: mine ? Alignment.bottomRight : Alignment.bottomLeft,
            child: child,
          ),
        ),
      ),
      child: tile,
    );
  }
}

/// Сам «пузырь» сообщения. Используется и в ленте, и в контекстном меню.
class BubbleBody extends StatelessWidget {
  const BubbleBody({
    super.key,
    required this.m,
    required this.contact,
    this.tail = true,
    this.showName = false,
    this.onQuoteTap,
  });

  final Message m;
  final Contact contact;
  final bool tail;

  /// В группе — имя автора над первым сообщением подряд.
  final bool showName;

  /// Касание цитаты — перейти к исходному сообщению.
  final VoidCallback? onQuoteTap;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final mine = m.mine;
    final fg = mine ? acc.onAccent : vc.text;
    final metaColor = mine ? acc.onAccent.withValues(alpha: 0.75) : vc.textFaint;

    final meta = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.secret) ...[
          Icon(Icons.visibility_off_rounded, size: 12, color: metaColor),
          const SizedBox(width: 3),
        ],
        if (m.edited)
          Text(
            'изм. ',
            style: TextStyle(color: metaColor, fontSize: 11, fontStyle: FontStyle.italic),
          ),
        Text(fmtTime(m.time), style: TextStyle(color: metaColor, fontSize: 11)),
        if (mine) ...[
          const SizedBox(width: 3),
          StatusTicks(status: m.status, color: metaColor, size: 15),
        ],
      ],
    );

    // Только эмодзи — крупно и без пузыря.
    if (m.kind == MsgKind.text && !m.secret && m.replyTo == null && isEmojiOnly(m.text)) {
      return Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _Wobble(child: Text(m.text, style: const TextStyle(fontSize: 52, height: 1.1))),
          Glass(
            radius: 10,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: vc.textDim),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(fmtTime(m.time), style: TextStyle(color: vc.textDim, fontSize: 11)),
                  if (mine) ...[const SizedBox(width: 3), StatusTicks(status: m.status, size: 14)],
                ],
              ),
            ),
          ),
        ],
      );
    }

    // В группе — имя автора (цветом его аватарки).
    final from = m.from;
    final Widget? author = showName && !mine && from != null && contact.isGroup
        ? Text(
            app.memberName(contact.id, from),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: (contact.group!.member(from)?.colors ?? acc.gradient.colors).first,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          )
        : null;

    // Видеосообщение — «квадратик» без пузыря.
    if (m.kind == MsgKind.note && m.att != null) {
      return Column(
        crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?author,
          if (m.replyTo != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Glass(
                radius: 14,
                padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                child: SizedBox(
                  width: 200,
                  child: _QuotedReply(m: m.replyTo!, contact: contact, mine: false),
                ),
              ),
            ),
          NoteBubble(
            m: m,
            chatId: contact.id,
            meta: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(fmtTime(m.time), style: const TextStyle(color: Colors.white, fontSize: 11)),
                if (mine) ...[
                  const SizedBox(width: 3),
                  StatusTicks(status: m.status, color: Colors.white, size: 15),
                ],
              ],
            ),
          ),
        ],
      );
    }

    const r = Radius.circular(20);
    const small = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: !mine && tail ? small : r,
      bottomRight: mine && tail ? small : r,
    );

    // Фото, видео и карта — от края до края пузыря.
    final edge = m.kind == MsgKind.photo || m.kind == MsgKind.video || m.kind == MsgKind.geo;
    final maxW = MediaQuery.sizeOf(context).width * 0.78;
    final mediaW = min(270.0, maxW) - 6;
    final inner = BorderRadius.only(
      topLeft: const Radius.circular(17),
      topRight: const Radius.circular(17),
      bottomLeft: Radius.circular(!mine && tail ? 4 : 17),
      bottomRight: Radius.circular(mine && tail ? 4 : 17),
    );

    Widget metaOn(Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (m.edited) Text('изм. ', style: TextStyle(color: color, fontSize: 11)),
        Text(fmtTime(m.time), style: TextStyle(color: color, fontSize: 11)),
        if (mine) ...[
          const SizedBox(width: 3),
          StatusTicks(status: m.status, color: color, size: 15),
        ],
      ],
    );

    Widget textBlock(String t) {
      final style = TextStyle(color: fg, fontSize: 16, height: 1.32);
      Widget text = Fmt.has(t)
          ? Text.rich(
              TextSpan(children: Fmt.spans(t, style, reveal: m.revealed)),
              style: style,
            )
          : Text(t, style: style);
      // Размывается только текст — пузырь сохраняет свой естественный размер,
      // а время и галочки всегда видны.
      if (m.secret) text = _SecretText(revealed: m.revealed, fg: fg, child: text);
      return Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          text,
          Padding(padding: const EdgeInsets.only(top: 4), child: meta),
        ],
      );
    }

    // Подпись к вложению: текст слева, время с галочками — внизу справа.
    Widget captionBlock(String t) => Stack(
      children: [
        Text.rich(
          TextSpan(
            children: [
              ...Fmt.spans(t, TextStyle(color: fg, fontSize: 16), reveal: true),
              WidgetSpan(child: SizedBox(width: mine ? 66 : 44, height: 12)),
            ],
          ),
          style: TextStyle(color: fg, fontSize: 16, height: 1.32),
        ),
        Positioned(right: 0, bottom: 0, child: meta),
      ],
    );

    final hasCaption = m.text.trim().isNotEmpty;
    Widget content;
    switch (m.kind) {
      case MsgKind.voice:
        content = m.att == null
            ? _VoiceContent(m: m, fg: fg, meta: meta)
            : VoiceMessage(m: m, chatId: contact.id, fg: fg, meta: meta);
      case MsgKind.photo || MsgKind.video when m.att != null:
        final media = VisualMedia(
          m: m,
          chatId: contact.id,
          width: mediaW,
          radius: hasCaption || m.replyTo != null
              ? (hasCaption
                    ? const BorderRadius.vertical(
                        top: Radius.circular(17),
                        bottom: Radius.circular(6),
                      )
                    : BorderRadius.vertical(
                        top: const Radius.circular(6),
                        bottom: inner.bottomLeft,
                      ))
              : inner,
          overlayMeta: hasCaption ? null : metaOn(Colors.white),
        );
        content = hasCaption
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  media,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 8, 4),
                    child: SizedBox(width: mediaW - 18, child: captionBlock(m.text)),
                  ),
                ],
              )
            : media;
      case MsgKind.file when m.att != null:
        content = FileContent(m: m, chatId: contact.id, fg: fg, meta: meta);
        if (hasCaption) {
          content = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              content,
              const SizedBox(height: 6),
              SizedBox(width: 250, child: captionBlock(m.text)),
            ],
          );
        }
      case MsgKind.geo when m.geo != null:
        content = GeoContent(m: m, width: mediaW, radius: inner, fg: fg, meta: meta);
      case MsgKind.poll when m.poll != null:
        content = PollContent(m: m, chatId: contact.id, fg: fg, meta: meta);
      default:
        content = textBlock(m.text);
    }

    return Container(
      padding: edge ? const EdgeInsets.all(3) : const EdgeInsets.fromLTRB(14, 9, 12, 8),
      decoration: BoxDecoration(
        gradient: mine
            ? LinearGradient(
                colors: [acc.a, acc.b],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: mine ? null : vc.bubbleIn,
        borderRadius: radius,
        border: mine ? null : Border.all(color: vc.border),
        // Лёгкая тень только у своих пузырей (тени дороги при прокрутке).
        boxShadow: mine
            ? [
                BoxShadow(
                  color: acc.mid.withValues(alpha: 0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (author != null)
            Padding(
              padding: edge
                  ? const EdgeInsets.fromLTRB(8, 5, 8, 4)
                  : const EdgeInsets.only(bottom: 2),
              child: author,
            ),
          if (m.fwd != null)
            Padding(
              padding: edge
                  ? const EdgeInsets.fromLTRB(8, 5, 8, 4)
                  : const EdgeInsets.only(bottom: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.forward_rounded, size: 14, color: metaColor),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Переслано от ${m.fwd}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: metaColor,
                        fontSize: 12.5,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (m.replyTo != null)
            Padding(
              padding: edge ? const EdgeInsets.fromLTRB(8, 6, 8, 0) : EdgeInsets.zero,
              child: SizedBox(
                width: edge ? mediaW - 16 : null,
                child: GestureDetector(
                  onTap: onQuoteTap,
                  child: _QuotedReply(m: m.replyTo!, contact: contact, mine: mine),
                ),
              ),
            ),
          content,
        ],
      ),
    );
  }
}

/// Лёгкое покачивание крупных эмодзи при появлении.
class _Wobble extends StatelessWidget {
  const _Wobble({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900).by(context),
      builder: (_, t, c) => Transform.rotate(
        angle: sin(t * pi * 4) * 0.18 * (1 - t),
        child: Transform.scale(scale: 0.6 + 0.4 * Curves.elasticOut.transform(t), child: c),
      ),
      child: child,
    );
  }
}

class _QuotedReply extends StatelessWidget {
  const _QuotedReply({required this.m, required this.contact, required this.mine});

  final Message m;
  final Contact contact;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final fg = mine ? acc.onAccent : vc.text;
    final name = m.mine
        ? 'Вы'
        : m.from != null
        ? app.memberName(contact.id, m.from!)
        : contact.name;
    final text = Fmt.plain(m.preview);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: BoxDecoration(
        color: mine ? Colors.white.withValues(alpha: 0.16) : acc.a.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border(left: BorderSide(color: mine ? acc.onAccent : acc.a, width: 3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: TextStyle(color: mine ? fg : acc.a, fontWeight: FontWeight.w700, fontSize: 13),
          ),
          Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: fg.withValues(alpha: 0.85), fontSize: 13.5),
          ),
        ],
      ),
    );
  }
}

/// Текст секретного сообщения: размыт, пока его не открыли. Открыть/скрыть —
/// касанием по пузырю (см. [_MessageTile]).
class _SecretText extends StatelessWidget {
  const _SecretText({required this.revealed, required this.fg, required this.child});

  final bool revealed;
  final Color fg;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: revealed ? 0 : 1),
      duration: const Duration(milliseconds: 380).by(context),
      curve: Curves.easeOutCubic,
      builder: (_, t, child) => Stack(
        alignment: Alignment.center,
        children: [
          if (t > 0.01)
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 7 * t, sigmaY: 7 * t, tileMode: TileMode.decal),
              child: child,
            )
          else
            child!,
          if (t > 0.05)
            Opacity(
              opacity: t,
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.visibility_rounded, size: 16, color: fg),
              ),
            ),
        ],
      ),
      child: child,
    );
  }
}

class _VoiceContent extends StatefulWidget {
  const _VoiceContent({required this.m, required this.fg, required this.meta});

  final Message m;
  final Color fg;
  final Widget meta;

  @override
  State<_VoiceContent> createState() => _VoiceContentState();
}

class _VoiceContentState extends State<_VoiceContent> with SingleTickerProviderStateMixin {
  late final AnimationController _play =
      AnimationController(
        vsync: this,
        duration: Duration(seconds: max(1, widget.m.voiceSeconds)),
      )..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          _play.reset();
          setState(() {});
        }
      });
  late final _bars = waveform(widget.m.id, 30);

  @override
  void dispose() {
    _play.dispose();
    super.dispose();
  }

  void _toggle() {
    context.appRead.tick(HapticKind.selection);
    setState(() => _play.isAnimating ? _play.stop() : _play.forward());
  }

  @override
  Widget build(BuildContext context) {
    final fg = widget.fg;
    final mine = widget.m.mine;
    final acc = context.accent;
    final playing = _play.isAnimating;
    return SizedBox(
      width: 230,
      child: Row(
        children: [
          Pressable(
            scale: 0.85,
            haptic: false,
            onTap: _toggle,
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: mine ? Colors.white.withValues(alpha: 0.22) : null,
                gradient: mine ? null : acc.gradient,
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200).by(context),
                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                child: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  key: ValueKey(playing),
                  color: mine ? fg : acc.onAccent,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 28,
                  child: AnimatedBuilder(
                    animation: _play,
                    builder: (_, _) => Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        for (var i = 0; i < _bars.length; i++)
                          Expanded(
                            child: Center(
                              child: Container(
                                width: 3,
                                height: 4 + 22 * _bars[i],
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(2),
                                  color:
                                      (i / _bars.length) <= _play.value &&
                                          (playing || _play.value > 0)
                                      ? (mine ? fg : acc.a)
                                      : fg.withValues(alpha: 0.35),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    AnimatedBuilder(
                      animation: _play,
                      builder: (_, _) => Text(
                        fmtDuration(
                          playing
                              ? (widget.m.voiceSeconds * _play.value).floor()
                              : widget.m.voiceSeconds,
                        ),
                        style: TextStyle(color: fg.withValues(alpha: 0.8), fontSize: 12),
                      ),
                    ),
                    const Spacer(),
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

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({required this.emoji});
  final String emoji;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return TweenAnimationBuilder<double>(
      key: ValueKey(emoji),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500).by(context),
      curve: Curves.elasticOut,
      builder: (_, s, c) => Transform.scale(scale: s, child: c),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: vc.elevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: vc.bg, width: 2),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6)],
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 15)),
      ),
    );
  }
}

/// Сердце, разлетающееся по двойному тапу.
class _HeartBurst extends StatelessWidget {
  const _HeartBurst({super.key});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900).by(context),
      builder: (_, t, _) {
        final pop = Curves.elasticOut.transform((t * 1.6).clamp(0, 1));
        final fade = t < 0.6 ? 1.0 : 1 - (t - 0.6) / 0.4;
        return Stack(
          alignment: Alignment.center,
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < 8; i++)
              Transform.translate(
                offset: Offset.fromDirection(i * pi / 4, 20 + 50 * Curves.easeOut.transform(t)),
                child: Opacity(
                  opacity: (1 - t).clamp(0, 1),
                  child: Text(i.isEven ? '❤️' : '✨', style: TextStyle(fontSize: 10 + 6 * (1 - t))),
                ),
              ),
            Opacity(
              opacity: fade.clamp(0, 1),
              child: Transform.scale(
                scale: pop * 1.2,
                child: const Text('❤️', style: TextStyle(fontSize: 44)),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────────── Контекстное меню ─────────────────────────────

class _MessageMenu extends StatelessWidget {
  const _MessageMenu({
    required this.m,
    required this.contact,
    required this.rect,
    required this.onReply,
    required this.onAction,
  });

  final Message m;
  final Contact contact;
  final Rect rect;
  final VoidCallback onReply;
  final ValueChanged<String> onAction;

  static const _barH = 56.0;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);
    final menuH = _ActionsMenu.actionsFor(app, m, contact).length * 48.0 + 12;

    // Сдвигаем пузырь, чтобы меню целиком поместилось на экране.
    final bubbleH = min(rect.height, size.height * 0.4);
    final wantTop = rect.top - _barH - 10;
    final wantBottom = rect.top + bubbleH + 10 + menuH;
    var shift = 0.0;
    if (wantBottom > size.height - pad.bottom - 12) {
      shift = wantBottom - (size.height - pad.bottom - 12);
    }
    if (wantTop - shift < pad.top + 8) shift = wantTop - pad.top - 8;
    final top = rect.top - shift;
    final alignRight = m.mine;
    final hPos = alignRight
        ? EdgeInsets.only(right: size.width - rect.right)
        : EdgeInsets.only(left: rect.left);

    void close() => Navigator.of(context).pop();

    return Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: close,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: Container(color: Colors.black.withValues(alpha: vc.dark ? 0.45 : 0.2)),
              ),
            ),
          ),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: rect.top, end: top),
            duration: const Duration(milliseconds: 320).by(context),
            curve: Curves.easeOutCubic,
            builder: (_, y, _) => Positioned(
              top: y - _barH - 10,
              left: 0,
              right: 0,
              child: Column(
                crossAxisAlignment: alignRight ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: hPos,
                    child: _ReactionBar(m: m, chatId: contact.id),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: hPos,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: rect.width, maxHeight: bubbleH),
                      child: IgnorePointer(
                        child: SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: BubbleBody(m: m, contact: contact),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: hPos,
                    child: _ActionsMenu(
                      m: m,
                      contact: contact,
                      onReply: onReply,
                      onAction: onAction,
                      close: close,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReactionBar extends StatelessWidget {
  const _ReactionBar({required this.m, required this.chatId});
  final Message m;
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    final acc = app.accent;
    return Material(
      type: MaterialType.transparency,
      child: Glass(
        radius: 28,
        color: vc.elevated.withValues(alpha: 0.92),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, e) in reactionEmojis.indexed)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: Duration(milliseconds: 380 + i * 50).by(context),
                curve: Interval(i * 0.08, 1, curve: Curves.easeOutBack),
                builder: (_, t, c) => Transform.scale(scale: t, child: c),
                child: Pressable(
                  scale: 0.75,
                  onTap: () {
                    app.tick(HapticKind.light);
                    app.react(chatId, m, e);
                    Navigator.of(context).pop();
                  },
                  child: Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: m.reaction == e ? acc.a.withValues(alpha: 0.25) : Colors.transparent,
                    ),
                    child: Text(e, style: const TextStyle(fontSize: 26)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionsMenu extends StatelessWidget {
  const _ActionsMenu({
    required this.m,
    required this.contact,
    required this.onReply,
    required this.onAction,
    required this.close,
  });

  final Message m;
  final Contact contact;
  final VoidCallback onReply;
  final ValueChanged<String> onAction;
  final VoidCallback close;

  /// Какие действия доступны: (значок, подпись, код, опасное).
  static List<(IconData, String, String, bool)> actionsFor(AppState app, Message m, Contact c) {
    final canWrite = !(c.group?.left ?? false) && !c.blocked;
    final editable =
        m.mine &&
        canWrite &&
        !m.secret &&
        (m.kind == MsgKind.text ||
            (m.att != null && m.text.isNotEmpty && m.kind != MsgKind.note)) &&
        DateTime.now().difference(m.time).inHours < 48;
    return [
      if (canWrite) (Icons.reply_rounded, 'Ответить', 'reply', false),
      if (m.att?.local ?? false)
        (Icons.ios_share_rounded, 'Поделиться', 'share', false)
      else
        (Icons.copy_rounded, 'Копировать', 'copy', false),
      (Icons.forward_rounded, 'Переслать', 'forward', false),
      if (editable) (Icons.edit_rounded, 'Изменить', 'edit', false),
      if (canWrite)
        c.pinnedMsg == m.id
            ? (Icons.push_pin_outlined, 'Открепить', 'pin', false)
            : (Icons.push_pin_rounded, 'Закрепить', 'pin', false),
      app.isStarred(c.id, m)
          ? (Icons.star_rounded, 'Убрать из избранного', 'star', false)
          : (Icons.star_outline_rounded, 'В избранное', 'star', false),
      if (m.mine && canWrite) (Icons.delete_forever_rounded, 'Удалить у всех', 'deleteAll', true),
      (Icons.delete_outline_rounded, 'Удалить у себя', 'delete', true),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;

    void run(String code) {
      close();
      switch (code) {
        case 'reply':
          onReply();
        case 'share':
          shareFile(m.att!.path!, text: m.text.isEmpty ? null : m.text);
        case 'copy':
          final g = m.geo, p = m.poll;
          final text = g != null
              ? '${g.lat}, ${g.lng}'
              : p != null
              ? [p.question, for (final o in p.options) '• $o'].join('\n')
              : m.text;
          Clipboard.setData(ClipboardData(text: text));
          showVeilToast(context, 'Скопировано', icon: Icons.copy_rounded);
        case 'delete':
          app.deleteMessage(contact.id, m);
        default:
          onAction(code);
      }
    }

    Widget action((IconData, String, String, bool) a) {
      final (icon, label, code, danger) = a;
      final color = danger ? VeilColors.danger : vc.text;
      return InkWell(
        onTap: () => run(code),
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(color: color, fontSize: 15, fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(icon, size: 20, color: color),
              ],
            ),
          ),
        ),
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.85, end: 1),
      duration: const Duration(milliseconds: 280).by(context),
      curve: Curves.easeOutBack,
      builder: (_, s, c) => Transform.scale(
        scale: s,
        alignment: m.mine ? Alignment.topRight : Alignment.topLeft,
        child: c,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Glass(
          radius: 18,
          color: vc.elevated.withValues(alpha: 0.94),
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: SizedBox(
            width: 230,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (final a in actionsFor(app, m, contact)) action(a)],
            ),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Поле ввода ─────────────────────────────

class _SendMicButton extends StatelessWidget {
  const _SendMicButton({
    required this.hasText,
    required this.recording,
    required this.note,
    required this.onSend,
    this.onSendMenu,
    required this.onToggleMode,
    required this.onRecordStart,
    required this.onRecordEnd,
    required this.onRecordDrag,
  });

  final bool hasText;
  final bool recording;

  /// Режим видеосообщения (камера) вместо голосового (микрофон).
  final bool note;
  final VoidCallback onSend;

  /// Долгое нажатие на «отправить» — варианты (без звука).
  final VoidCallback? onSendMenu;

  /// Короткое нажатие — переключить микрофон ↔ камеру (как в Telegram).
  final VoidCallback onToggleMode;
  final VoidCallback onRecordStart;
  final VoidCallback onRecordEnd;
  final ValueChanged<double> onRecordDrag;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final vc = context.vc;
    final active = hasText || recording;
    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 250).by(context),
      curve: Curves.easeOutBack,
      width: 44,
      height: 44,
      transform: Matrix4.diagonal3Values(recording ? 1.25 : 1, recording ? 1.25 : 1, 1),
      transformAlignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: active ? acc.gradient : null,
        color: active ? null : Colors.transparent,
        boxShadow: active
            ? [BoxShadow(color: acc.mid.withValues(alpha: 0.5), blurRadius: 14)]
            : null,
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 260).by(context),
        transitionBuilder: (c, a) => RotationTransition(
          turns: Tween(begin: -0.25, end: 0.0).animate(a),
          child: ScaleTransition(scale: a, child: c),
        ),
        child: hasText
            ? Icon(Icons.arrow_upward_rounded, key: const ValueKey('send'), color: acc.onAccent)
            : Icon(
                note ? Icons.videocam_rounded : Icons.mic_rounded,
                key: ValueKey(note ? 'note' : 'mic'),
                color: recording ? acc.onAccent : vc.textDim,
              ),
      ),
    );

    if (hasText) {
      return Pressable(
        scale: 0.85,
        onTap: onSend,
        onLongPress: onSendMenu,
        haptic: false,
        child: button,
      );
    }
    // Отпускание пальца ловим и «сырыми» событиями: если жест прервался
    // (например, всплыл системный запрос), запись всё равно остановится.
    return Listener(
      onPointerUp: (_) {
        if (recording) onRecordEnd();
      },
      onPointerCancel: (_) {
        if (recording) onRecordEnd();
      },
      child: GestureDetector(
        onLongPressStart: (_) => onRecordStart(),
        onLongPressMoveUpdate: (d) => onRecordDrag(d.offsetFromOrigin.dx),
        onLongPressEnd: (_) => onRecordEnd(),
        onTap: recording ? onRecordEnd : onToggleMode,
        child: button,
      ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({required this.seconds, this.cancel = false, this.level});
  final int seconds;
  final bool cancel;

  /// Громкость 0..1 — точка «дышит» в такт голосу.
  final ValueListenable<double>? level;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final lvl = level;
    return SizedBox(
      key: const ValueKey('rec'),
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 4),
          if (lvl == null)
            const _PulsingDot()
          else
            ValueListenableBuilder<double>(
              valueListenable: lvl,
              builder: (_, v, child) => AnimatedScale(
                scale: 1 + v * 0.9,
                duration: const Duration(milliseconds: 100),
                child: child,
              ),
              child: const _PulsingDot(),
            ),
          const SizedBox(width: 10),
          Text(
            fmtDuration(seconds),
            style: TextStyle(
              color: vc.text,
              fontSize: 16,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180).by(context),
              child: Text(
                cancel ? 'отпусти — запись отменится' : 'отпусти — отправится · ← отмена',
                key: ValueKey(cancel),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: cancel ? VeilColors.danger : vc.textFaint, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.3, end: 1.0).animate(_c),
    child: Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(color: VeilColors.danger, shape: BoxShape.circle),
    ),
  );
}

class _ReplyPreview extends StatelessWidget {
  const _ReplyPreview({
    required this.m,
    required this.contact,
    required this.onClose,
    this.editing = false,
  });

  final Message m;
  final Contact contact;
  final VoidCallback onClose;

  /// Это не ответ, а редактирование своего сообщения.
  final bool editing;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final text = Fmt.plain(m.preview);
    final title = editing
        ? 'Редактирование'
        : m.mine
        ? 'Ответ себе'
        : 'Ответ: ${m.from != null ? app.memberName(contact.id, m.from!) : contact.name}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 18,
        padding: const EdgeInsets.fromLTRB(14, 8, 4, 8),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 36,
              decoration: BoxDecoration(
                gradient: acc.gradient,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            GradientIcon(editing ? Icons.edit_rounded : Icons.reply_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(color: acc.a, fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: vc.textDim, fontSize: 13.5),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onClose,
              icon: Icon(Icons.close_rounded, color: vc.textDim),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachMenu extends StatelessWidget {
  const _AttachMenu({required this.onPick});
  final ValueChanged<String> onPick;

  static const _items = [
    (Icons.photo_rounded, 'Фото', 'photo', [Color(0xFF7C5CFF), Color(0xFF00C2FF)]),
    (Icons.photo_camera_rounded, 'Камера', 'camera', [Color(0xFFFF4F8B), Color(0xFFFFA45C)]),
    (Icons.videocam_rounded, 'Видео', 'video', [Color(0xFFFF5F6D), Color(0xFFB06AB3)]),
    (Icons.insert_drive_file_rounded, 'Файл', 'file', [Color(0xFF00C896), Color(0xFF0098E6)]),
    (Icons.location_on_rounded, 'Место', 'geo', [Color(0xFFFFC145), Color(0xFFFF7A45)]),
    (Icons.poll_rounded, 'Опрос', 'poll', [Color(0xFFB06AB3), Color(0xFF4568DC)]),
  ];

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    Widget item(int i) {
      final (icon, label, key, colors) = _items[i];
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 350 + i * 50).by(context),
        curve: Interval(i * 0.08, 1, curve: Curves.easeOutBack),
        builder: (_, t, c) => Transform.translate(
          offset: Offset(0, (1 - t) * 20),
          child: Opacity(opacity: t.clamp(0, 1), child: c),
        ),
        child: Pressable(
          onTap: () => onPick(key),
          child: SizedBox(
            width: 72,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: colors),
                    boxShadow: [
                      BoxShadow(color: colors.first.withValues(alpha: 0.4), blurRadius: 12),
                    ],
                  ),
                  child: Icon(icon, color: Colors.white),
                ),
                const SizedBox(height: 6),
                Text(label, style: TextStyle(color: vc.textDim, fontSize: 12)),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [for (var i = 0; i < 3; i++) item(i)],
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [for (var i = 3; i < 6; i++) item(i)],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScrollDownButton extends StatelessWidget {
  const _ScrollDownButton({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    return Pressable(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Glass(
            radius: 22,
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(Icons.keyboard_arrow_down_rounded, color: context.vc.text, size: 28),
            ),
          ),
          if (count > 0)
            Positioned(
              top: -6,
              right: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  gradient: acc.gradient,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(color: acc.onAccent, fontSize: 11, fontWeight: FontWeight.w800),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BlockedBar extends StatelessWidget {
  const _BlockedBar({required this.onUnblock});
  final VoidCallback onUnblock;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.paddingOf(context).bottom + 10),
      child: Glass(
        radius: 22,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.block_rounded, color: VeilColors.danger, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text('Контакт заблокирован', style: TextStyle(color: context.vc.textDim)),
            ),
            TextButton(onPressed: onUnblock, child: const Text('Разблокировать')),
          ],
        ),
      ),
    );
  }
}

/// Незнакомец написал первым: принять или заблокировать.
class _RequestBar extends StatelessWidget {
  const _RequestBar({required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Glass(
        radius: 22,
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              contact.isGroup
                  ? 'Тебя позвали в группу «${contact.name}». '
                        'Если не знаешь этих людей — просто удали её.'
                  : '${contact.name} добавил(а) тебя по твоему коду. '
                        'Если не знаешь этого человека — заблокируй.',
              style: TextStyle(color: vc.textDim, fontSize: 13.5, height: 1.35),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (contact.isGroup)
                  TextButton(
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      await app.deleteContact(contact.id);
                      nav.maybePop();
                    },
                    child: const Text('Удалить', style: TextStyle(color: VeilColors.danger)),
                  )
                else
                  TextButton(
                    onPressed: () => app.toggleBlocked(contact.id),
                    child: const Text('Заблокировать', style: TextStyle(color: VeilColors.danger)),
                  ),
                TextButton(
                  onPressed: () => app.acceptRequest(contact.id),
                  child: const Text('Принять'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Событие группы по центру ленты: «Алиса создал(а) группу», «Боб вышел(а)».
class _EventChip extends StatelessWidget {
  const _EventChip({required this.m, required this.chatId});
  final Message m;
  final String chatId;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Glass(
          radius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            app.eventText(chatId, m),
            textAlign: TextAlign.center,
            style: TextStyle(color: vc.textDim, fontSize: 12.5),
          ),
        ),
      ),
    );
  }
}

/// Вышли из группы (или удалили) — писать нельзя.
class _LeftGroupBar extends StatelessWidget {
  const _LeftGroupBar();

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(12, 0, 12, MediaQuery.paddingOf(context).bottom + 10),
    child: Glass(
      radius: 22,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(Icons.group_off_rounded, color: context.vc.textDim, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Ты больше не участник этой группы',
              style: TextStyle(color: context.vc.textDim),
            ),
          ),
        ],
      ),
    ),
  );
}
