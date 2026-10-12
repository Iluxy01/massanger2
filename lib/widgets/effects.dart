import 'dart:math';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// Медленно «дышащее» северное сияние на фоне.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, this.child, this.intensity = 1});

  final Widget? child;
  final double intensity;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 24))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _AuroraPainter(
          _c,
          bg: vc.bg,
          colors: [acc.a, acc.b, Color.lerp(acc.a, const Color(0xFFFF4F8B), 0.5)!],
          intensity: widget.intensity * (vc.dark ? 1 : 0.6),
        ),
        child: widget.child,
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.anim, {required this.bg, required this.colors, required this.intensity})
    : super(repaint: anim);

  final Animation<double> anim;
  final Color bg;
  final List<Color> colors;
  final double intensity;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = bg);
    final t = anim.value * 2 * pi;
    const speeds = [1.0, 2.0, 1.0];
    const phases = [0.0, 2.1, 4.2];
    for (var i = 0; i < colors.length; i++) {
      final cx = size.width * (0.5 + 0.38 * sin(t * speeds[i] + phases[i]));
      final cy = size.height * (0.32 + 0.28 * cos(t * speeds[i] * 0.7 + phases[i]) + i * 0.12);
      final r = size.width * (0.75 + 0.15 * sin(t + i));
      final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            colors[i].withValues(alpha: 0.30 * intensity),
            colors[i].withValues(alpha: 0),
          ],
        ).createShader(rect);
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      old.bg != bg || old.colors != colors || old.intensity != intensity;
}

/// Матовое стекло.
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.radius = 24,
    this.blur = 24,
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
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: color ?? vc.glass,
            borderRadius: BorderRadius.circular(radius),
            border: border ? Border.all(color: vc.border) : null,
          ),
          child: child,
        ),
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
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: widget.child,
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

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => context.accent.gradient.createShader(r),
      child: Icon(icon, size: size),
    );
  }
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
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: enabled ? 1 : 0.4,
        child: Container(
          height: 56,
          width: expanded ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 28),
          decoration: BoxDecoration(
            gradient: acc.gradient,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: acc.mid.withValues(alpha: enabled ? 0.45 : 0),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: acc.onAccent,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
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
        borderRadius: BorderRadius.circular(size * 0.32),
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

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.accent.mid;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final t = (_c.value - i * 0.16) % 1.0;
          final bounce = t < 0.5 ? sin(t * 2 * pi).clamp(0.0, 1.0) : 0.0;
          return Container(
            margin: EdgeInsets.symmetric(horizontal: widget.size * 0.25),
            width: widget.size,
            height: widget.size,
            transform: Matrix4.translationValues(0, -bounce * widget.size * 0.8, 0),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.4 + 0.6 * bounce),
              shape: BoxShape.circle,
            ),
          );
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
    return Pressable(
      scale: 0.9,
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: 50,
        height: 30,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          gradient: value ? acc.gradient : null,
          color: value ? null : vc.elevated,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: value ? Colors.transparent : vc.border),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutBack,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 6)],
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
      duration: Duration(milliseconds: 500 + (delay * 1000).round()),
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
      duration: const Duration(milliseconds: 500),
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
