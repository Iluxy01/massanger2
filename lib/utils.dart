import 'dart:math';

import 'package:flutter/widgets.dart';

final _rnd = Random.secure();

String randomHex(int len) =>
    List.generate(len, (_) => _rnd.nextInt(16).toRadixString(16)).join().toUpperCase();

String two(int n) => n.toString().padLeft(2, '0');

String fmtTime(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

String fmtDuration(int seconds) => '${seconds ~/ 60}:${two(seconds % 60)}';

const _months = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];
const _weekdays = ['пн', 'вт', 'ср', 'чт', 'пт', 'сб', 'вс'];

DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

bool sameDay(DateTime a, DateTime b) => _day(a) == _day(b);

int _daysAgo(DateTime t) => _day(DateTime.now()).difference(_day(t)).inDays;

/// «Сегодня», «Вчера», «12 октября».
String fmtDay(DateTime t) {
  final d = _daysAgo(t);
  if (d == 0) return 'Сегодня';
  if (d == 1) return 'Вчера';
  return '${t.day} ${_months[t.month - 1]}';
}

/// Короткое время для списка чатов.
String fmtListTime(DateTime t) {
  final d = _daysAgo(t);
  if (d == 0) return fmtTime(t);
  if (d == 1) return 'вчера';
  if (d < 7) return _weekdays[t.weekday - 1];
  return '${two(t.day)}.${two(t.month)}';
}

String fmtLastSeen(DateTime? t) {
  if (t == null) return 'был(а) недавно';
  final m = DateTime.now().difference(t).inMinutes;
  if (m < 1) return 'был(а) только что';
  if (m < 60) return 'был(а) $m мин назад';
  if (_daysAgo(t) == 0) return 'был(а) в ${fmtTime(t)}';
  return 'был(а) ${fmtDay(t).toLowerCase()}';
}

final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// Сообщение из 1–3 эмодзи показываем крупно и без «пузыря».
bool isEmojiOnly(String s) {
  final t = s.trim();
  if (t.isEmpty || t.characters.length > 3) return false;
  return !_letterOrDigit.hasMatch(t) && t.runes.any((r) => r >= 0x2190);
}

/// FNV-1a — стабильный хэш (String.hashCode не гарантирует стабильность).
int fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// «Код безопасности» — 12 групп по 5 цифр, одинаковый у обоих собеседников.
List<String> safetyNumber(String a, String b) {
  final pair = ([a, b]..sort()).join(':');
  var seed = fnv1a(pair);
  final r = Random(seed);
  return List.generate(12, (_) => r.nextInt(100000).toString().padLeft(5, '0'));
}

/// Детерминированная псевдо-волна для голосовых сообщений.
List<double> waveform(String id, int bars) {
  final r = Random(fnv1a(id));
  return List.generate(bars, (i) {
    final base = 0.25 + r.nextDouble() * 0.75;
    final envelope = sin(pi * (i + 1) / (bars + 1));
    return (base * (0.45 + 0.55 * envelope)).clamp(0.15, 1.0);
  });
}
