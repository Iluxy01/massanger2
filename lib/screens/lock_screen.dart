import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/palette.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';

/// PIN-код: разблокировка приложения или установка нового кода.
class LockScreen extends StatefulWidget {
  const LockScreen({
    super.key,
    this.setup = false,
    this.title,
    this.subtitle,
    this.onCreate,
    this.verify,
  });

  /// true — создаём новый PIN (ввод + подтверждение).
  final bool setup;

  /// Свои заголовок и подпись (PIN тайника, «под принуждением»…).
  final String? title;
  final String? subtitle;

  /// Создание своего PIN: вернуть текст ошибки или null, если всё хорошо.
  /// Без него — задаётся основной PIN приложения.
  final Future<String?> Function(String pin)? onCreate;

  /// Своя проверка (например, открыть тайник). Без неё — разблокировка приложения.
  final Future<bool> Function(String pin)? verify;

  static Route<bool> setupRoute({
    String? title,
    String? subtitle,
    Future<String?> Function(String pin)? onCreate,
  }) => _route(LockScreen(setup: true, title: title, subtitle: subtitle, onCreate: onCreate));

  /// Спросить PIN (например, тайника). true — верный.
  static Route<bool> verifyRoute({
    required String title,
    String? subtitle,
    required Future<bool> Function(String pin) verify,
  }) => _route(LockScreen(title: title, subtitle: subtitle, verify: verify));

