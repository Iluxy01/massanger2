import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/chat_screen.dart';
import 'screens/home_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/onboarding_screen.dart';
import 'state/app_state.dart';
import 'widgets/avatar.dart';
import 'widgets/effects.dart';

final navigatorKey = GlobalKey<NavigatorState>();

class VeilApp extends StatefulWidget {
  const VeilApp({super.key, required this.state});

  final AppState state;

  @override
  State<VeilApp> createState() => _VeilAppState();
}

class _VeilAppState extends State<VeilApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Свернул приложение — оно блокируется (если задан PIN).
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      widget.state.lock();
      widget.state.setForeground(false);
    } else if (s == AppLifecycleState.resumed) {
      widget.state.setForeground(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      child: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final s = widget.state;
          final vc = s.colors;
          SystemChrome.setSystemUIOverlayStyle(
            SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              systemNavigationBarColor: Colors.transparent,
              statusBarIconBrightness: vc.dark ? Brightness.light : Brightness.dark,
              systemNavigationBarIconBrightness: vc.dark ? Brightness.light : Brightness.dark,
            ),
          );
          return MaterialApp(
            title: 'Veil',
            debugShowCheckedModeBanner: false,
            navigatorKey: navigatorKey,
            theme: _theme(s),
            builder: (context, child) => Stack(
              children: [
                child!,
                const _InAppBanner(),
                // Экран блокировки — поверх всего, включая открытые чаты.
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 450),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (c, a) => FadeTransition(
                    opacity: a,
                    child: ScaleTransition(
                      scale: Tween(begin: 1.08, end: 1.0).animate(a),
                      child: c,
                    ),
                  ),
                  child: s.locked
                      ? const LockScreen(key: ValueKey('lock'))
                      : const SizedBox.shrink(),
                ),
              ],
            ),
            home: const _RootGate(),
          );
        },
      ),
    );
  }

  ThemeData _theme(AppState s) {
    final vc = s.colors;
    final acc = s.accent;
    final brightness = vc.dark ? Brightness.dark : Brightness.light;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: acc.a,
        brightness: brightness,
        primary: acc.a,
        surface: vc.surface,
      ),
      scaffoldBackgroundColor: vc.bg,
      splashFactory: InkRipple.splashFactory,
      splashColor: acc.a.withValues(alpha: 0.08),
      highlightColor: Colors.transparent,
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: acc.a,
        selectionColor: acc.a.withValues(alpha: 0.3),
        selectionHandleColor: acc.a,
      ),
      dividerColor: vc.border,
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: vc.text, displayColor: vc.text),
      iconTheme: IconThemeData(color: vc.text),
    );
  }
}

/// Онбординг или главный экран.
class _RootGate extends StatelessWidget {
  const _RootGate();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final onboarded = app.onboarded;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 700),
      switchInCurve: Curves.easeOutCubic,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(a), child: c),
      ),
      child: !app.ready
          ? const _Splash(key: ValueKey('splash'))
          : onboarded
          ? const HomeScreen(key: ValueKey('home'))
          : const OnboardingScreen(key: ValueKey('onboarding')),
    );
  }
}

/// Пока открывается база — только логотип на фоне.
class _Splash extends StatelessWidget {
  const _Splash({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.vc.bg,
    body: const Center(child: VeilLogo(size: 84)),
  );
}

/// Стеклянное уведомление о новом сообщении, выезжающее сверху.
class _InAppBanner extends StatefulWidget {
  const _InAppBanner();

  @override
  State<_InAppBanner> createState() => _InAppBannerState();
}

class _InAppBannerState extends State<_InAppBanner> {
  StreamSubscription<Incoming>? _sub;
  Incoming? _current;
  bool _visible = false;
  Timer? _hide;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sub ??= context.appRead.incoming.listen((e) {
      if (!mounted || context.appRead.locked) return;
      context.appRead.tick(HapticKind.light);
      setState(() {
        _current = e;
        _visible = true;
      });
      _hide?.cancel();
      _hide = Timer(const Duration(milliseconds: 3200), () {
        if (mounted) setState(() => _visible = false);
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = _current;
    final vc = context.vc;
    final top = MediaQuery.paddingOf(context).top + 8;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 520),
      curve: _visible ? Curves.easeOutBack : Curves.easeInCubic,
      top: _visible ? top : -140,
      left: 12,
      right: 12,
      child: e == null
          ? const SizedBox.shrink()
          : Material(
              type: MaterialType.transparency,
              child: Dismissible(
                key: ValueKey(e.message.id),
                direction: DismissDirection.up,
                onDismissed: (_) => setState(() {
                  _visible = false;
                  _current = null;
                }),
                child: Pressable(
                  onTap: () {
                    setState(() => _visible = false);
                    navigatorKey.currentState?.push(ChatScreen.route(e.contact));
                  },
                  child: Glass(
                    radius: 22,
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Avatar.contact(e.contact, size: 42, showOnline: false),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    e.contact.name,
                                    style: TextStyle(
                                      color: vc.text,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 15,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Icon(Icons.lock_rounded, size: 12, color: vc.textFaint),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                e.message.text,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: vc.textDim, fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                        Text('сейчас', style: TextStyle(color: vc.textFaint, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
