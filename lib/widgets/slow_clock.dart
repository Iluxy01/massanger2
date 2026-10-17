import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Активность пользователя и приложения — общая для всех [SlowClock].
class Activity {
  Activity._();

  static DateTime _last = DateTime.now();
  static bool _resumed = true;

  /// Меняется, когда часам пора проверить, не проснуться ли (касание после
  /// паузы, возврат приложения) или не уснуть ли (приложение свёрнуто).
  static final changes = ValueNotifier<int>(0);

  /// Приложение на экране.
  static bool get resumed => _resumed;

  /// Сколько времени никто не трогал экран.
  static Duration get idle => DateTime.now().difference(_last);

  /// Касание, прокрутка, ввод — «пользователь здесь».
  static void poke() {
    final now = DateTime.now();
    final gap = now.difference(_last);
    _last = now;
    if (gap > const Duration(milliseconds: 900)) changes.value++;
  }

  static void setResumed(bool v) {
    if (_resumed == v) return;
    _resumed = v;
    if (v) _last = DateTime.now();
    changes.value++;
  }
}

/// Часы для декоративных анимаций (живой фон, «печатает…»).
///
/// Тикают обычным таймером с небольшой частотой кадров, а не на каждом кадре
/// экрана: на 120 Гц это в 4–6 раз меньше перерисовок. Стоят, когда виджет
/// скрыт (другая вкладка, перекрыт экраном), когда приложение свёрнуто, и — если
/// задан [idle] — когда экран давно никто не трогал. Значение — фаза 0…1.
class SlowClock extends ValueNotifier<double> {
  SlowClock({double start = 0}) : super(start) {
    _start = start;
    Activity.changes.addListener(sync);
  }

  /// Нужна ли анимация вообще (по настройкам).
  bool wanted = false;

  /// Кадров в секунду.
  int fps = 24;

  /// Длина цикла.
  Duration period = const Duration(seconds: 60);

  /// Засыпать, если экран не трогали дольше этого (null — не засыпать).
  Duration? idle;

  /// Сообщает, когда часы пошли или встали.
  final running = ValueNotifier<bool>(false);

  late double _start;
  Timer? _timer;
  int _timerFps = 0;
  final _watch = Stopwatch();
  ValueListenable<TickerModeData>? _mode;
  bool _visible = true;
  bool _disposed = false;

  /// Подключить к видимости виджета (TickerMode) — из didChangeDependencies.
  void attach(BuildContext context) {
    final m = TickerMode.getValuesNotifier(context);
    if (!identical(m, _mode)) {
      _mode?.removeListener(_onMode);
      _mode = m..addListener(_onMode);
      _visible = m.value.enabled;
    }
    sync();
  }

  void _onMode() {
    _visible = _mode?.value.enabled ?? true;
    sync();
  }

  bool get _awake => idle == null || Activity.idle < idle!;

  /// Пересчитать, должны ли часы идти.
  void sync() {
    if (_disposed) return;
    final go = wanted && _visible && Activity.resumed && _awake;
    if (go && (_timer == null || _timerFps != fps)) {
      _timer?.cancel();
      _watch.start();
      _timerFps = fps;
      _timer = Timer.periodic(Duration(microseconds: 1000000 ~/ fps), _tick);
    } else if (!go && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _watch.stop();
    }
    running.value = _timer != null;
  }

  void _tick(Timer _) {
    if (!_awake) {
      sync();
      return;
    }
    final p = period.inMicroseconds;
    value = ((_start * p + _watch.elapsedMicroseconds) % p) / p;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _mode?.removeListener(_onMode);
    Activity.changes.removeListener(sync);
    running.dispose();
    super.dispose();
  }
}
