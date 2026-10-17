import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/sky.dart';
import 'slow_clock.dart';
import 'visual.dart';

/// Фон экрана: северное сияние (у других стилей — их фон: сетка, космос, пятна).
///
/// Неподвижное рисуется один раз в готовую картинку (см. [Sky]). Движение —
/// по [SlowClock]: обычным таймером 20–30 кадров в секунду, только пока экран
/// виден, и на «Балансе»/«Максимуме» — только пока экран трогают (потом фон
/// замирает до следующего касания). На приветствии ([animate]) — всегда.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, this.child, this.intensity = 1, this.animate = false});

  final Widget? child;
  final double intensity;
  final bool animate;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> {
  final _clock = SlowClock(start: 0.18);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
    _clock.attach(context);
  }

  @override
  void didUpdateWidget(AuroraBackground old) {
    super.didUpdateWidget(old);
    _configure();
    _clock.sync();
  }

  Sky _sky() {
    final v = context.visual;
    final vc = context.vc;
    return Sky(
      skin: v.skin,
      c: vc,
      acc: context.accent,
      dim: 0.6 + 0.4 * widget.intensity,
      // «Минимум» — чистый фон без сияния.
      aurora: v.look == 0 ? 0 : widget.intensity * (vc.dark ? 1 : 0.6),
    );
  }

  /// Движется ли фон: на приветствии — всегда; у стилей — и на «Балансе»;
  /// у классики — только на «Максимуме»; с выключенными анимациями — нигде.
  void _configure() {
    final v = context.visual;
    final full = widget.animate || v.look == 2;
    final skinned = v.skin.id != 0;
    _clock
      ..wanted = v.motion > 0 && v.look > 0 && (full || skinned) && _sky().moves
      ..fps = full ? 30 : 20
      ..idle = widget.animate ? null : Duration(seconds: full ? 30 : 8)
      ..period = Duration(seconds: skinned ? 60 : 24);
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final bg = RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: SkyPainter(
          _sky(),
          t: _clock,
          moving: _clock.running,
          screen: mq.size,
          dpr: mq.devicePixelRatio,
        ),
      ),
    );
    final child = widget.child;
    if (child == null) return bg;
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(child: bg),
        child,
      ],
    );
  }
}

/// Матовая панель.
///
/// По умолчанию — без размытия (просто полупрозрачная заливка): размытие
/// пересчитывается каждый кадр и сильно грузит видеочип. [blur] включаем только
/// там, где под панелью действительно прокручивается содержимое.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 24,
    this.blur = 0,
    this.padding,
    this.color,
    this.border = true,
  });

  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final Color? color;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final skin = context.skin;
    final r = BorderRadius.circular(radius * skin.radius);
    // «Минимум» — без размытия вовсе, «Максимум» — матовое стекло везде.
    final blur = switch (context.visual.look) {
      0 => 0.0,
      2 => this.blur > 0 ? this.blur : 14.0,
      _ => this.blur,
    };
    final box = Container(
      padding: padding,
      decoration: BoxDecoration(
        // Панель, которая должна была размываться, на «Минимуме» почти
        // непрозрачная — чтобы текст под ней не просвечивал.
        color:
            color ??
            (blur > 0
                ? vc.glass
                : this.blur > 0
                ? Color.alphaBlend(vc.panel, vc.bg)
                : vc.panel),
        borderRadius: r,
        border: border && skin.border > 0 ? Border.all(color: vc.border, width: skin.border) : null,
        // Лимонад: вместо обводки — мягкая тёплая тень.
        boxShadow: skin.shadow && border
            ? const [BoxShadow(color: Color(0x14603A00), blurRadius: 16, offset: Offset(0, 4))]
            : null,
      ),
      child: child,
    );
    if (blur <= 0) return box;
    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: box,
      ),
    );
  }
}

/// Пружинит при нажатии.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.95,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) context.appRead.tick(HapticKind.selection);
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              _set(false);
              context.appRead.tick(HapticKind.medium);
              widget.onLongPress!();
            },
      child: Builder(
        builder: (context) {
          // Терминал почти не «вжимается», Лимонад — заметно и с отскоком.
          final skin = context.skin;
          return AnimatedScale(
            scale: _down ? 1 - (1 - widget.scale) * skin.press : 1,
            duration: const Duration(milliseconds: 140).by(context),
            curve: skin.curve,
            child: widget.child,
          );
        },
      ),
    );
  }
}

/// Текст с градиентной заливкой в цветах акцента.
class GradientText extends StatelessWidget {
  const GradientText(this.text, {super.key, this.style, this.gradient});

