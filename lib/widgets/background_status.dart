import 'package:flutter/widgets.dart';

import '../core/link.dart';
import '../core/notifier.dart';

/// Что мешает сообщениям приходить, пока Veil закрыт.
class BackgroundState {
  const BackgroundState({required this.notifications, required this.unrestricted});

  /// Уведомления Veil разрешены в Android.
  final bool notifications;

  /// Android не ограничивает Veil в фоне (нет «оптимизации батареи»).
  final bool unrestricted;
}

/// Следит за [BackgroundState] и обновляет его, когда возвращаемся в
/// приложение (например, из системного окна «Разрешить?»). На не-Android и в
/// тестах состояние неизвестно (null).
class BackgroundStatus extends StatefulWidget {
  const BackgroundStatus({super.key, required this.builder});

  final Widget Function(BuildContext context, BackgroundState? state, BackgroundActions act)
  builder;

  @override
  State<BackgroundStatus> createState() => _BackgroundStatusState();
}

/// Что можно сделать: разрешить уведомления, снять ограничения батареи.
class BackgroundActions {
  const BackgroundActions(this.allowNotifications, this.allowBackground);

  final Future<void> Function() allowNotifications;
  final Future<void> Function() allowBackground;
}

class _BackgroundStatusState extends State<BackgroundStatus> {
  BackgroundState? _state;
  late final AppLifecycleListener _life;
  late final _actions = BackgroundActions(_allowNotifications, _allowBackground);

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(onResume: _refresh);
    _refresh();
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final link = await Link.status();
    final notes = await SystemNotify.enabled();
    if (!mounted || link == null || notes == null) return;
    setState(() => _state = BackgroundState(notifications: notes, unrestricted: link.unrestricted));
  }

  Future<void> _allowNotifications() async {
    await SystemNotify.requestPermission();
    await _refresh();
    // Раньше уже отказали — Android больше не спрашивает: открываем настройки.
    if (mounted && _state?.notifications == false) await Link.notificationSettings();
  }

  Future<void> _allowBackground() async {
    await Link.askUnrestricted();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _state, _actions);
}
