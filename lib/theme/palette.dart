import 'package:flutter/material.dart';

/// Акцентная палитра — пользователь выбирает её в настройках.
class Accent {
  const Accent(this.name, this.a, this.b, {this.onAccent = Colors.white});

  final String name;
  final Color a;
  final Color b;

  /// Цвет текста поверх градиента.
  final Color onAccent;

  LinearGradient get gradient =>
      LinearGradient(colors: [a, b], begin: Alignment.topLeft, end: Alignment.bottomRight);

  Color get mid => Color.lerp(a, b, 0.5)!;
}

const accents = <Accent>[
  Accent('Аврора', Color(0xFF7C5CFF), Color(0xFF00C2FF)),
  Accent('Закат', Color(0xFFFF4F8B), Color(0xFFFFA45C)),
  Accent('Мята', Color(0xFF00C896), Color(0xFF0098E6)),
  Accent('Лава', Color(0xFFFF3D5A), Color(0xFFFF8A00)),
  Accent('Неон', Color(0xFFB6FF3B), Color(0xFF00F5C4), onAccent: Color(0xFF0B140A)),
  Accent('Лёд', Color(0xFFA6C8FF), Color(0xFFE2D1FF), onAccent: Color(0xFF16162A)),
];

/// Цвета для отдельного чата: общая палитра и ещё несколько.
const chatAccents = <Accent>[
  ...accents,
  Accent('Роза', Color(0xFFFF6FA8), Color(0xFF8E5CFF)),
  Accent('Океан', Color(0xFF3A5BFF), Color(0xFF00C2FF)),
  Accent('Солнце', Color(0xFFFFB300), Color(0xFFFF5F6D), onAccent: Color(0xFF221500)),
  Accent('Лес', Color(0xFF2E8B57), Color(0xFF9ACD32)),
  Accent('Графит', Color(0xFF5B6270), Color(0xFF2B2F38)),
];

/// Цвета поверхностей для тёмной и светлой темы.
class VeilColors {
  const VeilColors({
    required this.dark,
    required this.bg,
    required this.surface,
    required this.elevated,
    required this.border,
    required this.text,
    required this.textDim,
    required this.textFaint,
    required this.bubbleIn,
    required this.glass,
    required this.panel,
  });

  final bool dark;
  final Color bg;
  final Color surface;
  final Color elevated;
  final Color border;
  final Color text;
  final Color textDim;
  final Color textFaint;
  final Color bubbleIn;
  final Color glass;

  /// Матовая панель без размытия.
  final Color panel;

  static const danger = Color(0xFFFF4D6A);
  static const success = Color(0xFF2BD99F);
  static const warning = Color(0xFFFFC145);

  static const darkColors = VeilColors(
    dark: true,
    bg: Color(0xFF09090E),
    surface: Color(0xFF12121A),
    elevated: Color(0xFF1B1B26),
    border: Color(0x17FFFFFF),
    text: Color(0xFFF4F4F8),
    textDim: Color(0xFF9B9BB0),
    textFaint: Color(0xFF5D5D70),
    bubbleIn: Color(0xFF1C1C28),
    glass: Color(0xA6121219),
    panel: Color(0xE6181822),
  );

  /// «Ультра»: настоящий чёрный — на AMOLED-экране чёрные точки не светятся
  /// и не тратят батарею.
  static const amoledColors = VeilColors(
    dark: true,
    bg: Color(0xFF000000),
    surface: Color(0xFF0A0A0E),
    elevated: Color(0xFF131318),
    border: Color(0x14FFFFFF),
    text: Color(0xFFE9E9EF),
    textDim: Color(0xFF8E8EA0),
    textFaint: Color(0xFF55555F),
    bubbleIn: Color(0xFF111116),
    glass: Color(0xF0000000),
    panel: Color(0xF2050507),
  );

  static const lightColors = VeilColors(
    dark: false,
    bg: Color(0xFFF4F4F9),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFEAEAF2),
    border: Color(0x14000000),
    text: Color(0xFF0F0F18),
    textDim: Color(0xFF686880),
    textFaint: Color(0xFFA3A3B5),
    bubbleIn: Color(0xFFFFFFFF),
    glass: Color(0xB8FFFFFF),
    panel: Color(0xEBFFFFFF),
  );
}

/// Палитры для аватарок.
const avatarGradients = <List<Color>>[
  [Color(0xFFFF8A65), Color(0xFFFF4F8B)],
  [Color(0xFF7C5CFF), Color(0xFF00C2FF)],
  [Color(0xFF00C896), Color(0xFF7CE38B)],
  [Color(0xFFFFC145), Color(0xFFFF7A45)],
  [Color(0xFFB06AB3), Color(0xFF4568DC)],
  [Color(0xFF43CEA2), Color(0xFF185A9D)],
  [Color(0xFFF953C6), Color(0xFFB91D73)],
  [Color(0xFF2C3E50), Color(0xFF4CA1AF)],
];

const avatarEmojis = [
  '🦊',
  '🐺',
  '🐼',
  '🐙',
  '🦄',
  '🐸',
  '🐧',
  '🦉',
  '🐯',
  '🐨',
  '🦋',
  '🐳',
  '👾',
  '🤖',
  '👻',
  '🌚',
  '🔥',
  '🌸',
  '🍄',
  '🍕',
  '🎧',
  '🚀',
  '⚡',
  '🌈',
];