  final String text;
  final TextStyle? style;
  final Gradient? gradient;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => (gradient ?? context.accent.gradient).createShader(r),
      child: Text(text, style: style),
    );
  }
}

class GradientIcon extends StatelessWidget {
  const GradientIcon(this.icon, {super.key, this.size = 24});

  final IconData icon;
  final double size;

  // Без ShaderMask: тот отрисовывал каждый значок в отдельный слой, а их на
  // экране настроек десятки — это и тормозило переключение вкладок. Здесь
  // глиф рисуется сразу градиентной «краской». Сам Icon остаётся в дереве
  // (невидимым) — для размеров и поиска значков.
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _GlyphPainter(icon, size, context.accent.gradient),
      child: Opacity(opacity: 0, child: Icon(icon, size: size)),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.icon, this.size, this.gradient);

  final IconData icon;
  final double size;
  final Gradient gradient;

  @override
  void paint(Canvas canvas, Size box) {
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          inherit: false,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          fontFamilyFallback: icon.fontFamilyFallback,
          fontSize: size,
          height: 1,
          leadingDistribution: TextLeadingDistribution.even,
          foreground: Paint()..shader = gradient.createShader(Offset.zero & box),
        ),
      ),
    )..layout();
    tp.paint(canvas, Offset((box.width - tp.width) / 2, (box.height - tp.height) / 2));
    tp.dispose();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.icon != icon || old.size != size || old.gradient != gradient;
}

/// Главная кнопка с градиентом и мягким свечением.
class AccentButton extends StatelessWidget {
  const AccentButton({super.key, required this.label, this.onTap, this.icon, this.expanded = true});

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final skin = context.skin;
    final enabled = onTap != null;
    // Свечение: Терминал — короткое и тусклое, Космос — широкое, Лимонад —
    // мягкая тень снизу.
    final (glow, blur, dy) = switch (skin.id) {
      1 => (0.25, 14.0, 0.0),
      2 => (0.6, 32.0, 0.0),
      3 => (0.35, 16.0, 6.0),
      _ => (0.45, 24.0, 8.0),
    };
    return Pressable(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200).by(context),
        opacity: enabled ? 1 : 0.4,
        child: Container(
          height: 56,
          width: expanded ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            gradient: acc.gradient,
            borderRadius: BorderRadius.circular(18 * skin.radius),
            boxShadow: [
              BoxShadow(
                color: acc.mid.withValues(alpha: enabled ? glow : 0),
                blurRadius: blur,
                offset: Offset(0, dy),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: acc.onAccent,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              if (icon != null) ...[
                const SizedBox(width: 8),
                Icon(icon, color: acc.onAccent, size: 20),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Логотип Veil: «V», сотканная из двух лент, на градиентном сквиркле.
class VeilLogo extends StatelessWidget {
  const VeilLogo({super.key, this.size = 72, this.glow = true});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: acc.gradient,
        borderRadius: BorderRadius.circular(size * 0.32 * min(context.skin.radius, 1.3)),
        boxShadow: glow
            ? [BoxShadow(color: acc.mid.withValues(alpha: 0.55), blurRadius: size * 0.6)]
            : null,
      ),
      child: CustomPaint(painter: _LogoPainter(acc.onAccent)),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s.width * 0.1
      ..strokeCap = StrokeCap.round;
    final left = Path()
      ..moveTo(s.width * 0.28, s.height * 0.3)
      ..quadraticBezierTo(s.width * 0.36, s.height * 0.62, s.width * 0.5, s.height * 0.72);
    final right = Path()
      ..moveTo(s.width * 0.72, s.height * 0.3)
      ..quadraticBezierTo(s.width * 0.64, s.height * 0.62, s.width * 0.5, s.height * 0.72);
    canvas.drawPath(left, p);
    canvas.drawPath(right, p..color = color.withValues(alpha: 0.7));
    canvas.drawCircle(
      Offset(s.width * 0.5, s.height * 0.3),
      s.width * 0.055,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}

/// Три прыгающие точки «печатает…».
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 6});

  final Color? color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> {
  // 30 кадров в секунду таймером, а не на каждом кадре экрана (120 Гц).
  final _c = SlowClock()
    ..wanted = true
    ..fps = 30
    ..period = const Duration(milliseconds: 1100);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _c.attach(context);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.accent.mid;
    final skin = context.skin.id;
    final sz = widget.size;
    final margin = EdgeInsets.symmetric(horizontal: sz * 0.25);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final t = (_c.value - i * 0.16) % 1.0;
          switch (skin) {
            // Терминал: квадратики загораются по очереди, без прыжков.
            case 1:
              final on = (_c.value * 4).floor() % 4 > i;
              return Container(
                margin: margin,
                width: sz,
                height: sz,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: on ? 0.95 : 0.22),
                  borderRadius: BorderRadius.circular(1.5),
                ),
              );
            // Космос: точки мерцают, как звёзды.
            case 2:
              final glow = 0.5 + 0.5 * sin(t * 2 * pi);
              return Container(
                margin: margin,
                width: sz,
                height: sz,
                transform: Matrix4.diagonal3Values(0.7 + 0.4 * glow, 0.7 + 0.4 * glow, 1),
                transformAlignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.35 + 0.65 * glow),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: color.withValues(alpha: 0.55 * glow),
                      blurRadius: sz * 1.4,
                    ),
                  ],
                ),
              );
            // Лимонад: прыгают и чуть «сплющиваются», приземляясь.
            case 3:
              final up = t < 0.5 ? sin(t * 2 * pi) : 0.0;
              final squash = t >= 0.5 && t < 0.64 ? sin((t - 0.5) / 0.14 * pi) : 0.0;
              return Container(
                margin: margin,
                width: sz,
                height: sz,
                transform: Matrix4.diagonal3Values(1 + 0.25 * squash, 1 - 0.3 * squash, 1)
                  ..setTranslationRaw(0, -up * sz, 0),
                transformAlignment: Alignment.bottomCenter,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.45 + 0.55 * up),
                  shape: BoxShape.circle,
                ),
              );
            default:
              final bounce = t < 0.5 ? sin(t * 2 * pi).clamp(0.0, 1.0) : 0.0;
              return Container(
                margin: margin,
                width: sz,
                height: sz,
                transform: Matrix4.translationValues(0, -bounce * sz * 0.8, 0),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.4 + 0.6 * bounce),
                  shape: BoxShape.circle,
                ),
              );
          }
        }),
      ),
    );
  }
}

