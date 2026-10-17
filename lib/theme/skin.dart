import 'package:flutter/material.dart';

import 'palette.dart';

/// Стиль всего приложения: не только цвета, но и формы, обводки, шрифт,
/// фон и характер анимаций.
///
///   0 «Veil» — классический (сияние, стекло);
///   1 «Терминал» — тёмный, строгий, моноширинный, резкие быстрые анимации;
///   2 «Космос» — звёзды, туманность и чёрная дыра, плавные «невесомые» анимации;
///   3 «Лимонад» — светлый и тёплый, мягкие формы, пружинистые анимации.
///
/// У каждого стиля свои мелкие настройки ([opts], ключи — см. [Skin.options]).
class Skin {
  const Skin._({
    required this.id,
    required this.colors,
    required this.accent,
    required this.radius,
    required this.avatarRadius,
    required this.border,
    required this.speed,
    required this.press,
    required this.appear,
    this.font,
    this.monoMessages = false,
    this.glow = false,
    this.shadow = false,
    this.outlineMine = false,
    required this.opts,
  });

  final int id;

  /// null — цвета/акцент из обычных настроек (классический стиль).
  final VeilColors? colors;
  final Accent? accent;

  /// Множитель скруглений: панели, кнопки, пузыри.
  final double radius;

  /// Скругление аватарки (доля размера): 0.5 — круг.
  final double avatarRadius;

  /// Толщина обводок панелей.
  final double border;

  /// Темп анимаций (больше — медленнее).
  final double speed;

  /// Насколько «вжимаются» кнопки при нажатии (1 — как в классике).
  final double press;

  /// Как появляются новые сообщения.
  final Appear appear;

  /// Шрифт всего приложения (null — системный).
  final String? font;

  /// Моноширинный только в сообщениях.
  final bool monoMessages;

  /// Свечение вокруг акцентных элементов (Космос).
  final bool glow;

  /// Мягкие тени под панелями (Лимонад).
  final bool shadow;

  /// Свои сообщения — контуром, а не заливкой (Терминал).
  final bool outlineMine;

  final Map<String, int> opts;

  int opt(String k) => opts[k] ?? 0;

  static const names = ['Veil', 'Терминал', 'Космос', 'Лимонад'];
  static const hints = [
    'Сияние и матовое стекло',
    'Тёмный и строгий: моноширинный шрифт, чёткие линии',
    'Звёзды, туманность и чёрная дыра',
    'Светлый и тёплый, мягкие формы',
  ];

  /// Мелкие настройки каждого стиля.
  static const options = <int, List<SkinOption>>{
    1: [
      SkinOption(
        'tc',
        'Цвет',
        Icons.palette_rounded,
        ['Зелёный', 'Янтарный', 'Циан'],
        ['Как на старых мониторах', 'Тёплый янтарный экран', 'Холодный ночной неон'],
      ),
      SkinOption(
        'tb',
        'Фон',
        Icons.grid_4x4_rounded,
        ['Сетка', 'Код', 'Чистый'],
        ['Точечная сетка и бегущая строка', 'Силуэт кода и бегущая строка', 'Только тёмный фон'],
      ),
      SkinOption(
        'tf',
        'Моноширинный шрифт',
        Icons.text_fields_rounded,
        ['Везде', 'В сообщениях'],
        ['Во всём приложении', 'Только в переписке'],
      ),
    ],
    2: [
      SkinOption(
        'cn',
        'Туманность',
        Icons.blur_on_rounded,
        ['Фиолетовая', 'Синяя', 'Алая'],
        ['Фиолетовая с розовым', 'Синяя с бирюзой', 'Алая с золотом'],
      ),
      SkinOption(
        'ch',
        'Чёрная дыра',
        Icons.lens_blur_rounded,
        ['Есть', 'Нет'],
        ['С аккреционным диском и кольцом света', 'Только звёзды и туманность'],
      ),
      SkinOption(
        'cs',
        'Звёзды',
        Icons.auto_awesome_rounded,
        ['Мало', 'Средне', 'Много'],
        ['Тихое небо', 'Как за городом', 'Млечный Путь'],
      ),
    ],
    3: [
      SkinOption(
        'lt',
        'Вкус',
        Icons.local_drink_rounded,
        ['Лимон', 'Арбуз', 'Мята'],
        ['Солнечный жёлтый', 'Розовый с персиком', 'Свежий зелёный'],
      ),
      SkinOption(
        'lb',
        'Фон',
        Icons.bubble_chart_rounded,
        ['Пятна', 'Горошек', 'Чистый'],
        ['Мягкие цветные пятна', 'Аккуратный горошек', 'Только светлый фон'],
      ),
      SkinOption(
        'la',
        'Движения',
        Icons.waves_rounded,
        ['Мягкие', 'Пружинистые'],
        ['Плавно и спокойно', 'С лёгким отскоком'],
      ),
    ],
  };

  static const classic = Skin._(
    id: 0,
    colors: null,
    accent: null,
    radius: 1,
    avatarRadius: 0.5,
    border: 1,
    speed: 1,
    press: 1,
    appear: Appear.rise,
    opts: {},
  );

