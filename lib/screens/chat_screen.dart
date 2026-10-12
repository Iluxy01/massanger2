import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../state/mock_data.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'contact_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.contact});

  final Contact contact;

  static Route<void> route(Contact c) => MaterialPageRoute(builder: (_) => ChatScreen(contact: c));

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
  bool _secret = false;
  bool _attachOpen = false;
  bool _showDown = false;
  int _seen = 0;

  bool _recording = false;
  int _recSeconds = 0;
  Timer? _recTimer;

  Contact get c => widget.contact;

  @override
  void initState() {
    super.initState();
    _app = context.appRead;
    _input.text = _app.drafts[c.id] ?? '';
    var last = _input.text;
    _input.addListener(() {
      if (_input.text.isNotEmpty && _input.text != last) _app.userTyping(c.id);
      last = _input.text;
      setState(() {});
    });
    _animated = _app.messagesOf(c.id).map((m) => m.id).toSet();
    _seen = _app.messagesOf(c.id).length;
    _app.openChat = c.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _app.markRead(c.id));
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
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _toBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _app.tick(HapticKind.light);
    _app.send(c.id, text, replyTo: _replyTo, secret: _secret);
    _input.clear();
    setState(() {
      _replyTo = null;
      _secret = false;
    });
    _toBottom();
  }

  void _setReply(Message m) {
    _app.tick(HapticKind.medium);
    setState(() => _replyTo = m);
    _focus.requestFocus();
  }

  void _startRecording() {
    if (!_app.demo) {
      showVeilToast(context, 'Голосовые сообщения — в следующей версии', icon: Icons.mic_rounded);
      return;
    }
    _app.tick(HapticKind.medium);
    setState(() {
      _recording = true;
      _recSeconds = 0;
      _attachOpen = false;
    });
    _recTimer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _recSeconds++));
  }

  void _stopRecording({bool cancel = false}) {
    if (!_recording) return;
    _recTimer?.cancel();
    final secs = _recSeconds;
    setState(() => _recording = false);
    if (cancel || secs < 1) {
      showVeilToast(context, 'Удерживай кнопку, чтобы записать голосовое', icon: Icons.mic_rounded);
      return;
    }
    _app.tick(HapticKind.light);
    _app.send(c.id, '', kind: MsgKind.voice, voiceSeconds: secs, replyTo: _replyTo);
    setState(() => _replyTo = null);
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
    final items = _buildItems(msgs, typing);
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
                child: GestureDetector(
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
                      _MsgItem(:final m, :final first, :final last) => _MessageTile(
                        key: ValueKey(m.id),
                        m: m,
                        contact: c,
                        first: first,
                        last: last,
                        animate: !_animated.contains(m.id),
                        onAnimated: () => _animated.add(m.id),
                        onReply: () => _setReply(m),
                      ),
                    },
                  ),
                ),
              ),
              if (c.request && !c.blocked) _RequestBar(contact: c),
              if (c.blocked)
                _BlockedBar(onUnblock: () => app.toggleBlocked(c.id))
              else
                _composer(context),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _TopBar(contact: c, typing: typing),
          ),
          Positioned(
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + (_replyTo != null ? 150 : 96),
            child: AnimatedScale(
              scale: _showDown ? 1 : 0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: _ScrollDownButton(count: newBelow, onTap: _toBottom),
            ),
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final hasText = _input.text.trim().isNotEmpty;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(10, 0, 10, bottom + 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: _attachOpen
                ? _AttachMenu(
                    onPick: (label) {
                      setState(() => _attachOpen = false);
                      showVeilToast(
                        context,
                        '$label — в следующей версии',
                        icon: Icons.construction_rounded,
                      );
                    },
                  )
                : const SizedBox(width: double.infinity),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
            child: _replyTo == null
                ? const SizedBox(width: double.infinity)
                : _ReplyPreview(
                    m: _replyTo!,
                    contact: c,
                    onClose: () => setState(() => _replyTo = null),
                  ),
          ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
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
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeOutBack,
                        child: Icon(Icons.add_rounded, color: vc.textDim, size: 28),
                      ),
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: _recording
                          ? _RecordingRow(seconds: _recSeconds)
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
                          duration: const Duration(milliseconds: 250),
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
                  _SendMicButton(
                    hasText: hasText,
                    recording: _recording,
                    onSend: _send,
                    onRecordStart: _startRecording,
                    onRecordEnd: () => _stopRecording(),
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
  const _TopBar({required this.contact, required this.typing});

  final Contact contact;
  final bool typing;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final c = contact;
    final top = MediaQuery.paddingOf(context).top;

    final Widget status;
    if (typing) {
      status = Row(
        key: const ValueKey('t'),
        mainAxisSize: MainAxisSize.min,
        children: [
          GradientText(
            'печатает',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 5),
          const TypingDots(size: 4),
        ],
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

    void openProfile() => Navigator.of(context).push(ContactScreen.route(c));

    return Glass(
      radius: 0,
      border: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: vc.border)),
        ),
        padding: EdgeInsets.fromLTRB(4, top + 4, 8, 8),
        child: Row(
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
                      duration: const Duration(milliseconds: 250),
                      transitionBuilder: (ch, a) => FadeTransition(
                        opacity: a,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(a),
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
            IconButton(
              onPressed: () => showVeilToast(
                context,
                'Зашифрованные звонки — в следующей версии',
                icon: Icons.call_rounded,
              ),
              icon: Icon(Icons.call_outlined, color: vc.text),
            ),
            IconButton(
              onPressed: () => showVeilToast(
                context,
                'Видеозвонки — в следующей версии',
                icon: Icons.videocam_rounded,
              ),
              icon: Icon(Icons.videocam_outlined, color: vc.text),
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
          blur: 10,
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
        onTap: () => Navigator.of(context).push(ContactScreen.route(contact)),
        child: Glass(
          radius: 18,
          blur: 10,
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              const GradientIcon(Icons.lock_rounded, size: 22),
              const SizedBox(height: 8),
              Text(
                'Сообщения защищены сквозным шифрованием и хранятся только на ваших с ${contact.name} телефонах. Нажми, чтобы сверить код безопасности.',
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
        duration: const Duration(milliseconds: 380),
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
  });

  final Message m;
  final Contact contact;
  final bool first;
  final bool last;
  final bool animate;
  final VoidCallback onAnimated;
  final VoidCallback onReply;

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
      pageBuilder: (_, _, _) =>
          _MessageMenu(m: widget.m, contact: widget.contact, rect: rect, onReply: widget.onReply),
      transitionBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.m;
    final mine = m.mine;
    final vc = context.vc;

    Widget tile = Padding(
      padding: EdgeInsets.only(top: widget.first ? 8 : 2, bottom: m.reaction != null ? 14 : 0),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          child: GestureDetector(
            onDoubleTap: _doubleTap,
            onLongPress: () {
              context.appRead.tick(HapticKind.medium);
              _openMenu();
            },
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                KeyedSubtree(
                  key: _bubbleKey,
                  child: BubbleBody(m: m, contact: widget.contact, tail: widget.last),
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

    if (!widget.animate) return tile;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
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
  const BubbleBody({super.key, required this.m, required this.contact, this.tail = true});

  final Message m;
  final Contact contact;
  final bool tail;

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
            blur: 8,
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

    const r = Radius.circular(20);
    const small = Radius.circular(6);
    final radius = BorderRadius.only(
      topLeft: r,
      topRight: r,
      bottomLeft: !mine && tail ? small : r,
      bottomRight: mine && tail ? small : r,
    );

    Widget content;
    if (m.kind == MsgKind.voice) {
      content = _VoiceContent(m: m, fg: fg, meta: meta);
    } else {
      content = Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          Text(m.text, style: TextStyle(color: fg, fontSize: 16, height: 1.32)),
          Padding(padding: const EdgeInsets.only(top: 4), child: meta),
        ],
      );
      if (m.secret) content = _SecretContent(m: m, fg: fg, child: content);
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 9, 12, 8),
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
        boxShadow: [
          BoxShadow(
            color: mine ? acc.mid.withValues(alpha: 0.25) : Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (m.replyTo != null) _QuotedReply(m: m.replyTo!, contact: contact, mine: mine),
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
      duration: const Duration(milliseconds: 900),
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
    final vc = context.vc;
    final acc = context.accent;
    final fg = mine ? acc.onAccent : vc.text;
    final name = m.mine ? 'Вы' : contact.name;
    final text = m.kind == MsgKind.voice
        ? '🎤 Голосовое'
        : m.secret
        ? '🔒 Секретное сообщение'
        : m.text;
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

/// Секретное сообщение: размыто, пока не коснёшься; входящее снова прячется через 8 секунд.
class _SecretContent extends StatefulWidget {
  const _SecretContent({required this.m, required this.fg, required this.child});

  final Message m;
  final Color fg;
  final Widget child;

  @override
  State<_SecretContent> createState() => _SecretContentState();
}

class _SecretContentState extends State<_SecretContent> {
  Timer? _hide;

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  void _toggle() {
    final app = context.appRead;
    final show = !widget.m.revealed;
    app.tick(HapticKind.light);
    app.reveal(widget.m, show);
    _hide?.cancel();
    if (show && !widget.m.mine) {
      _hide = Timer(const Duration(seconds: 8), () {
        if (mounted) app.reveal(widget.m, false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final revealed = widget.m.revealed;
    return GestureDetector(
      onTap: _toggle,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: revealed ? 0 : 7),
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
        builder: (_, sigma, child) => Stack(
          alignment: Alignment.center,
          children: [
            ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal),
              child: child,
            ),
            if (sigma > 0.5)
              Positioned.fill(
                child: Opacity(
                  opacity: (sigma / 7).clamp(0, 1),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.touch_app_rounded, size: 16, color: widget.fg),
                        const SizedBox(width: 6),
                        Text(
                          'Коснись, чтобы прочитать',
                          style: TextStyle(
                            color: widget.fg,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 210),
          child: widget.child,
        ),
      ),
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
                duration: const Duration(milliseconds: 200),
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
      duration: const Duration(milliseconds: 500),
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
      duration: const Duration(milliseconds: 900),
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
  });

  final Message m;
  final Contact contact;
  final Rect rect;
  final VoidCallback onReply;

  static const _barH = 56.0;
  static const _menuH = 4 * 48.0 + 12;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final size = MediaQuery.sizeOf(context);
    final pad = MediaQuery.paddingOf(context);

    // Сдвигаем пузырь, чтобы меню целиком поместилось на экране.
    final bubbleH = min(rect.height, size.height * 0.4);
    final wantTop = rect.top - _barH - 10;
    final wantBottom = rect.top + bubbleH + 10 + _menuH;
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
            duration: const Duration(milliseconds: 320),
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
                    child: _ActionsMenu(m: m, contact: contact, onReply: onReply, close: close),
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
                duration: Duration(milliseconds: 380 + i * 50),
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
    required this.close,
  });

  final Message m;
  final Contact contact;
  final VoidCallback onReply;
  final VoidCallback close;

  @override
  Widget build(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;

    Widget action(IconData icon, String label, VoidCallback onTap, {bool danger = false}) {
      final color = danger ? VeilColors.danger : vc.text;
      return InkWell(
        onTap: onTap,
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
      duration: const Duration(milliseconds: 280),
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
            width: 220,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                action(Icons.reply_rounded, 'Ответить', () {
                  close();
                  onReply();
                }),
                action(Icons.copy_rounded, 'Копировать', () {
                  Clipboard.setData(ClipboardData(text: m.text));
                  close();
                  showVeilToast(context, 'Скопировано', icon: Icons.copy_rounded);
                }),
                action(Icons.push_pin_outlined, 'Закрепить', () {
                  close();
                  showVeilToast(
                    context,
                    'Закрепление сообщений — скоро',
                    icon: Icons.push_pin_rounded,
                  );
                }),
                action(Icons.delete_outline_rounded, 'Удалить у себя', () {
                  app.deleteMessage(contact.id, m);
                  close();
                }, danger: true),
              ],
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
    required this.onSend,
    required this.onRecordStart,
    required this.onRecordEnd,
  });

  final bool hasText;
  final bool recording;
  final VoidCallback onSend;
  final VoidCallback onRecordStart;
  final VoidCallback onRecordEnd;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final vc = context.vc;
    final active = hasText || recording;
    final button = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
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
        duration: const Duration(milliseconds: 260),
        transitionBuilder: (c, a) => RotationTransition(
          turns: Tween(begin: -0.25, end: 0.0).animate(a),
          child: ScaleTransition(scale: a, child: c),
        ),
        child: hasText
            ? Icon(Icons.arrow_upward_rounded, key: const ValueKey('send'), color: acc.onAccent)
            : Icon(
                Icons.mic_rounded,
                key: const ValueKey('mic'),
                color: recording ? acc.onAccent : vc.textDim,
              ),
      ),
    );

    if (hasText) return Pressable(scale: 0.85, onTap: onSend, haptic: false, child: button);
    return GestureDetector(
      onLongPressStart: (_) => onRecordStart(),
      onLongPressEnd: (_) => onRecordEnd(),
      onTap: () =>
          showVeilToast(context, 'Удерживай, чтобы записать голосовое', icon: Icons.mic_rounded),
      child: button,
    );
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({required this.seconds});
  final int seconds;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return SizedBox(
      key: const ValueKey('rec'),
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 4),
          const _PulsingDot(),
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
            child: Text(
              'отпусти — отправится',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: vc.textFaint, fontSize: 13),
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
  const _ReplyPreview({required this.m, required this.contact, required this.onClose});

  final Message m;
  final Contact contact;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    final text = m.kind == MsgKind.voice
        ? '🎤 Голосовое сообщение'
        : m.secret
        ? '🔒 Секретное сообщение'
        : m.text;
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
            const GradientIcon(Icons.reply_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.mine ? 'Ответ себе' : 'Ответ: ${contact.name}',
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
    (Icons.photo_rounded, 'Фото', [Color(0xFF7C5CFF), Color(0xFF00C2FF)]),
    (Icons.photo_camera_rounded, 'Камера', [Color(0xFFFF4F8B), Color(0xFFFFA45C)]),
    (Icons.insert_drive_file_rounded, 'Файл', [Color(0xFF00C896), Color(0xFF0098E6)]),
    (Icons.location_on_rounded, 'Место', [Color(0xFFFFC145), Color(0xFFFF7A45)]),
    (Icons.poll_rounded, 'Опрос', [Color(0xFFB06AB3), Color(0xFF4568DC)]),
  ];

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Glass(
        radius: 24,
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            for (final (i, (icon, label, colors)) in _items.indexed)
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: Duration(milliseconds: 350 + i * 60),
                curve: Interval(i * 0.1, 1, curve: Curves.easeOutBack),
                builder: (_, t, c) => Transform.translate(
                  offset: Offset(0, (1 - t) * 20),
                  child: Opacity(opacity: t.clamp(0, 1), child: c),
                ),
                child: Pressable(
                  onTap: () => onPick(label),
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
              '${contact.name} добавил(а) тебя по твоему коду. '
              'Если не знаешь этого человека — заблокируй.',
              style: TextStyle(color: vc.textDim, fontSize: 13.5, height: 1.35),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
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
