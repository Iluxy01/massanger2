import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'screens/chat_screen.dart';
import 'screens/cover_screens.dart';
import 'screens/home_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/onboarding_screen.dart';
import 'state/app_state.dart';
import 'widgets/avatar.dart';
import 'widgets/effects.dart';
import 'widgets/slow_clock.dart';
import 'widgets/visual.dart';

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
    // Декоративные анимации (фон, точки) стоят, пока приложение не на экране.
    Activity.setResumed(s == AppLifecycleState.resumed);
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
      // Всё приложение (тема, MaterialApp) перестраивается только при смене
      // темы или акцента; данные перерисовывают лишь зависящие от них экраны.
      child: ListenableBuilder(
        listenable: widget.state.themeTick,
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
            builder: (context, child) => Visual(
              look: s.effLook,
              motion: s.effMotion,
              skin: s.skin,
              // Анимации выключены — аватарки между экранами тоже не «летают».
              child: HeroMode(
                enabled: s.effMotion > 0,
                // Любое касание «будит» живой фон; без касаний он замирает.
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) => Activity.poke(),
                  onPointerMove: (_) => Activity.poke(),
                  onPointerSignal: (_) => Activity.poke(),
                  child: Stack(
                    children: [
                      child!,
                      const _InAppBanner(),
                      // Экран блокировки — поверх всего, включая открытые чаты.
                      const _LockLayer(),
                      // Маскировка («Калькулятор» / «Заметки») — ещё выше.
                      const _CoverLayer(),
                    ],
                  ),
                ),
              ),
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
    final skin = s.skin;
    final brightness = vc.dark ? Brightness.dark : Brightness.light;
    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      fontFamily: skin.font,
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
      pageTransitionsTheme: s.effMotion == 0
          ? const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _NoTransitions(),
                TargetPlatform.iOS: _NoTransitions(),
              },
            )
          : skin.id == 0
          ? const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: CupertinoPageTransitionsBuilder(),
                TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
              },
            )
          : PageTransitionsTheme(
              builders: {
                TargetPlatform.android: _SkinTransitions(skin.id),
                TargetPlatform.iOS: _SkinTransitions(skin.id),
              },
            ),
    );
    return base.copyWith(
      textTheme: base.textTheme.apply(bodyColor: vc.text, displayColor: vc.text),
      iconTheme: IconThemeData(color: vc.text),
    );
  }
}

/// Переход между экранами без анимации (уровень анимаций «Выкл»).
class _NoTransitions extends PageTransitionsBuilder {
  const _NoTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

/// Переходы между экранами у стилей:
///   Терминал — короткий сдвиг с проявлением, без «пружин»;
///   Космос — экран выплывает из глубины, прежний уходит «вперёд»;
///   Лимонад — мягко поднимается снизу с лёгким отскоком.
class _SkinTransitions extends PageTransitionsBuilder {
  const _SkinTransitions(this.skin);

  final int skin;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // Прозрачность — самая дорогая часть перехода (весь экран рисуется в
    // отдельный слой), поэтому экран проявляется за первую половину пути, а
    // дальше движется уже непрозрачным.
    switch (skin) {
      case 1:
        final a = CurvedAnimation(parent: animation, curve: Curves.easeOutQuart);
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.45)),
          child: SlideTransition(
            position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(a),
            child: child,
          ),
        );
      case 2:
        return _DepthTransition(animation: animation, secondary: secondaryAnimation, child: child);
      default:
        final a = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: const Interval(0, 0.45)),
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.08), end: Offset.zero).animate(a),
            child: child,
          ),
        );
    }
  }
}

/// Космос: экран выплывает из глубины (0.9 → 1, проявляясь), прежний уходит
/// «вперёд» (1 → 1.05).
///
/// Пока идёт переход, экран один раз рисуется в картинку, и масштабируется уже
/// она. Если масштабировать сам экран, движок под каждый промежуточный масштаб
/// заново растрирует все буквы и эмодзи — на первых открытиях это дёргает.
class _DepthTransition extends StatefulWidget {
  const _DepthTransition({required this.animation, required this.secondary, required this.child});

  final Animation<double> animation;
  final Animation<double> secondary;
  final Widget child;

  @override
  State<_DepthTransition> createState() => _DepthTransitionState();
}