  static Skin of(int id, Map<String, int> opts) {
    int o(String k) => opts[k] ?? 0;
    switch (id) {
      case 1:
        const accents = [
          Accent('Зелёный', Color(0xFF3DFF9A), Color(0xFF00C9A7), onAccent: Color(0xFF03130B)),
          Accent('Янтарный', Color(0xFFFFB627), Color(0xFFFF7A1A), onAccent: Color(0xFF1C0F00)),
          Accent('Циан', Color(0xFF2CE5FF), Color(0xFF4D8BFF), onAccent: Color(0xFF02101A)),
        ];
        return Skin._(
          id: 1,
          colors: _terminal,
          accent: accents[o('tc').clamp(0, 2)],
          radius: 0.28,
          avatarRadius: 0.16,
          border: 1,
          speed: 0.65,
          press: 0.4,
          appear: Appear.type,
          font: o('tf') == 0 ? 'monospace' : null,
          monoMessages: true,
          outlineMine: true,
          opts: opts,
        );
      case 2:
        const accents = [
          Accent('Фиолетовая', Color(0xFF8B5CFF), Color(0xFFFF5CC8)),
          Accent('Синяя', Color(0xFF3D7BFF), Color(0xFF22E1FF)),
          Accent('Алая', Color(0xFFFF4D6D), Color(0xFFFF9E3D)),
        ];
        return Skin._(
          id: 2,
          colors: _cosmos,
          accent: accents[o('cn').clamp(0, 2)],
          radius: 1.15,
          avatarRadius: 0.5,
          border: 1,
          speed: 1.35,
          press: 0.8,
          appear: Appear.float,
          glow: true,
          opts: opts,
        );
      case 3:
        const accents = [
          Accent('Лимон', Color(0xFFFFC93C), Color(0xFFFF8A3D), onAccent: Color(0xFF3A2400)),
          Accent('Арбуз', Color(0xFFFF5E7E), Color(0xFFFF9A6B)),
          Accent('Мята', Color(0xFF2FCB98), Color(0xFF1FA8D8)),
        ];
        return Skin._(
          id: 3,
          colors: _lemonade,
          accent: accents[o('lt').clamp(0, 2)],
          radius: 1.3,
          avatarRadius: 0.36,
          border: 0,
          speed: 1,
          press: 1.6,
          appear: o('la') == 1 ? Appear.bounce : Appear.pop,
          shadow: true,
          opts: opts,
        );
      default:
        return classic;
    }
  }

  static const _terminal = VeilColors(
    dark: true,
    bg: Color(0xFF07090A),
    surface: Color(0xFF0D1112),
    elevated: Color(0xFF141A1B),
    border: Color(0x2E9FD8C0),
    text: Color(0xFFDDE7E2),
    textDim: Color(0xFF889A92),
    textFaint: Color(0xFF4F5E58),
    bubbleIn: Color(0xFF0E1314),
    glass: Color(0xE607090A),
    panel: Color(0xF00B0F10),
  );

  static const _cosmos = VeilColors(
    dark: true,
    bg: Color(0xFF03030A),
    surface: Color(0xFF0B0B19),
    elevated: Color(0xFF141429),
    border: Color(0x26A9B4FF),
    text: Color(0xFFEDECFF),
    textDim: Color(0xFF9C9BC6),
    textFaint: Color(0xFF5D5C88),
    bubbleIn: Color(0xFF12122A),
    glass: Color(0xB30A0A18),
    panel: Color(0xE00C0C1C),
  );

  static const _lemonade = VeilColors(
    dark: false,
    bg: Color(0xFFFFF8EC),
    surface: Color(0xFFFFFFFF),
    elevated: Color(0xFFFFF0D6),
    border: Color(0x14603A00),
    text: Color(0xFF2B2118),
    textDim: Color(0xFF7D6B57),
    textFaint: Color(0xFFB8A790),
    bubbleIn: Color(0xFFFFFFFF),
    glass: Color(0xD9FFFFFF),
    panel: Color(0xF2FFFFFF),
  );

  /// Кривая «обычного» движения для стиля.
  Curve get curve => switch (id) {
    1 => Curves.easeOutQuart,
    2 => Curves.easeInOutCubic,
    3 => Curves.easeOutBack,
    _ => Curves.easeOutCubic,
  };
}

/// Мелкая настройка стиля: ключ в настройках, название, значок, варианты и
/// подсказки к ним.
class SkinOption {
  const SkinOption(this.key, this.title, this.icon, this.labels, this.hints);

  final String key;
  final String title;
  final IconData icon;
  final List<String> labels;
  final List<String> hints;
}

/// Как появляется новое сообщение.
enum Appear {
  /// Классика: снизу с лёгким увеличением.
  rise,

  /// Терминал: «печатается» слева направо, быстро.
  type,

  /// Космос: медленно всплывает из глубины.
  float,

  /// Лимонад: мягкий «поп».
  pop,

  /// Лимонад, пружинистые: «поп» с отскоком.
  bounce,
}
