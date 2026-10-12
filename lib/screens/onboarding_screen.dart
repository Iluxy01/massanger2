import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/notifier.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Step { intro, profile, keys }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Step step = _Step.intro;
  String name = '';
  String emoji = avatarEmojis.first;
  int gradient = 1;

  @override
  Widget build(BuildContext context) {
    final Widget body = switch (step) {
      _Step.intro => _Intro(onDone: () => setState(() => step = _Step.profile)),
      _Step.profile => _ProfileSetup(
        name: name,
        emoji: emoji,
        gradient: gradient,
        onChanged: (n, e, g) => setState(() {
          name = n;
          emoji = e;
          gradient = g;
        }),
        onDone: () => setState(() => step = _Step.keys),
      ),
      _Step.keys => _KeyGen(
        onDone: () async {
          final app = context.appRead;
          await app.createProfile(name: name.trim(), emoji: emoji, colorIndex: gradient);
          // Разрешение на уведомления (Android 13+) — сразу после создания профиля.
          if (!app.demo) SystemNotify.requestPermission().catchError((_) {});
        },
      ),
    };
    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: AuroraBackground(
        child: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(
                position: Tween(begin: const Offset(0.15, 0), end: Offset.zero).animate(a),
                child: c,
              ),
            ),
            child: KeyedSubtree(key: ValueKey(step), child: body),
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── Интро ─────────────────────────────

class _IntroPage {
  const _IntroPage(this.icon, this.title, this.text, this.orbit);
  final IconData icon;
  final String title;
  final String text;
  final List<String> orbit;
}

const _pages = [
  _IntroPage(
    Icons.smartphone_rounded,
    'Только на твоём\nтелефоне',
    'Сообщения не хранятся на серверах. Вообще. Переписка живёт только на твоём устройстве и у друга.',
    ['💬', '🔒', '📱'],
  ),
  _IntroPage(
    Icons.key_rounded,
    'Сквозное\nшифрование',
    'Каждое сообщение шифруется ключом, который никогда не покидает телефон. Даже мы не сможем его прочитать.',
    ['🔑', '🛡️', '✨'],
  ),
  _IntroPage(
    Icons.favorite_rounded,
    'Бесплатно.\nНавсегда.',
    'Без рекламы, подписок и слежки. Только ты и твои друзья.',
    ['🎉', '🤝', '🚀'],
  ),
];

class _Intro extends StatefulWidget {
  const _Intro({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_Intro> createState() => _IntroState();
}

class _IntroState extends State<_Intro> {
  final _pc = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final last = _page == _pages.length - 1;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
          child: Row(
            children: [
              const VeilLogo(size: 34, glow: false),
              const SizedBox(width: 10),
              Text(
                'Veil',
                style: TextStyle(
                  color: vc.text,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const Spacer(),
              AnimatedOpacity(
                duration: const Duration(milliseconds: 250),
                opacity: last ? 0 : 1,
                child: TextButton(
                  onPressed: last ? null : widget.onDone,
                  child: Text('Пропустить', style: TextStyle(color: vc.textDim)),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pc,
            itemCount: _pages.length,
            onPageChanged: (i) {
              context.appRead.tick(HapticKind.selection);
              setState(() => _page = i);
            },
            itemBuilder: (_, i) => AnimatedBuilder(
              animation: _pc,
              builder: (_, _) {
                final pos = _pc.hasClients && _pc.position.haveDimensions ? _pc.page! : 0.0;
                final d = (i - pos).clamp(-1.0, 1.0);
                return _IntroPageView(page: _pages[i], delta: d);
              },
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeOutCubic,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: active ? 28 : 8,
                    height: 8,
                    decoration: BoxDecoration(
                      gradient: active ? context.accent.gradient : null,
                      color: active ? null : vc.textFaint.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 28),
              AccentButton(
                label: last ? 'Создать профиль' : 'Далее',
                icon: Icons.arrow_forward_rounded,
                onTap: () {
                  if (last) {
                    widget.onDone();
                  } else {
                    _pc.nextPage(
                      duration: const Duration(milliseconds: 500),
                      curve: Curves.easeOutCubic,
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _IntroPageView extends StatelessWidget {
  const _IntroPageView({required this.page, required this.delta});

  final _IntroPage page;
  final double delta;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final fade = 1 - delta.abs();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // На маленьких экранах иллюстрация сжимается, текст — нет.
          Flexible(
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Transform.translate(
                  offset: Offset(delta * 120, 0),
                  child: Transform.scale(
                    scale: 0.8 + 0.2 * fade,
                    child: _Orbit(icon: page.icon, orbit: page.orbit),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
          Opacity(
            opacity: fade.clamp(0, 1),
            child: Transform.translate(
              offset: Offset(delta * 60, 0),
              child: Column(
                children: [
                  Text(
                    page.title,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: vc.text,
                      fontSize: 34,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    page.text,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: vc.textDim, fontSize: 16, height: 1.45),
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

/// Светящийся шар с иконкой и вращающимися вокруг «спутниками».
class _Orbit extends StatefulWidget {
  const _Orbit({required this.icon, required this.orbit});

  final IconData icon;
  final List<String> orbit;

  @override
  State<_Orbit> createState() => _OrbitState();
}

class _OrbitState extends State<_Orbit> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 14))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final vc = context.vc;
    const size = 260.0;
    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) {
          final t = _c.value * 2 * pi;
          final breathe = 1 + 0.04 * sin(t * 3);
          return Stack(
            alignment: Alignment.center,
            children: [
              for (final r in [size, size * 0.72])
                Container(
                  width: r,
                  height: r,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: vc.text.withValues(alpha: 0.07)),
                  ),
                ),
              Transform.scale(
                scale: breathe,
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: acc.gradient,
                    boxShadow: [
                      BoxShadow(
                        color: acc.a.withValues(alpha: 0.5),
                        blurRadius: 50,
                        spreadRadius: 4,
                      ),
                      BoxShadow(
                        color: acc.b.withValues(alpha: 0.35),
                        blurRadius: 90,
                        spreadRadius: 10,
                      ),
                    ],
                  ),
                  child: Icon(widget.icon, size: 50, color: acc.onAccent),
                ),
              ),
              for (var i = 0; i < widget.orbit.length; i++)
                Builder(
                  builder: (_) {
                    final ring = i.isEven ? size / 2 : size * 0.36;
                    final a = t * (i.isEven ? 1 : -1.4) + i * 2 * pi / widget.orbit.length;
                    return Transform.translate(
                      offset: Offset(cos(a) * ring, sin(a) * ring),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: vc.elevated,
                          border: Border.all(color: vc.border),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 12),
                          ],
                        ),
                        child: Text(widget.orbit[i], style: const TextStyle(fontSize: 20)),
                      ),
                    );
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

// ───────────────────────────── Профиль ─────────────────────────────

class _ProfileSetup extends StatefulWidget {
  const _ProfileSetup({
    required this.name,
    required this.emoji,
    required this.gradient,
    required this.onChanged,
    required this.onDone,
  });

  final String name;
  final String emoji;
  final int gradient;
  final void Function(String name, String emoji, int gradient) onChanged;
  final VoidCallback onDone;

  @override
  State<_ProfileSetup> createState() => _ProfileSetupState();
}

class _ProfileSetupState extends State<_ProfileSetup> {
  late final _name = TextEditingController(text: widget.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final ok = widget.name.trim().length >= 2;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      children: [
        Text(
          'Кто ты?',
          style: TextStyle(
            color: vc.text,
            fontSize: 34,
            fontWeight: FontWeight.w800,
            letterSpacing: -1,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Профиль хранится только на этом телефоне.\nНикаких номеров и почты.',
          style: TextStyle(color: vc.textDim, fontSize: 15, height: 1.4),
        ),
        const SizedBox(height: 32),
        Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 450),
            transitionBuilder: (c, a) => RotationTransition(
              turns: Tween(
                begin: -0.15,
                end: 0.0,
              ).animate(CurvedAnimation(parent: a, curve: Curves.easeOutBack)),
              child: ScaleTransition(
                scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
                child: c,
              ),
            ),
            child: Container(
              key: ValueKey('${widget.emoji}${widget.gradient}'),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: avatarGradients[widget.gradient].first.withValues(alpha: 0.5),
                    blurRadius: 40,
                  ),
                ],
              ),
              child: Avatar(
                emoji: widget.emoji,
                colors: avatarGradients[widget.gradient],
                size: 116,
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        Glass(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: TextField(
            controller: _name,
            maxLength: 24,
            textCapitalization: TextCapitalization.words,
            style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w600),
            onChanged: (v) => widget.onChanged(v, widget.emoji, widget.gradient),
            decoration: InputDecoration(
              border: InputBorder.none,
              counterText: '',
              hintText: 'Твоё имя или ник',
              hintStyle: TextStyle(color: vc.textFaint),
              icon: Icon(Icons.alternate_email_rounded, color: vc.textDim),
            ),
          ),
        ),
        const SizedBox(height: 24),
        _label(context, 'Цвет'),
        SizedBox(
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: avatarGradients.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, i) {
              final sel = i == widget.gradient;
              return Pressable(
                onTap: () => widget.onChanged(widget.name, widget.emoji, i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 44,
                  height: 44,
                  padding: EdgeInsets.all(sel ? 3 : 0),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: sel ? vc.text : Colors.transparent, width: 2),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(colors: avatarGradients[i]),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 20),
        _label(context, 'Аватар'),
        GridView.count(
          crossAxisCount: 8,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          children: [
            for (final e in avatarEmojis)
              Pressable(
                onTap: () => widget.onChanged(widget.name, e, widget.gradient),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: e == widget.emoji ? vc.text.withValues(alpha: 0.12) : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutBack,
                    scale: e == widget.emoji ? 1.2 : 1,
                    child: Text(e, style: const TextStyle(fontSize: 22)),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 32),
        AccentButton(
          label: 'Сгенерировать ключи',
          icon: Icons.key_rounded,
          onTap: ok
              ? () {
                  FocusScope.of(context).unfocus();
                  widget.onDone();
                }
              : null,
        ),
      ],
    );
  }

  Widget _label(BuildContext context, String t) => Padding(
    padding: const EdgeInsets.only(bottom: 10, left: 4),
    child: Text(
      t.toUpperCase(),
      style: TextStyle(
        color: context.vc.textFaint,
        fontSize: 12,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.4,
      ),
    ),
  );
}

// ───────────────────────────── Генерация ключей ─────────────────────────────

class _KeyGen extends StatefulWidget {
  const _KeyGen({required this.onDone});
  final VoidCallback onDone;

  @override
  State<_KeyGen> createState() => _KeyGenState();
}

class _KeyGenState extends State<_KeyGen> with SingleTickerProviderStateMixin {
  static const _steps = [
    'Генерация пары ключей X25519',
    'Создание ключа подписи Ed25519',
    'Шифрование локального хранилища',
    'Ключи сохранены только на этом устройстве',
  ];

  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 2))
    ..repeat();
  final _target = randomHex(32);
  final _timers = <Timer>[];
  int _done = 0;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < _steps.length; i++) {
      _timers.add(
        Timer(Duration(milliseconds: 900 + i * 750), () {
          if (!mounted) return;
          context.appRead.tick(i == _steps.length - 1 ? HapticKind.medium : HapticKind.light);
          setState(() => _done = i + 1);
          if (_done == _steps.length) _spin.stop();
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final t in _timers) {
      t.cancel();
    }
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    final finished = _done == _steps.length;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Spacer(),
          SizedBox(
            width: 170,
            height: 170,
            child: Stack(
              alignment: Alignment.center,
              children: [
                AnimatedBuilder(
                  animation: _spin,
                  builder: (_, _) => Transform.rotate(
                    angle: _spin.value * 2 * pi,
                    child: CustomPaint(
                      size: const Size.square(170),
                      painter: _ArcPainter(acc.a, acc.b, finished ? 1 : 0.7),
                    ),
                  ),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  transitionBuilder: (c, a) => ScaleTransition(
                    scale: CurvedAnimation(parent: a, curve: Curves.elasticOut),
                    child: c,
                  ),
                  child: finished
                      ? Container(
                          key: const ValueKey('ok'),
                          width: 96,
                          height: 96,
                          decoration: BoxDecoration(shape: BoxShape.circle, gradient: acc.gradient),
                          child: Icon(Icons.check_rounded, size: 52, color: acc.onAccent),
                        )
                      : const VeilLogo(key: ValueKey('logo'), size: 88),
                ),
              ],
            ),
          ),
          const SizedBox(height: 36),
          Text(
            finished ? 'Всё готово!' : 'Создаём твои ключи…',
            style: TextStyle(
              color: vc.text,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          ScrambleText(
            target: _target,
            duration: const Duration(milliseconds: 3600),
            style: TextStyle(
              color: acc.b,
              fontFamily: 'monospace',
              fontSize: 14,
              letterSpacing: 2,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 32),
          for (var i = 0; i < _steps.length; i++)
            AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: i <= _done ? 1 : 0.25,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                        child: i < _done
                            ? GradientIcon(
                                Icons.check_circle_rounded,
                                key: const ValueKey('done'),
                                size: 22,
                              )
                            : i == _done
                            ? SizedBox(
                                key: const ValueKey('wait'),
                                child: CircularProgressIndicator(strokeWidth: 2, color: acc.a),
                              )
                            : Icon(Icons.circle_outlined, size: 22, color: vc.textFaint),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(_steps[i], style: TextStyle(color: vc.text, fontSize: 15)),
                    ),
                  ],
                ),
              ),
            ),
          const Spacer(),
          AnimatedSlide(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutBack,
            offset: finished ? Offset.zero : const Offset(0, 1.5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 400),
              opacity: finished ? 1 : 0,
              child: AccentButton(
                label: 'Войти в Veil',
                icon: Icons.arrow_forward_rounded,
                onTap: finished ? widget.onDone : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.a, this.b, this.sweep);
  final Color a;
  final Color b;
  final double sweep;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(4);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(colors: [a.withValues(alpha: 0), a, b]).createShader(rect);
    canvas.drawArc(rect, 0, 2 * pi * sweep, false, p);
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.sweep != sweep || old.a != a;
}

/// Хаотичные символы, которые постепенно «проявляются» в настоящий ключ.
class ScrambleText extends StatefulWidget {
  const ScrambleText({super.key, required this.target, required this.duration, this.style});

  final String target;
  final Duration duration;
  final TextStyle? style;

  @override
  State<ScrambleText> createState() => _ScrambleTextState();
}

class _ScrambleTextState extends State<ScrambleText> {
  static const _chars = '0123456789ABCDEF';
  final _r = Random();
  Timer? _timer;
  final _start = DateTime.now();
  String _shown = '';

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(milliseconds: 45), (_) => _tick());
  }

  void _tick() {
    final p = (DateTime.now().difference(_start).inMilliseconds / widget.duration.inMilliseconds)
        .clamp(0.0, 1.0);
    final revealed = (widget.target.length * p).floor();
    final buf = StringBuffer();
    for (var i = 0; i < widget.target.length; i++) {
      if (i > 0 && i % 4 == 0) buf.write(i % 16 == 0 ? '\n' : ' ');
      buf.write(i < revealed ? widget.target[i] : _chars[_r.nextInt(16)]);
    }
    if (mounted) setState(() => _shown = buf.toString());
    if (p >= 1) _timer?.cancel();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Text(_shown, textAlign: TextAlign.center, style: widget.style);
}
