import 'package:flutter/widgets.dart';

/// Уровень оформления: сколько «тяжёлых» эффектов рисовать.
///   0 — минимум: чистый фон без сияния, без размытия (меньше всего греет);
///   1 — баланс (по умолчанию);
///   2 — максимум: живое сияние на фоне и матовое стекло на всех панелях.
const lookLevels = ['Минимум', 'Баланс', 'Максимум'];

/// Уровень анимаций: 0 — выключены, 1 — быстрые, 2 — обычные, 3 — плавные.
const motionLevels = ['Выкл', 'Быстрые', 'Обычные', 'Плавные'];
const _motionScale = [0.0, 0.6, 1.0, 1.4];

/// Настройки визуала для всего дерева. Перерисовывает только тех, кто от них
/// зависит, и только когда уровень действительно меняется.
class Visual extends InheritedWidget {
  const Visual({super.key, this.look = 1, this.motion = 2, required super.child});

  final int look;
  final int motion;

  static const _fallback = Visual(child: SizedBox.shrink());

  static Visual of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<Visual>() ?? _fallback;

  double get motionScale => _motionScale[motion.clamp(0, _motionScale.length - 1)];

  @override
  bool updateShouldNotify(Visual old) => old.look != look || old.motion != motion;
}

extension VisualContext on BuildContext {
  Visual get visual => Visual.of(this);
}

extension MotionDuration on Duration {
  /// Длительность анимации с учётом выбранного уровня анимаций.
  Duration by(BuildContext context) {
    final k = Visual.of(context).motionScale;
    if (k == 1) return this;
    // «Без анимаций» — 1 мс, а не ноль: на глаз мгновенно, а AnimatedSize и
    // подобные не завершаются синхронно посреди раскладки.
    if (k == 0) return const Duration(milliseconds: 1);
    return Duration(microseconds: (inMicroseconds * k).round());
  }
}
