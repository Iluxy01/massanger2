import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Связь с Android-частью «мгновенных уведомлений».
///
/// Во сне телефон не выполняет таймеры приложения: приходящее сообщение или
/// оборванное соединение будят его лишь на мгновение. Пока переподключаемся и
/// забираем новое, просим Android ненадолго не засыпать ([hold]) и отпускаем,
/// как только закончили ([release]). Будильник службы и смена сети приходят
/// сюда «тиками» ([onTick]).
class Link {
  Link._();

  static const _ch = MethodChannel('veil/link');
  static DateTime _heldTill = DateTime(2000);

  /// Не засыпать [d] (Android сам отпустит по сроку). Частые вызовы подряд
  /// не дёргают систему: продлеваем, только когда половина срока прошла.
  static void hold([Duration d = const Duration(seconds: 10)]) {
    final now = DateTime.now();
    if (_heldTill.difference(now) > d ~/ 2) return;
    _heldTill = now.add(d);
    _call('hold', d.inMilliseconds);
  }

  static void release() {
    if (_heldTill.isBefore(DateTime.now())) return;
    _heldTill = DateTime(2000);
    _call('release');
  }

  /// Будильник службы или смена сети: [handler] проверяет связь.
  static void onTick(Future<void> Function(String reason) handler) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'tick') await handler('${call.arguments ?? ''}');
      return null;
    });
  }

  /// Состояние фоновой работы: разрешено ли «без ограничений батареи» и
  /// запущена ли служба. null — не Android (или не получилось спросить).
  static Future<({bool unrestricted, bool running})?> status() async {
    try {
      final m = await _ch.invokeMapMethod<String, Object?>('status');
      if (m == null) return null;
      return (unrestricted: m['unrestricted'] == true, running: m['running'] == true);
    } catch (_) {
      return null;
    }
  }

  /// Попросить Android не ограничивать Veil в фоне (системное окно).
  static Future<bool> askUnrestricted() async {
    try {
      return await _ch.invokeMethod<bool>('askUnrestricted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Причина прошлого вылета Android-части (null — не падал). Читается один раз.
  static Future<String?> lastCrash() async {
    try {
      return await _ch.invokeMethod<String>('lastCrash');
    } catch (_) {
      return null;
    }
  }

  /// События Android-части (служба, окно, будильник) с прошлого раза.
  static Future<List<String>> nativeNotes() async {
    try {
      final t = await _ch.invokeMethod<String>('notes');
      return t == null ? const [] : t.split('\n').where((l) => l.trim().isNotEmpty).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Открыть настройки уведомлений Veil в Android.
  static Future<bool> notificationSettings() async {
    try {
      return await _ch.invokeMethod<bool>('notificationSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  static void _call(String method, [Object? arg]) {
    _ch.invokeMethod<void>(method, arg).catchError((Object e) {
      if (e is! MissingPluginException) debugPrint('link: $e');
    });
  }
}
