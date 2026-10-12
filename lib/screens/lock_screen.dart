import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../theme/palette.dart';
import '../widgets/effects.dart';

/// PIN-код: разблокировка приложения или установка нового кода.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, this.setup = false});

  /// true — создаём новый PIN (ввод + подтверждение).
  final bool setup;

  static Route<bool> setupRoute() => PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 450),
    pageBuilder: (_, _, _) => const LockScreen(setup: true),
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
  bool _success = false;

  String get _title {
    if (!widget.setup) return 'Введите PIN';
    return _first == null ? 'Придумайте PIN' : 'Повторите PIN';
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

  void _check() {
    if (!mounted) return;
    final app = context.appRead;
    if (widget.setup) {
      if (_first == null) {
        setState(() {
          _first = _input;
          _input = '';
        });
      } else if (_first == _input) {
        _ok(() {
          app.setPin(_input);
          Navigator.of(context).pop(true);
        });
      } else {
        _fail(resetFirst: true);
      }
      return;
    }
    if (_input == app.pin) {
      _ok(() => app.unlock(_input));
    } else {
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

  void _fail({bool resetFirst = false}) {
    context.appRead.tick(HapticKind.heavy);
    setState(() {
      _error = true;
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
              if (widget.setup)
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
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutBack,
                child: VeilLogo(size: 64, glow: _success),
              ),
              const SizedBox(height: 24),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: Text(
                  _error ? (widget.setup ? 'Не совпадает, ещё раз' : 'Неверный PIN') : _title,
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
                widget.setup ? 'Код защищает переписку на этом устройстве' : 'Veil заблокирован',
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
                      duration: const Duration(milliseconds: 220),
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
              _Keypad(onDigit: _press, onBackspace: _backspace),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  const _Keypad({required this.onDigit, required this.onBackspace});

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

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
              const SizedBox(width: 108),
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
          blur: 12,
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