/// Кастомный переключатель с градиентом.
class VeilSwitch extends StatelessWidget {
  const VeilSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final vc = context.vc;
    final skin = context.skin;
    // Терминал — прямоугольный, без отскока; Космос — ползунок светится.
    final square = skin.id == 1;
    return Pressable(
      scale: 0.9,
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260).by(context),
        curve: Curves.easeOutCubic,
        width: 50,
        height: 30,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          gradient: value ? acc.gradient : null,
          color: value ? null : vc.elevated,
          borderRadius: BorderRadius.circular(square ? 5 : 20),
          border: Border.all(color: value ? Colors.transparent : vc.border),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 320).by(context),
          curve: square ? Curves.easeOutQuart : Curves.easeOutBack,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: square && !value ? vc.textDim : Colors.white,
              shape: square ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: square ? BorderRadius.circular(3) : null,
              boxShadow: [
                if (skin.glow && value)
                  BoxShadow(color: Colors.white.withValues(alpha: 0.7), blurRadius: 10)
                else
                  BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Появление с задержкой — для «каскадных» списков.
class Reveal extends StatelessWidget {
  const Reveal({super.key, required this.child, this.index = 0, this.offset = 24});

  final Widget child;
  final int index;
  final double offset;

  @override
  Widget build(BuildContext context) {
    final delay = (index * 0.06).clamp(0.0, 0.6);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 500 + (delay * 1000).round()).by(context),
      curve: Interval(delay / (0.5 + delay), 1, curve: Curves.easeOutCubic),
      builder: (_, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * offset), child: child),
      ),
      child: child,
    );
  }
}

/// Тряска (неверный PIN и т.п.). Меняйте [trigger], чтобы встряхнуть.
class Shake extends StatelessWidget {
  const Shake({super.key, required this.trigger, required this.child});

  final int trigger;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(trigger),
      tween: Tween(begin: trigger == 0 ? 1 : 0, end: 1),
      duration: const Duration(milliseconds: 500).by(context),
      builder: (_, t, child) =>
          Transform.translate(offset: Offset(sin(t * pi * 6) * 14 * (1 - t), 0), child: child),
      child: child,
    );
  }
}

/// Небольшое уведомление снизу.
void showVeilToast(
  BuildContext context,
  String text, {
  IconData icon = Icons.check_circle_rounded,
}) {
  final acc = context.appRead.accent;
  final vc = context.appRead.colors;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 100),
        duration: const Duration(milliseconds: 2200),
        content: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: vc.elevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: vc.border),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 20)],
          ),
          child: Row(
            children: [
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => acc.gradient.createShader(r),
                child: Icon(icon, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text, style: TextStyle(color: vc.text, fontSize: 14)),
              ),
            ],
          ),
        ),
      ),
    );
}
