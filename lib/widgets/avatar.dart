import 'dart:math';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../utils.dart';
import 'visual.dart';

/// Аватар-эмодзи на градиенте. Опционально — градиентное кольцо и точка «в сети».
///
/// Постоянных анимаций нет: они заставляли перерисовывать экран каждый кадр
/// (нагрев). Точка «в сети» один раз мягко «пульсирует» при появлении.
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
      // Свой DefaultTextStyle: во время перелёта (Hero) над аватаркой нет Material,
      // и без этого эмодзи рисовалось с отладочным жёлтым двойным подчёркиванием.
      child: DefaultTextStyle(
        style: const TextStyle(decoration: TextDecoration.none, color: Colors.white),
        child: Text(emoji, style: TextStyle(fontSize: size * 0.48, height: 1.15)),
      ),
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

class _StoryRing extends StatelessWidget {
  const _StoryRing({required this.colors});
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: SweepGradient(colors: [acc.a, acc.b, colors.last, acc.a]),
      ),
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(shape: BoxShape.circle, color: context.vc.bg),
      ),
    );
  }
}

class _OnlineDot extends StatelessWidget {
  const _OnlineDot({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    final s = size;
    final dot = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: VeilColors.success,
        border: Border.all(color: context.vc.bg, width: s * 0.18),
      ),
    );
    // Одна мягкая волна при появлении — и всё, дальше точка статична.
    return SizedBox(
      width: s,
      height: s,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 900).by(context),
        curve: Curves.easeOut,
        builder: (_, t, child) => Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (t < 1)
              Container(
                width: s * (1 + t * 0.9),
                height: s * (1 + t * 0.9),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: VeilColors.success.withValues(alpha: 0.45 * (1 - t)),
                ),
              ),
            child!,
          ],
        ),
        child: dot,
      ),
    );
  }
}

/// Галочки статуса (как в Telegram):
///   ⏱ отправляется · ✓ бледная — у ретрансляторов · ✓ яркая — доставлено другу
///   · ✓✓ — прочитано.
class StatusTicks extends StatelessWidget {
  const StatusTicks({super.key, required this.status, this.color, this.size = 15});

  final MsgStatus status;

  /// Цвет на своём градиентном пузыре; null — в списке чатов.
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final onBubble = color != null;
    final vc = context.vc;
    final dim = onBubble ? Colors.white.withValues(alpha: 0.55) : vc.textFaint;
    final bright = onBubble ? Colors.white : vc.textDim;
    final read = onBubble ? Colors.white : context.accent.b;
    final Widget icon = switch (status) {
      MsgStatus.sending => Icon(Icons.schedule_rounded, size: size - 2, color: dim),
      MsgStatus.sent => Icon(Icons.done_rounded, size: size, color: dim),
      MsgStatus.delivered => Icon(Icons.done_rounded, size: size, color: bright),
      MsgStatus.read => Icon(Icons.done_all_rounded, size: size, color: read),
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260).by(context),
      switchInCurve: Curves.easeOutBack,
      transitionBuilder: (child, a) => ScaleTransition(
        scale: a,
        child: FadeTransition(opacity: a, child: child),
      ),
      child: KeyedSubtree(key: ValueKey(status), child: icon),
    );
  }
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
