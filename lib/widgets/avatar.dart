import 'dart:math';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../utils.dart';

/// Аватар-эмодзи на градиенте. Опционально — вращающееся «сторис»-кольцо
/// и пульсирующая точка «в сети».
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.emoji,
    required this.colors,
    this.size = 52,
    this.online = false,
    this.ring = false,
  });

  factory Avatar.contact(
    Contact c, {
    double size = 52,
    bool ring = false,
    bool showOnline = true,
  }) => Avatar(
    emoji: c.emoji,
    colors: c.colors,
    size: size,
    online: showOnline && c.online,
    ring: ring && c.hasStory,
  );

  final String emoji;
  final List<Color> colors;
  final double size;
  final bool online;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final core = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Text(emoji, style: TextStyle(fontSize: size * 0.48, height: 1.15)),
    );

    final dot = size * 0.26;
    return SizedBox(
      width: size + (ring ? 8 : 0),
      height: size + (ring ? 8 : 0),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          if (ring) Positioned.fill(child: _StoryRing(colors: colors)),
          core,
          if (online)
            Positioned(
              right: ring ? 3 : 0,
              bottom: ring ? 3 : 0,
              child: _OnlineDot(size: dot.clamp(10, 18)),
            ),
        ],
      ),
    );
  }
}

class _StoryRing extends StatefulWidget {
  const _StoryRing({required this.colors});
  final List<Color> colors;

  @override
  State<_StoryRing> createState() => _StoryRingState();
}

class _StoryRingState extends State<_StoryRing> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 6))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final vc = context.vc;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: SweepGradient(
            colors: [acc.a, acc.b, widget.colors.last, acc.a],
            transform: GradientRotation(_c.value * 2 * pi),
          ),
        ),
        padding: const EdgeInsets.all(2),
        child: Container(
          decoration: BoxDecoration(shape: BoxShape.circle, color: vc.bg),
        ),
      ),
    );
  }
}

class _OnlineDot extends StatefulWidget {
  const _OnlineDot({required this.size});
  final double size;

  @override
  State<_OnlineDot> createState() => _OnlineDotState();
}

class _OnlineDotState extends State<_OnlineDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) => Container(
              width: s * (1 + _c.value * 0.9),
              height: s * (1 + _c.value * 0.9),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: VeilColors.success.withValues(alpha: 0.45 * (1 - _c.value)),
              ),
            ),
          ),
          Container(
            width: s,
            height: s,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: VeilColors.success,
              border: Border.all(color: context.vc.bg, width: s * 0.18),
            ),
          ),
        ],
      ),
    );
  }
}

/// Галочки статуса: часики → ✓ → ✓✓ → ✓✓ в цвете акцента.
class StatusTicks extends StatelessWidget {
  const StatusTicks({super.key, required this.status, this.color, this.size = 15});

  final MsgStatus status;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final base = color ?? context.vc.textFaint;
    final readColor = context.accent.b;
    final Widget icon = switch (status) {
      MsgStatus.sending => _SpinningClock(size: size - 2, color: base),
      MsgStatus.sent => Icon(Icons.done_rounded, size: size, color: base),
      MsgStatus.delivered => Icon(Icons.done_all_rounded, size: size, color: base),
      MsgStatus.read => Icon(
        Icons.done_all_rounded,
        size: size,
        color: color != null ? Colors.white : readColor,
      ),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      transitionBuilder: (child, a) => ScaleTransition(
        scale: CurvedAnimation(parent: a, curve: Curves.easeOutBack),
        child: FadeTransition(opacity: a, child: child),
      ),
      child: KeyedSubtree(key: ValueKey(status), child: icon),
    );
  }
}

class _SpinningClock extends StatefulWidget {
  const _SpinningClock({required this.size, required this.color});
  final double size;
  final Color color;

  @override
  State<_SpinningClock> createState() => _SpinningClockState();
}

class _SpinningClockState extends State<_SpinningClock> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _c,
    child: Icon(Icons.schedule_rounded, size: widget.size, color: widget.color),
  );
}

/// Визуальный отпечаток ключа (симметричный «идентикон»).
/// Если у вас и у друга картинки совпадают — соединение не подменено.
class KeyIdenticon extends StatelessWidget {
  const KeyIdenticon({super.key, required this.seed, this.size = 72, this.cells = 7});

  final String seed;
  final double size;
  final int cells;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final r = Random(fnv1a(seed));
    final half = (cells + 1) ~/ 2;
    final grid = List.generate(cells, (_) => List.generate(half, (_) => r.nextDouble()));
    final cell = size / cells;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: context.vc.elevated,
        borderRadius: BorderRadius.circular(size * 0.2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          for (var y = 0; y < cells; y++)
            for (var x = 0; x < cells; x++)
              if (grid[y][x < half ? x : cells - 1 - x] > 0.48)
                Positioned(
                  left: x * cell,
                  top: y * cell,
                  width: cell,
                  height: cell,
                  child: Padding(
                    padding: EdgeInsets.all(cell * 0.08),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(cell * 0.3),
                        color: Color.lerp(
                          acc.a,
                          acc.b,
                          (x + y) / (cells * 2 - 2),
                        )!.withValues(alpha: 0.55 + 0.45 * grid[y][x < half ? x : cells - 1 - x]),
                      ),
                    ),
                  ),
                ),
        ],
      ),
    );
  }
}
