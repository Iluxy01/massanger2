import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
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

  static const _tabs = [ChatsTab(), ContactsTab(), SettingsTab()];

  void _go(int i) {
    if (i == _tab) return;
    setState(() => _tab = i);
  }

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Scaffold(
      backgroundColor: vc.bg,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          for (var i = 0; i < _tabs.length; i++)
            // Анимация исчезновения должна быть СНАРУЖИ TickerMode: иначе выключенный
            // тикер замораживает её, и старая вкладка остаётся видна поверх новой.
            AnimatedOpacity(
              duration: const Duration(milliseconds: 260).by(context),
              curve: Curves.easeOut,
              opacity: i == _tab ? 1 : 0,
              child: AnimatedScale(
                duration: const Duration(milliseconds: 320).by(context),
                curve: Curves.easeOutCubic,
                scale: i == _tab ? 1 : 0.97,
                child: IgnorePointer(
                  ignoring: i != _tab,
                  child: TickerMode(
                    enabled: i == _tab,
                    // Аватары с Hero есть на нескольких вкладках — оставляем только активную.
                    child: HeroMode(enabled: i == _tab, child: _tabs[i]),
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
              curve: Curves.easeOutBack,
              alignment: Alignment(-1 + index * 1.0, 0),
              child: FractionallySizedBox(
                widthFactor: 1 / 3,
                heightFactor: 1,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: acc.gradient,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [BoxShadow(color: acc.mid.withValues(alpha: 0.5), blurRadius: 18)],
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
