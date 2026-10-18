import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../state/app_state.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'chat_screen.dart';
import 'chats_tab.dart';
import 'contacts_tab.dart';
import 'settings_tab.dart';
import '../widgets/visual.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  late final AppState _app = context.appRead;

  /// Вкладки, которые уже хоть раз были нарисованы.
  final _painted = <int>{0};

  /// Вкладка, которая прямо сейчас один кадр рисуется невидимо (см. [_warmNext]).
  int? _warming;

  /// Только что «прогретая» вкладка: прячется обратно мгновенно, без анимации.
  int? _cooled;
  Timer? _warmTimer;

  /// Почти ноль: глазу не видно, но вкладка рисуется по-настоящему.
  static const _ghost = 2 / 255;

  @override
  void initState() {
    super.initState();
    _app.openRequest.addListener(_openRequested);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openRequested();
      _warmTimer = Timer(const Duration(milliseconds: 700), _warmNext);
    });
  }

  @override
  void dispose() {
    _warmTimer?.cancel();
    _app.openRequest.removeListener(_openRequested);
    super.dispose();
  }

  static const _tabs = [ChatsTab(), ContactsTab(), SettingsTab()];

  void _go(int i) {
    if (i == _tab) return;
    setState(() {
      _tab = i;
      _painted.add(i);
      if (_warming == i) _warming = null;
      _cooled = null;
    });
  }

  /// Скрытая вкладка не рисуется вовсе, поэтому при ПЕРВОМ показе движку
  /// приходилось разом готовить для неё всё: буквы и эмодзи нужных размеров,
  /// превью стилей, градиенты, — и переход дёргался (дальше всё уже готово).
  /// Поэтому вскоре после запуска каждая скрытая вкладка по очереди рисуется
  /// один кадр почти прозрачной — и к первому нажатию уже готова.
  void _warmNext() {
    if (!mounted) return;
    int? next;
    for (var i = 0; i < _tabs.length; i++) {
      if (!_painted.contains(i)) {
        next = i;
        break;
      }
    }
    if (next == null) return;
    final tab = next;
    setState(() {
      _warming = tab;
      _cooled = null;
    });
    // Колбэк сработает после кадра, в котором вкладка нарисована.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _painted.add(tab);
      if (_warming == tab) {
        setState(() {
          _warming = null;
          _cooled = tab;
        });
      }
      _warmTimer = Timer(const Duration(milliseconds: 250), _warmNext);
    });
  }

  /// Нажали на уведомление — открыть тот чат (после разблокировки).
  void _openRequested() {
    if (!mounted) return;
    final app = context.appRead;
    final id = app.openRequest.value;
    if (id == null || app.locked || app.covered) return;
    app.openRequest.value = null;
    final c = app.contact(id);
    if (c == null || !app.visible(c) || app.openChat == id) return;
    final nav = Navigator.of(context);
    nav.popUntil((r) => r.isFirst);
    nav.push(ChatScreen.route(c));
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final app = context.app;
    // Ждали разблокировки, чтобы открыть чат из уведомления.
    if (app.openRequest.value != null && !app.locked && !app.covered) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _openRequested());
    }
    return Scaffold(
      backgroundColor: vc.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Один общий фон на все вкладки: при переключении он не меняется и не
          // перерисовывается — плавно сменяется только содержимое.
          const Positioned.fill(child: AuroraBackground(intensity: 0.5)),
          for (var i = 0; i < _tabs.length; i++)
            // Анимация исчезновения должна быть СНАРУЖИ TickerMode: иначе выключенный
            // тикер замораживает её, и старая вкладка остаётся видна поверх новой.
            AnimatedOpacity(
              duration: i == _warming || i == _cooled
                  ? Duration.zero
                  : const Duration(milliseconds: 260).by(context),
              curve: Curves.easeOut,
              opacity: i == _tab
                  ? 1
                  : i == _warming
                  ? _ghost
                  : 0,
              // Вкладка «всплывает» сдвигом, а не масштабом: при каждом новом
              // масштабе движок заново растрирует все буквы и эмодзи вкладки —
              // именно это и дёргало первое переключение.
              child: AnimatedSlide(
                duration: const Duration(milliseconds: 320).by(context),
                curve: Curves.easeOutCubic,
                offset: i == _tab ? Offset.zero : const Offset(0, 0.012),
                child: IgnorePointer(
                  ignoring: i != _tab,
                  child: TickerMode(
                    enabled: i == _tab,
                    // Аватары с Hero есть на нескольких вкладках — оставляем только активную.
                    child: HeroMode(
                      enabled: i == _tab,
                      // Своя «плёнка» у вкладки: при её появлении и уходе
                      // остальной экран не перерисовывается.
                      child: RepaintBoundary(child: _tabs[i]),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.paddingOf(context).bottom + 14,
            child: _NavBar(index: _tab, onTap: _go),
          ),
        ],
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final profile = app.profile;
    final unread = app.totalUnread;
    final skin = context.skin;

    Widget item(int i, Widget icon, String label, {int badge = 0}) {
      final active = i == index;
      return Expanded(
        child: Pressable(
          key: ValueKey('nav-$i'),
          scale: 0.88,
          onTap: () => onTap(i),
          child: SizedBox(
            height: 58,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconTheme(
                      data: IconThemeData(color: active ? acc.onAccent : vc.textDim, size: 24),
                      child: icon,
                    ),
                    if (badge > 0)
                      Positioned(
                        right: -8,
                        top: -6,
                        child: _Badge(count: badge, inverted: active),
                      ),
                  ],
                ),
                Flexible(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 300).by(context),
                    curve: Curves.easeOutCubic,
                    child: active
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.fade,
                              softWrap: false,
                              style: TextStyle(
                                color: acc.onAccent,
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Glass(
      blur: 20,
      radius: 30,
      padding: const EdgeInsets.all(6),
      child: Stack(
        children: [
          // Скользящая «пилюля» под активной вкладкой.
          Positioned.fill(
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 420).by(context),
              curve: skin.id == 0 ? Curves.easeOutBack : skin.curve,
              alignment: Alignment(-1 + index * 1.0, 0),
              child: FractionallySizedBox(
                widthFactor: 1 / 3,
                heightFactor: 1,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: acc.gradient,
                    borderRadius: BorderRadius.circular(24 * skin.radius),
                    boxShadow: [
                      BoxShadow(
                        color: acc.mid.withValues(alpha: skin.id == 1 ? 0.25 : 0.5),
                        blurRadius: skin.glow ? 24 : 18,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              item(0, const Icon(Icons.chat_bubble_rounded), 'Чаты', badge: unread),
              item(1, const Icon(Icons.people_alt_rounded), 'Друзья'),
              item(
                2,
                profile == null
                    ? const Icon(Icons.person_rounded)
                    : Avatar(emoji: profile.emoji, colors: profile.colors, size: 26),
                'Профиль',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, this.inverted = false});

  final int count;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    return TweenAnimationBuilder<double>(
      key: ValueKey(count),
      tween: Tween(begin: 1.5, end: 1),
      duration: const Duration(milliseconds: 400).by(context),
      curve: Curves.easeOutBack,
      builder: (_, s, c) => Transform.scale(scale: s, child: c),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        constraints: const BoxConstraints(minWidth: 18),
        decoration: BoxDecoration(
          color: inverted ? Colors.white : null,
          gradient: inverted ? null : acc.gradient,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '$count',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: inverted ? acc.a : acc.onAccent,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}
