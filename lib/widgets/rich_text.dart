import 'package:flutter/material.dart';

/// Оформление текста в сообщениях (как в мессенджерах):
/// *жирный*, _курсив_, ~зачёркнутый~, `моноширинный`, ||скрытый||.
///
/// Маркер открывается в начале слова и закрывается в конце (`2*3*4` не
/// превратится в жирный). Вложенность не поддерживается — и не нужна.
class Fmt {
  static final _re = RegExp(
    r'\|\|(.+?)\|\|'
    r'|(?<![^\s(«"\[])\*(?=\S)(.+?)(?<=\S)\*(?![^\s.,!?:;)»"\]])'
    r'|(?<![^\s(«"\[])_(?=\S)(.+?)(?<=\S)_(?![^\s.,!?:;)»"\]])'
    r'|(?<![^\s(«"\[])~(?=\S)(.+?)(?<=\S)~(?![^\s.,!?:;)»"\]])'
    r'|`([^`\n]+)`',
  );

  /// Есть ли в тексте оформление (иначе — обычный Text, без лишней работы).
  static bool has(String text) => _re.hasMatch(text);

  /// Есть ли скрытый текст (||…||) — тогда касание открывает его.
  static bool hasSpoiler(String text) =>
      text.contains('||') && _re.allMatches(text).any((m) => m.group(1) != null);

  /// Текст без маркеров (для списка чатов и уведомлений).
  static String plain(String text) => text.replaceAllMapped(_re, (m) {
    if (m.group(1) != null) return '░' * m.group(1)!.length.clamp(1, 12);
    return m.group(2) ?? m.group(3) ?? m.group(4) ?? m.group(5) ?? '';
  });

  /// Куски текста со стилями. [reveal] — показать скрытое.
  static List<InlineSpan> spans(String text, TextStyle base, {required bool reveal}) {
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _re.allMatches(text)) {
      if (m.start > at) out.add(TextSpan(text: text.substring(at, m.start)));
      final color = base.color ?? Colors.white;
      if (m.group(1) != null) {
        out.add(
          TextSpan(
            text: m.group(1),
            style: reveal
                ? TextStyle(background: Paint()..color = color.withValues(alpha: 0.12))
                : TextStyle(
                    color: Colors.transparent,
                    background: Paint()..color = color.withValues(alpha: 0.35),
                  ),
          ),
        );
      } else if (m.group(2) != null) {
        out.add(
          TextSpan(
            text: m.group(2),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      } else if (m.group(3) != null) {
        out.add(
          TextSpan(
            text: m.group(3),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      } else if (m.group(4) != null) {
        out.add(
          TextSpan(
            text: m.group(4),
            style: const TextStyle(decoration: TextDecoration.lineThrough),
          ),
        );
      } else {
        out.add(
          TextSpan(
            text: m.group(5),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: (base.fontSize ?? 16) * 0.92,
              background: Paint()..color = color.withValues(alpha: 0.1),
            ),
          ),
        );
      }
      at = m.end;
    }
    if (at < text.length) out.add(TextSpan(text: text.substring(at)));
    return out;
  }
}
