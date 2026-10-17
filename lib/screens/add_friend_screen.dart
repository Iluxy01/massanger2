import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/protocol.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'chat_screen.dart';
import '../widgets/visual.dart';

/// Добавление друга без номера телефона: обмен QR-кодами при встрече.
class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const AddFriendScreen());

  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  int _tab = 0;
  Contact? _added;

  /// Сканирован QR или вставлен код. null — демо-«сканирование».
  Future<void> _add(Invite? inv) async {
    final app = context.appRead;
    if (_added != null) return;
    if (inv == null) {
      app.tick(HapticKind.heavy);
      setState(() => _added = app.addRandomFriend());
      return;
    }
    if (inv.pubkey == app.profile?.fingerprint) {
      showVeilToast(context, 'Это твой собственный код 🙂', icon: Icons.info_outline_rounded);
      return;
    }
    app.tick(HapticKind.heavy);
    final c = await app.addContact(inv);
    if (mounted) setState(() => _added = c);
  }

  /// Отсканирована ссылка канала — просимся в подписчики.
  void _join(ChannelInvite ci) {
    final app = context.appRead;
    app.tick(HapticKind.heavy);
    final ok = app.joinChannel(ci);
    showVeilToast(
      context,
      ok
          ? 'Попросились в «${ci.name}». Канал появится в чатах, когда автор будет в сети.'
          : 'Это твой канал или ты уже подписан(а)',
      icon: Icons.campaign_rounded,
    );
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Scaffold(
      backgroundColor: vc.bg,
      body: AuroraBackground(
        intensity: 0.9,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(Icons.arrow_back_ios_new_rounded, color: vc.text, size: 20),
                    ),
                    Text(
                      'Добавить друга',
                      style: TextStyle(color: vc.text, fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: _SegmentSwitch(
                  index: _tab,
                  labels: const ['Мой код', 'Сканировать'],
                  onChanged: (i) => setState(() => _tab = i),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400).by(context),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (c, a) => FadeTransition(
                    opacity: a,
                    child: ScaleTransition(
                      scale: Tween(begin: 0.96, end: 1.0).animate(a),
                      child: c,
                    ),
                  ),
                  child: _added != null
                      ? _Success(key: const ValueKey('ok'), contact: _added!)
                      : _tab == 0
                      ? const _MyCode(key: ValueKey('code'))
                      : _Scanner(key: const ValueKey('scan'), onScanned: _add, onChannel: _join),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SegmentSwitch extends StatelessWidget {
  const _SegmentSwitch({required this.index, required this.labels, required this.onChanged});

  final int index;
  final List<String> labels;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Glass(
      radius: 18,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        height: 42,
        child: Stack(
          children: [
            AnimatedAlign(
              duration: const Duration(milliseconds: 350).by(context),
              curve: Curves.easeOutBack,
              alignment: index == 0 ? Alignment.centerLeft : Alignment.centerRight,
              child: FractionallySizedBox(
                widthFactor: 1 / labels.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: acc.gradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        context.appRead.tick(HapticKind.selection);
                        onChanged(i);
                      },
                      child: Center(
                        child: AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 250).by(context),
                          style: TextStyle(
                            color: i == index ? acc.onAccent : vc.textDim,
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                          child: Text(labels[i]),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MyCode extends StatefulWidget {
  const _MyCode({super.key});

  @override
  State<_MyCode> createState() => _MyCodeState();
}

class _MyCodeState extends State<_MyCode> {
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final p = app.profile!;
    final data = app.inviteLink;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      child: Column(
        children: [
          // Крупный и контрастный: квадратные модули, тёмные «глаза», без логотипа
          // в центре — так код меньше по плотности и быстрее читается камерой.
          LayoutBuilder(
            builder: (context, box) {
              final side = box.maxWidth.clamp(200.0, 420.0);
              return Container(
                width: side,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  gradient: acc.gradient,
                  boxShadow: [BoxShadow(color: acc.mid.withValues(alpha: 0.3), blurRadius: 30)],
                ),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(27),
                  ),
                  child: QrImageView(
                    data: data,
                    padding: EdgeInsets.zero,
                    gapless: true,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF0F0F18),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF0F0F18),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 22),
          Avatar(emoji: p.emoji, colors: p.colors, size: 56),
          Text(
            p.name,
            style: TextStyle(color: vc.text, fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Pressable(
            onTap: () {
              Clipboard.setData(ClipboardData(text: app.inviteLink));
              showVeilToast(
                context,
                'Код-приглашение скопирован — вставь его в Veil друга',
                icon: Icons.copy_rounded,
              );
            },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  p.veilId,
                  style: TextStyle(
                    color: vc.textDim,
                    fontFamily: 'monospace',
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(width: 6),
                Icon(Icons.copy_rounded, size: 16, color: vc.textFaint),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            'Покажи этот код другу или отправь ссылку. В нём только твой публичный ключ — переписка всё равно останется на телефонах.',
            textAlign: TextAlign.center,
            style: TextStyle(color: vc.textDim, height: 1.45, fontSize: 14),
          ),
          const SizedBox(height: 24),
          AccentButton(
            label: 'Отправить ссылку',
            icon: Icons.ios_share_rounded,
            onTap: () => shareInvite(context),
          ),
        ],
      ),
    );
  }
}

/// Поделиться ссылкой-приглашением через любой мессенджер или почту.
Future<void> shareInvite(BuildContext context) async {
  final app = context.appRead;
  final link = app.inviteLink;
  final text =
      'Привет! Давай переписываться в Veil — приватном мессенджере без серверов.\n\n'
      'Мой код (вставь его в Veil → Друзья → Добавить друга → Сканировать → «Вставить код»):\n$link';
  try {
    await SharePlus.instance.share(ShareParams(text: text, subject: 'Мой код в Veil'));
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: text));
    if (context.mounted) {
      showVeilToast(context, 'Приглашение скопировано', icon: Icons.copy_rounded);
    }
  }
}

class _Scanner extends StatefulWidget {
  const _Scanner({super.key, required this.onScanned, required this.onChannel});
  final Future<void> Function(Invite?) onScanned;
  final void Function(ChannelInvite) onChannel;

  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> with SingleTickerProviderStateMixin {
  late final _line = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
    ..repeat(reverse: true);
  bool _done = false;
  bool _cameraFailed = false;

  @override
  void dispose() {
    _line.dispose();
    super.dispose();
  }

  void _detected(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final ch = ChannelInvite.parse(b.rawValue ?? '');
      if (ch != null) {
        _done = true;
        widget.onChannel(ch);
        return;
      }
      final inv = Invite.parse(b.rawValue ?? '');
      if (inv != null) {
        _done = true;
        widget.onScanned(inv);
        return;
      }
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final ch = ChannelInvite.parse(data?.text ?? '');
    if (ch != null) {
      widget.onChannel(ch);
      return;
    }
    final inv = Invite.parse(data?.text ?? '');
    if (inv == null) {
      showVeilToast(
        context,
        'В буфере нет кода Veil. Скопируй сообщение-приглашение друга целиком.',
        icon: Icons.content_paste_off_rounded,
      );
      return;
    }
    await widget.onScanned(inv);
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 32),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 1,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: RadialGradient(
                          colors: [const Color(0xFF22222E), const Color(0xFF0B0B10)],
                        ),
                      ),
                    ),
                  ),
                  if (!context.app.demo && !_cameraFailed)
                    Positioned.fill(
                      child: MobileScanner(
                        onDetect: _detected,
                        errorBuilder: (context, error) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) setState(() => _cameraFailed = true);
                          });
                          return const SizedBox();
                        },
                      ),
                    )
                  else
                    Center(
                      child: Icon(
                        _cameraFailed ? Icons.no_photography_outlined : Icons.photo_camera_outlined,
                        size: 56,
                        color: Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  Positioned.fill(child: CustomPaint(painter: _CornersPainter(acc.a, acc.b))),
                  AnimatedBuilder(
                    animation: _line,
                    builder: (_, _) => Align(
                      alignment: Alignment(0, -0.8 + 1.6 * Curves.easeInOut.transform(_line.value)),
                      child: Container(
                        height: 3,
                        margin: const EdgeInsets.symmetric(horizontal: 36),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [acc.a.withValues(alpha: 0), acc.b, acc.a.withValues(alpha: 0)],
                          ),
                          boxShadow: [BoxShadow(color: acc.b, blurRadius: 18, spreadRadius: 2)],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Наведи камеру на QR-код друга',
            style: TextStyle(color: vc.text, fontSize: 17, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            _cameraFailed
                ? 'Нет доступа к камере — разреши его в настройках или вставь код'
                : 'Друг далеко? Пусть пришлёт ссылку — вставь её кнопкой ниже',
            textAlign: TextAlign.center,
            style: TextStyle(color: vc.textDim, fontSize: 13),
          ),
          const Spacer(),
          if (context.app.demo)
            AccentButton(
              label: 'Симулировать сканирование',
              icon: Icons.qr_code_2_rounded,
              onTap: () => widget.onScanned(null),
            )
          else
            AccentButton(label: 'Вставить код', icon: Icons.content_paste_rounded, onTap: _paste),
        ],
      ),
    );
  }
}

class _CornersPainter extends CustomPainter {
  _CornersPainter(this.a, this.b);
  final Color a;
  final Color b;

  @override
  void paint(Canvas canvas, Size s) {
    const inset = 28.0;
    const len = 38.0;
    final p = Paint()
      ..shader = LinearGradient(colors: [a, b]).createShader(Offset.zero & s)
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final r = Rect.fromLTRB(inset, inset, s.width - inset, s.height - inset);
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      final path = Path()
        ..moveTo(corner.dx, corner.dy + dy * len)
        ..lineTo(corner.dx, corner.dy + dy * 10)
        ..quadraticBezierTo(corner.dx, corner.dy, corner.dx + dx * 10, corner.dy)
        ..lineTo(corner.dx + dx * len, corner.dy);
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_CornersPainter old) => old.a != a || old.b != b;
}

/// Друг добавлен — конфетти!
class _Success extends StatelessWidget {
  const _Success({super.key, required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Stack(
      children: [
        const Positioned.fill(child: IgnorePointer(child: _Confetti())),
        Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              const Spacer(),
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 900).by(context),
                curve: Curves.elasticOut,
                builder: (_, s, c) => Transform.scale(scale: s, child: c),
                child: Avatar.contact(contact, size: 130),
              ),
              const SizedBox(height: 24),
              Text(
                '${contact.name} теперь в Veil!',
                textAlign: TextAlign.center,
                style: TextStyle(color: vc.text, fontSize: 26, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              Text(
                'Ключи обменяны. При встрече сверьте код безопасности в профиле — так надёжнее всего.',
                textAlign: TextAlign.center,
                style: TextStyle(color: vc.textDim, height: 1.4),
              ),
              const Spacer(),
              AccentButton(
                label: 'Написать',
                icon: Icons.chat_bubble_rounded,
                onTap: () => Navigator.of(context).pushReplacement(ChatScreen.route(contact)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Confetti extends StatefulWidget {
  const _Confetti();

  @override
  State<_Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<_Confetti> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
    ..forward();
  final _r = Random();
  late final _pieces = List.generate(
    70,
    (_) => (
      dx: _r.nextDouble() * 2 - 1,
      speed: 0.6 + _r.nextDouble() * 0.8,
      spin: _r.nextDouble() * 8 - 4,
      hue: _r.nextDouble() * 360,
      w: 6 + _r.nextDouble() * 6,
    ),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => CustomPaint(painter: _ConfettiPainter(_c.value, _pieces)),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.t, this.pieces);

  final double t;
  final List<({double dx, double speed, double spin, double hue, double w})> pieces;

  @override
  void paint(Canvas canvas, Size s) {
    final origin = Offset(s.width / 2, s.height * 0.3);
    for (final p in pieces) {
      // Взрыв вверх-в стороны, потом гравитация.
      final x = origin.dx + p.dx * s.width * 0.7 * t;
      final y = origin.dy - 300 * p.speed * t + 900 * t * t;
      final paint = Paint()
        ..color = HSVColor.fromAHSV((1 - t).clamp(0, 1), p.hue, 0.7, 1).toColor();
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * t * pi);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: p.w, height: p.w * 0.5),
          const Radius.circular(2),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.t != t;
}