class _DepthTransitionState extends State<_DepthTransition> {
  final _controller = SnapshotController();
  late _DepthPainter _painter;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(_DepthTransition old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation || old.secondary != widget.secondary) {
      _detach(old);
      _painter.dispose();
      _attach();
    }
  }

  /// Сколько ближайших кадров ещё снимать экран заново: в начале перехода на
  /// нём меняется аватарка, улетающая в шапку (Hero), — без этого она бы на
  /// миг «двоилась». Дальше масштабируется уже готовая картинка.
  int _fresh = 0;

  void _attach() {
    _painter = _DepthPainter(widget.animation, widget.secondary);
    for (final a in [widget.animation, widget.secondary]) {
      a.addStatusListener(_status);
      a.addListener(_tick);
    }
    _status(AnimationStatus.completed);
  }

  void _detach(_DepthTransition w) {
    for (final a in [w.animation, w.secondary]) {
      a.removeStatusListener(_status);
      a.removeListener(_tick);
    }
  }

  void _status(AnimationStatus _) {
    final on = widget.animation.isAnimating || widget.secondary.isAnimating;
    if (on && !_controller.allowSnapshotting) _fresh = 3;
    _controller.allowSnapshotting = on;
  }

  void _tick() {
    if (_fresh > 0 && _controller.allowSnapshotting) {
      _fresh--;
      _controller.clear();
    }
  }

  @override
  void dispose() {
    _detach(widget);
    _painter.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SnapshotWidget(
    controller: _controller,
    // Видео внутри экрана в картинку не снять — тогда рисуем как обычно.
    mode: SnapshotMode.permissive,
    painter: _painter,
    child: widget.child,
  );
}

class _DepthPainter extends SnapshotPainter {
  _DepthPainter(this.enter, this.exit)
    : _in = CurvedAnimation(
        parent: enter,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ),
      _fade = CurvedAnimation(
        parent: enter,
        curve: const Interval(0, 0.55, curve: Curves.easeOut),
      ),
      _out = CurvedAnimation(parent: exit, curve: Curves.easeInOutCubic) {
    enter.addListener(notifyListeners);
    exit.addListener(notifyListeners);
  }

  final Animation<double> enter;
  final Animation<double> exit;
  final CurvedAnimation _in;
  final CurvedAnimation _fade;
  final CurvedAnimation _out;
  final _transform = LayerHandle<TransformLayer>();
  final _opacity = LayerHandle<OpacityLayer>();

  double get _scale => (0.9 + 0.1 * _in.value) * (1 + 0.05 * _out.value);
  int get _alpha => (_fade.value.clamp(0.0, 1.0) * 255).round();

  @override
  void paintSnapshot(
    PaintingContext context,
    Offset offset,
    Size size,
    ui.Image image,
    Size sourceSize,
    double pixelRatio,
  ) {
    final alpha = _alpha;
    if (alpha == 0) return;
    final s = _scale;
    // sourceSize — в физических пикселях; рисуем в логических.
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromCenter(
      center: (offset & size).center,
      width: size.width * s,
      height: size.height * s,
    );
    context.canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()
        ..color = Color.fromARGB(alpha, 0, 0, 0)
        ..filterQuality = FilterQuality.medium,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset, Size size, PaintingContextCallback painter) {
    final alpha = _alpha;
    final s = _scale;
    if (alpha == 255 && s == 1) {
      _transform.layer = null;
      _opacity.layer = null;
      painter(context, offset);
      return;
    }
    if (alpha == 0) {
      _transform.layer = null;
      _opacity.layer = null;
      return;
    }
    final c = size.center(Offset.zero);
    final m = Matrix4.translationValues(c.dx, c.dy, 0)
      ..multiply(Matrix4.diagonal3Values(s, s, 1))
      ..multiply(Matrix4.translationValues(-c.dx, -c.dy, 0));
    _transform.layer = context.pushTransform(
      true,
      offset,
      m,
      (context, offset) =>
          _opacity.layer = context.pushOpacity(offset, alpha, painter, oldLayer: _opacity.layer),
      oldLayer: _transform.layer,
    );
  }

  @override
  bool shouldRepaint(_DepthPainter old) => old.enter != enter || old.exit != exit;

  @override
  void dispose() {
    enter.removeListener(notifyListeners);
    exit.removeListener(notifyListeners);
    _in.dispose();
    _fade.dispose();
    _out.dispose();
    _transform.layer = null;
    _opacity.layer = null;
    super.dispose();
  }
}

class _CoverLayer extends StatelessWidget {
  const _CoverLayer();

  @override
  Widget build(BuildContext context) =>
      context.app.covered ? const CoverScreen() : const SizedBox.shrink();
}

class _LockLayer extends StatelessWidget {
  const _LockLayer();

  @override
  Widget build(BuildContext context) {
    final locked = context.app.locked;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 400).by(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 1.06, end: 1.0).animate(a), child: c),
      ),
      child: locked ? const LockScreen(key: ValueKey('lock')) : const SizedBox.shrink(),
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
      duration: const Duration(milliseconds: 700).by(context),
      switchInCurve: Curves.easeOutCubic,
      // Сдвиг, а не масштаб: масштаб заставлял заново растрировать весь текст
      // главного экрана на каждом кадре появления.
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.03), end: Offset.zero).animate(a),
          child: c,
        ),
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
      if (!mounted) return;
      final app = context.appRead;
      if (app.locked || app.covered || !app.inAppBanner) return;
      app.tick(HapticKind.light);
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
      duration: const Duration(milliseconds: 520).by(context),
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
                    blur: 20,
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
                                e.message.secret ? '🔒 Секретное сообщение' : e.message.preview,
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