  static Route<bool> _route(LockScreen screen) => PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 450),
    pageBuilder: (_, _, _) => screen,
    transitionsBuilder: (_, a, _, c) => FadeTransition(
      opacity: a,
      child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(a), child: c),
    ),
  );

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  static const _len = 4;
  String _input = '';
  String? _first;
  int _shake = 0;
  bool _error = false;
  String? _errorText;
  bool _success = false;
  AppLifecycleListener? _life;

  /// Экран блокировки приложения (а не ввод нового или чужого PIN).
  bool get _mainLock => !widget.setup && widget.verify == null;

  @override
  void initState() {
    super.initState();
    if (!_mainLock) return;
    // Отпечаток спрашиваем сразу — и каждый раз, когда возвращаемся в Veil.
    WidgetsBinding.instance.addPostFrameCallback((_) => _bio(auto: true));
    _life = AppLifecycleListener(onResume: () => _bio(auto: true));
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  DateTime _bioEnd = DateTime(2000);
  bool _declined = false;

  /// [auto] — сами, без нажатия. Если отказались («Ввести PIN»), сами больше
  /// не спрашиваем: на части телефонов окно отпечатка «сворачивает» Veil, и
  /// иначе оно открывалось бы снова и снова.
  Future<void> _bio({bool auto = false}) async {
    if (!mounted || _success) return;
    if (auto && (_declined || DateTime.now().difference(_bioEnd).inSeconds < 3)) return;
    final app = context.appRead;
    if (!app.biometric || !app.locked) return;
    final ok = await app.unlockWithBiometric();
    _bioEnd = DateTime.now();
    if (!ok) {
      _declined = true;
      return;
    }
    if (!mounted) return;
    app.tick(HapticKind.medium);
    setState(() => _success = true);
  }

  String get _title {
    if (!widget.setup) return widget.title ?? 'Введите PIN';
    if (_first != null) return 'Повторите PIN';
    return widget.title ?? 'Придумайте PIN';
  }

  void _press(String d) {
    if (_input.length >= _len || _success) return;
    final app = context.appRead;
    app.tick(HapticKind.selection);
    setState(() {
      _error = false;
      _input += d;
    });
    if (_input.length == _len) Future.delayed(const Duration(milliseconds: 160), _check);
  }

  void _backspace() {
    if (_input.isEmpty) return;
    context.appRead.tick(HapticKind.selection);
    setState(() => _input = _input.substring(0, _input.length - 1));
  }

  Future<void> _check() async {
    if (!mounted) return;
    final app = context.appRead;
    if (widget.setup) {
      if (_first == null) {
        setState(() {
          _first = _input;
          _input = '';
        });
      } else if (_first == _input) {
        final create = widget.onCreate;
        final pin = _input;
        if (create != null) {
          final err = await create(pin);
          if (!mounted) return;
          if (err != null) {
            _fail(resetFirst: true, text: err);
            return;
          }
          _ok(() => Navigator.of(context).pop(true));
          return;
        }
        // Основной PIN не должен совпадать с PIN тайника или «под принуждением».
        if (await app.pinTaken(pin)) {
          if (mounted) _fail(resetFirst: true, text: 'Этот PIN уже занят');
          return;
        }
        if (!mounted) return;
        _ok(() {
          app.setPin(pin);
          Navigator.of(context).pop(true);
        });
      } else {
        _fail(resetFirst: true);
      }
      return;
    }
    final verify = widget.verify;
    if (verify != null) {
      if (await verify(_input)) {
        if (mounted) _ok(() => Navigator.of(context).pop(true));
      } else if (mounted) {
        _fail();
      }
      return;
    }
    // Экран блокировки: основной PIN, PIN тайника или «под принуждением».
    if (await app.unlockWith(_input)) {
      if (mounted) setState(() => _success = true);
    } else if (mounted) {
      _fail();
    }
  }

  void _ok(VoidCallback then) {
    context.appRead.tick(HapticKind.medium);
    setState(() => _success = true);
    Future.delayed(const Duration(milliseconds: 380), () {
      if (mounted) then();
    });
  }

  void _fail({bool resetFirst = false, String? text}) {
    context.appRead.tick(HapticKind.heavy);
    setState(() {
      _error = true;
      _errorText = text;
      _shake++;
      _input = '';
      if (resetFirst) _first = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Material(
      color: vc.bg,
      child: AuroraBackground(
        intensity: 1.3,
        child: SafeArea(
          child: Column(
            children: [
              if (widget.setup || widget.verify != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: Icon(Icons.close_rounded, color: vc.text),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ),
              const Spacer(flex: 2),
              AnimatedScale(
                scale: _success ? 1.15 : 1,
                duration: const Duration(milliseconds: 300).by(context),
                curve: Curves.easeOutBack,
                child: VeilLogo(size: 64, glow: _success),
              ),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250).by(context),
                child: Text(
                  _error
                      ? (_errorText ?? (widget.setup ? 'Не совпадает, ещё раз' : 'Неверный PIN'))
                      : _title,
                  key: ValueKey('$_title$_error'),
                  style: TextStyle(
                    color: _error ? VeilColors.danger : vc.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                widget.subtitle ??
                    (widget.setup
                        ? 'Код защищает переписку на этом устройстве'
                        : 'Veil заблокирован'),
                textAlign: TextAlign.center,
                style: TextStyle(color: vc.textDim, fontSize: 14),
              ),
              const SizedBox(height: 32),
              Shake(
                trigger: _shake,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_len, (i) {
                    final filled = i < _input.length || _success;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 220).by(context),
                      curve: Curves.easeOutBack,
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      width: filled ? 18 : 14,
                      height: filled ? 18 : 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: filled && !_error ? acc.gradient : null,
                        color: _error
                            ? VeilColors.danger
                            : filled
                            ? null
                            : Colors.transparent,
                        border: Border.all(
                          color: _error ? VeilColors.danger : vc.textDim,
                          width: filled ? 0 : 1.6,
                        ),
                        boxShadow: filled && !_error
                            ? [BoxShadow(color: acc.mid.withValues(alpha: 0.6), blurRadius: 12)]
                            : null,
                      ),
                    );
                  }),
                ),
              ),
              const Spacer(flex: 2),
              _Keypad(
                onDigit: _press,
                onBackspace: _backspace,
                onBio: _mainLock && context.app.biometric ? _bio : null,
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace, this.onBio});

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  /// Войти по отпечатку / лицу (если включено).
  final VoidCallback? onBio;

  static const _letters = {
    '2': 'ABC',
    '3': 'DEF',
    '4': 'GHI',
    '5': 'JKL',
    '6': 'MNO',
    '7': 'PQRS',
    '8': 'TUV',
    '9': 'WXYZ',
    '0': '+',
  };

  @override
  Widget build(BuildContext context) {
    Widget key(String d) => _Key(digit: d, letters: _letters[d] ?? '', onTap: () => onDigit(d));
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
    ];
    return Column(
      children: [
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [for (final d in r) key(d)],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 108,
                child: onBio == null
                    ? null
                    // Без tooltip: экран блокировки лежит над навигатором, и
                    // всплывающей подсказке там негде показаться.
                    : IconButton(
                        onPressed: onBio,
                        icon: const GradientIcon(Icons.fingerprint_rounded, size: 34),
                      ),
              ),
              key('0'),
              SizedBox(
                width: 108,
                child: IconButton(
                  onPressed: onBackspace,
                  icon: Icon(Icons.backspace_outlined, color: context.vc.textDim),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({required this.digit, required this.letters, required this.onTap});

  final String digit;
  final String letters;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Pressable(
        scale: 0.86,
        haptic: false,
        onTap: onTap,
        child: Glass(
          radius: 38,
          child: SizedBox(
            width: 76,
            height: 76,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  digit,
                  style: TextStyle(color: vc.text, fontSize: 30, fontWeight: FontWeight.w400),
                ),
                if (letters.isNotEmpty)
                  Text(
                    letters,
                    style: TextStyle(
                      color: vc.textFaint,
                      fontSize: 9,
                      letterSpacing: 2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
