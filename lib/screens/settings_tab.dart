import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/relay_pool.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'add_friend_screen.dart';
import 'lock_screen.dart';
import '../widgets/visual.dart';
import 'backup_screens.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final p = app.profile;
    final top = MediaQuery.paddingOf(context).top;
    if (p == null) return const SizedBox.shrink();

    return Stack(
      children: [
        const Positioned.fill(child: AuroraBackground(intensity: 0.5)),
        ListView(
          padding: EdgeInsets.fromLTRB(20, top + 20, 20, 140),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: [
            // ── Профиль ──
            Center(
              child: Pressable(
                onTap: () => _editAvatar(context),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(color: p.colors.first.withValues(alpha: 0.5), blurRadius: 40),
                        ],
                      ),
                      child: Avatar(emoji: p.emoji, colors: p.colors, size: 110),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          gradient: app.accent.gradient,
                          shape: BoxShape.circle,
                          border: Border.all(color: vc.bg, width: 3),
                        ),
                        child: Icon(Icons.edit_rounded, size: 16, color: app.accent.onAccent),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Pressable(
                onTap: () => _editName(context),
                child: Text(
                  p.name,
                  style: TextStyle(
                    color: vc.text,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                p.veilId,
                style: TextStyle(
                  color: vc.textDim,
                  fontFamily: 'monospace',
                  fontSize: 13,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(height: 20),
            _KeyCard(fingerprint: p.fingerprint),
            const SizedBox(height: 12),
            _Group(
              children: [
                _Tile(
                  icon: Icons.qr_code_rounded,
                  title: 'Мой QR-код',
                  subtitle: 'Чтобы друг добавил тебя',
                  onTap: () => Navigator.of(context).push(AddFriendScreen.route()),
                ),
              ],
            ),

            // ── Оформление ──
            const _Section('Оформление'),
            _Group(
              children: [
                _Tile(
                  icon: vc.dark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  title: 'Тёмная тема',
                  trailing: VeilSwitch(value: app.dark, onChanged: app.setDark),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Акцент · ${app.accent.name}',
                        style: TextStyle(color: vc.textDim, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (var i = 0; i < accents.length; i++)
                            _AccentDot(
                              accent: accents[i],
                              selected: i == app.accentIndex,
                              onTap: () {
                                app.tick(HapticKind.light);
                                app.setAccent(i);
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                _LevelPicker(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Оформление',
                  labels: lookLevels,
                  hints: const [
                    'Чистый фон, без размытия — бережёт батарею',
                    'Сияние на фоне, стекло на главных панелях',
                    'Живое сияние и матовое стекло везде',
                  ],
                  value: app.look,
                  onChanged: app.setLook,
                ),
                _LevelPicker(
                  icon: Icons.animation_rounded,
                  title: 'Анимации',
                  labels: motionLevels,
                  hints: const [
                    'Всё появляется сразу, без движения',
                    'Короткие и резкие',
                    'Как задумано',
                    'Медленнее и мягче',
                  ],
                  value: app.motion,
                  onChanged: app.setMotion,
                ),
              ],
            ),

            // ── Приватность ──
            const _Section('Приватность'),
            _Group(
              children: [
                _Tile(
                  icon: Icons.pin_rounded,
                  title: 'PIN-код',
                  subtitle: !app.hasPin ? 'Выключен' : 'Включён · блокировка при сворачивании',
                  trailing: VeilSwitch(
                    value: app.hasPin,
                    onChanged: (v) async {
                      if (v) {
                        final ok = await Navigator.of(context).push(LockScreen.setupRoute());
                        if (ok == true && context.mounted) {
                          showVeilToast(context, 'PIN установлен', icon: Icons.lock_rounded);
                        }
                      } else {
                        app.setPin(null);
                      }
                    },
                  ),
                ),
                if (app.hasPin)
                  _Tile(
                    icon: Icons.lock_clock_rounded,
                    title: 'Заблокировать сейчас',
                    onTap: app.lock,
                  ),
                _Tile(
                  icon: Icons.done_all_rounded,
                  title: 'Отчёты о прочтении',
                  trailing: VeilSwitch(
                    value: app.readReceipts,
                    onChanged: (v) => app.setFlag(() => app.readReceipts = v),
                  ),
                ),
                _Tile(
                  icon: Icons.keyboard_rounded,
                  title: 'Индикатор набора',
                  trailing: VeilSwitch(
                    value: app.typingIndicators,
                    onChanged: (v) => app.setFlag(() => app.typingIndicators = v),
                  ),
                ),
                _Tile(
                  icon: Icons.screenshot_monitor_rounded,
                  title: 'Запрет скриншотов',
                  trailing: VeilSwitch(
                    value: app.screenshotProtection,
                    onChanged: (v) => app.setFlag(() => app.screenshotProtection = v),
                  ),
                ),
                _Tile(
                  icon: Icons.vibration_rounded,
                  title: 'Вибро-отклик',
                  trailing: VeilSwitch(
                    value: app.haptics,
                    onChanged: (v) => app.setFlag(() => app.haptics = v),
                  ),
                ),
                _Tile(
                  icon: Icons.web_asset_rounded,
                  title: 'Всплывающие сообщения',
                  subtitle: 'Окошко сверху, когда приложение открыто',
                  trailing: VeilSwitch(
                    value: app.inAppBanner,
                    onChanged: (v) => app.setFlag(() => app.inAppBanner = v),
                  ),
                ),
                _Tile(
                  icon: Icons.bolt_rounded,
                  title: 'Мгновенные уведомления',
                  subtitle: app.instantNotify
                      ? 'Сообщения приходят сразу · значок «на связи» в шторке'
                      : 'Сейчас — проверка раз в ~15 минут, когда Veil закрыт',
                  trailing: VeilSwitch(
                    value: app.instantNotify,
                    onChanged: (v) {
                      app.setInstantNotify(v);
                      if (v) {
                        showVeilToast(
                          context,
                          'Veil останется на связи в фоне. Если сообщения всё равно '
                          'опаздывают — разреши ему работать без ограничений батареи',
                          icon: Icons.bolt_rounded,
                        );
                      }
                    },
                  ),
                ),
                _Tile(
                  icon: Icons.notifications_rounded,
                  title: 'Текст в уведомлениях',
                  subtitle: app.notificationText ? 'Показывается' : 'Только «Новое сообщение»',
                  trailing: VeilSwitch(
                    value: app.notificationText,
                    onChanged: (v) => app.setFlag(() => app.notificationText = v),
                  ),
                ),
              ],
            ),

            // ── Сеть ──
            const _Section('Сеть'),
            const _NetworkCard(),

            // ── Хранилище ──
            const _Section('Хранилище'),
            const _StorageCard(),
            const SizedBox(height: 12),
            _Group(
              children: [
                _Tile(
                  icon: Icons.backup_rounded,
                  title: 'Зашифрованная копия',
                  subtitle: 'Файл под паролем — чтобы перенести Veil на новый телефон',
                  onTap: () => showExportBackup(context),
                ),
              ],
            ),

            // ── Опасная зона ──
            const _Section('Опасная зона'),
            HoldToConfirm(
              label: 'Удерживай, чтобы стереть всё',
              onConfirmed: () {
                navigatorKey.currentState?.popUntil((r) => r.isFirst);
                app.wipeEverything();
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Удалит ключи, профиль и всю переписку с этого телефона. Восстановить будет невозможно — серверных копий нет.',
              textAlign: TextAlign.center,
              style: TextStyle(color: vc.textFaint, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 32),
            Center(child: Opacity(opacity: 0.6, child: VeilLogo(size: 36, glow: false))),
            const SizedBox(height: 10),
            Center(
              child: Text(
                'Veil 0.1 · бесплатно навсегда',
                style: TextStyle(color: vc.textFaint, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _editName(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    final ctrl = TextEditingController(text: app.profile!.name);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Имя', style: TextStyle(color: vc.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 24,
          style: TextStyle(color: vc.text),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(
            onPressed: () {
              if (ctrl.text.trim().length >= 2) app.updateProfile(name: ctrl.text.trim());
              Navigator.pop(ctx);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }

  void _editAvatar(BuildContext context) {
    final app = context.appRead;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AppScope(
        state: app,
        child: Builder(
          builder: (ctx) {
            final vc = ctx.vc;
            final p = ctx.app.profile!;
            return Padding(
              padding: const EdgeInsets.all(12),
              child: Glass(
                radius: 28,
                color: vc.surface.withValues(alpha: 0.95),
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Avatar(emoji: p.emoji, colors: p.colors, size: 72),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: avatarGradients.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (_, i) => Pressable(
                          onTap: () => app.updateProfile(colorIndex: i),
                          child: Container(
                            width: 40,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(colors: avatarGradients[i]),
                              border: Border.all(
                                color: avatarGradients[i] == p.colors
                                    ? vc.text
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GridView.count(
                      crossAxisCount: 8,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final e in avatarEmojis)
                          Pressable(
                            onTap: () => app.updateProfile(emoji: e),
                            child: Center(child: Text(e, style: const TextStyle(fontSize: 24))),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 28, 6, 10),
    child: Text(
      title.toUpperCase(),
      style: TextStyle(
        color: context.vc.textFaint,
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.4,
      ),
    ),
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Container(
      decoration: BoxDecoration(
        color: vc.surface.withValues(alpha: vc.dark ? 0.85 : 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: vc.border),
      ),
      child: Column(
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 60, color: vc.border),
            children[i],
          ],
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, this.subtitle, this.trailing, this.onTap});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: acc.a.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(child: GradientIcon(icon, size: 19)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: vc.text, fontSize: 15.5, fontWeight: FontWeight.w600),
                ),
                if (subtitle != null)
                  Text(subtitle!, style: TextStyle(color: vc.textDim, fontSize: 12.5)),
              ],
            ),
          ),
          trailing ??
              (onTap != null
                  ? Icon(Icons.chevron_right_rounded, color: vc.textFaint)
                  : const SizedBox()),
        ],
      ),
    );
    if (onTap == null) return body;
    return Pressable(scale: 0.98, onTap: onTap, child: body);
  }
}

/// Выбор уровня: заголовок, подсказка к выбранному уровню и ряд сегментов.
class _LevelPicker extends StatelessWidget {
  const _LevelPicker({
    required this.icon,
    required this.title,
    required this.labels,
    required this.hints,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final List<String> labels;
  final List<String> hints;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: acc.a.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(child: GradientIcon(icon, size: 19)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(color: vc.text, fontSize: 15.5, fontWeight: FontWeight.w600),
                    ),
                    Text(hints[value], style: TextStyle(color: vc.textDim, fontSize: 12.5)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: vc.elevated, borderRadius: BorderRadius.circular(14)),
            child: Row(
              children: [
                for (var i = 0; i < labels.length; i++)
                  Expanded(
                    child: Pressable(
                      scale: 0.94,
                      onTap: () {
                        if (i == value) return;
                        context.appRead.tick(HapticKind.light);
                        onChanged(i);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250).by(context),
                        curve: Curves.easeOutCubic,
                        padding: const EdgeInsets.symmetric(vertical: 9),
                        decoration: BoxDecoration(
                          gradient: i == value ? acc.gradient : null,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            labels[i],
                            style: TextStyle(
                              color: i == value ? acc.onAccent : vc.textDim,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AccentDot extends StatelessWidget {
  const _AccentDot({required this.accent, required this.selected, required this.onTap});

  final Accent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Pressable(
      scale: 0.85,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300).by(context),
        curve: Curves.easeOutBack,
        width: 44,
        height: 44,
        padding: EdgeInsets.all(selected ? 4 : 0),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: selected ? vc.text : Colors.transparent, width: 2),
        ),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: accent.gradient,
            boxShadow: selected
                ? [BoxShadow(color: accent.mid.withValues(alpha: 0.6), blurRadius: 14)]
                : null,
          ),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 300).by(context),
            curve: Curves.easeOutBack,
            scale: selected ? 1 : 0,
            child: Icon(Icons.check_rounded, size: 18, color: accent.onAccent),
          ),
        ),
      ),
    );
  }
}

/// Отпечаток ключа владельца.
class _KeyCard extends StatelessWidget {
  const _KeyCard({required this.fingerprint});
  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final groups = [for (var i = 0; i < 32; i += 4) fingerprint.substring(i, i + 4)];
    return Glass(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          KeyIdenticon(seed: fingerprint, size: 64),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const GradientIcon(Icons.key_rounded, size: 16),
                    const SizedBox(width: 6),
                    Text(
                      'Твой ключ',
                      style: TextStyle(color: vc.text, fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  groups.join(' '),
                  style: TextStyle(
                    color: vc.textDim,
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.5,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final kb = app.storageBytes / 1024;
    final size = kb > 1024 ? '${(kb / 1024).toStringAsFixed(1)} МБ' : '${kb.toStringAsFixed(1)} КБ';
    final chats = app.chatList.length;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: vc.surface.withValues(alpha: vc.dark ? 0.85 : 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: vc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const GradientIcon(Icons.phone_android_rounded, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Всё хранится на этом телефоне',
                  style: TextStyle(color: vc.text, fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: app.totalMessages.toDouble()),
                duration: const Duration(milliseconds: 1200).by(context),
                curve: Curves.easeOutCubic,
                builder: (_, v, _) => GradientText(
                  '${v.round()}',
                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, height: 1),
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'сообщений · $chats чатов · $size',
                  style: TextStyle(color: vc.textDim, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  Expanded(flex: 5, child: Container(color: acc.a)),
                  Expanded(flex: 3, child: Container(color: acc.b)),
                  Expanded(flex: 1, child: Container(color: VeilColors.warning)),
                  Expanded(flex: 6, child: Container(color: vc.elevated)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _Legend(color: acc.a, label: 'Текст'),
              _Legend(color: acc.b, label: 'Голосовые'),
              const _Legend(color: VeilColors.warning, label: 'Ключи'),
              _Legend(color: vc.textFaint, label: 'На сервере: 0 Б'),
            ],
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: TextStyle(color: context.vc.textDim, fontSize: 12)),
    ],
  );
}

/// Кнопка «удерживай, чтобы подтвердить» с заполняющимся прогрессом.
class HoldToConfirm extends StatefulWidget {
  const HoldToConfirm({super.key, required this.label, required this.onConfirmed});

  final String label;
  final VoidCallback onConfirmed;

  @override
  State<HoldToConfirm> createState() => _HoldToConfirmState();
}

class _HoldToConfirmState extends State<HoldToConfirm> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800))
        ..addStatusListener((s) {
          if (s == AnimationStatus.completed) {
            context.appRead.tick(HapticKind.heavy);
            widget.onConfirmed();
          }
        })
        ..addListener(() {
          // Нарастающая вибрация по мере удержания.
          final step = (_c.value * 10).floor();
          if (step != _lastStep && _c.status == AnimationStatus.forward) {
            _lastStep = step;
            context.appRead.tick(HapticKind.selection);
          }
        });
  int _lastStep = 0;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    _lastStep = 0;
    _c.forward();
  }

  void _up() {
    if (_c.status != AnimationStatus.completed) {
      _c.animateBack(0, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _down(),
      onTapUp: (_) => _up(),
      onTapCancel: _up,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Transform.scale(
          scale: 1 - 0.03 * _c.value,
          child: Container(
            height: 60,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: VeilColors.danger.withValues(alpha: 0.1),
              border: Border.all(color: VeilColors.danger.withValues(alpha: 0.4)),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                FractionallySizedBox(
                  widthFactor: _c.value,
                  heightFactor: 1,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: [Color(0xFFFF7A45), VeilColors.danger]),
                    ),
                  ),
                ),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.local_fire_department_rounded,
                        color: Color.lerp(VeilColors.danger, Colors.white, _c.value),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        widget.label,
                        style: TextStyle(
                          color: Color.lerp(VeilColors.danger, Colors.white, _c.value),
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ],
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

/// Ретрансляторы: бесплатные публичные «почтовые ящики» для зашифрованных конвертов.
class _NetworkCard extends StatelessWidget {
  const _NetworkCard();

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final relays = app.relays;
    final online = app.onlineRelays;
    final color = online > 0 ? VeilColors.success : VeilColors.danger;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 10, 8),
      decoration: BoxDecoration(
        color: vc.surface.withValues(alpha: vc.dark ? 0.85 : 0.9),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: vc.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  online > 0
                      ? 'Подключено: $online из ${relays.length}'
                      : 'Нет связи с ретрансляторами',
                  style: TextStyle(color: vc.text, fontWeight: FontWeight.w700, fontSize: 15),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Text(
              'Сообщения идут через бесплатные ретрансляторы Nostr. Они видят только '
              'зашифрованный конверт и удаляют его через 7 дней. Достаточно, чтобы работал хотя бы один.',
              style: TextStyle(color: vc.textDim, fontSize: 12.5, height: 1.4),
            ),
          ),
          const SizedBox(height: 8),
          for (final url in relays)
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: switch (app.relayState(url)) {
                    RelayState.online => VeilColors.success,
                    RelayState.connecting => VeilColors.warning,
                    RelayState.offline => VeilColors.danger,
                  },
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    url.replaceFirst('wss://', ''),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: vc.text, fontSize: 13.5, fontFamily: 'monospace'),
                  ),
                ),
                if (relays.length > 1)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.close_rounded, size: 18, color: vc.textFaint),
                    onPressed: () => app.setRelays([...relays]..remove(url)),
                  ),
              ],
            ),
          const SizedBox(height: 8),
          AccentButton(
            label: 'Проверить связь',
            icon: Icons.network_check_rounded,
            onTap: () => _diagnose(context),
          ),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            children: [
              TextButton.icon(
                onPressed: () => _add(context),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Добавить свой'),
              ),
              TextButton.icon(
                onPressed: () => _journal(context),
                icon: const Icon(Icons.receipt_long_rounded, size: 18),
                label: const Text('Журнал'),
              ),

              TextButton(
                onPressed: () => app.setRelays(List.of(defaultRelays)),
                child: Text('Сбросить', style: TextStyle(color: vc.textDim)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _diagnose(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    final future = app.diagnose();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Проверка связи', style: TextStyle(color: vc.text)),
        content: FutureBuilder<Map<String, (bool, bool)>>(
          future: future,
          builder: (_, snap) {
            if (!snap.hasData) {
              return Row(
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Отправляю зашифрованное письмо самому себе через каждый ретранслятор…',
                      style: TextStyle(color: vc.textDim),
                    ),
                  ),
                ],
              );
            }
            final r = snap.data!;
            final good = r.values.where((v) => v.$1 && v.$2).length;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  good > 0
                      ? 'Работает $good из ${r.length}. Сообщения ходят ✅'
                      : 'Ни один ретранслятор не доставил письмо ❌',
                  style: TextStyle(color: vc.text, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                for (final e in r.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${e.value.$1 && e.value.$2
                          ? '✅'
                          : e.value.$1
                          ? '⚠️'
                          : '❌'}  '
                      '${e.key.replaceFirst('wss://', '')}'
                      '${e.value.$1 && !e.value.$2 ? ' — принял, но не вернул' : ''}'
                      '${!e.value.$1 ? ' — нет ответа${app.relayError(e.key) != null ? ' (${app.relayError(e.key)})' : ''}' : ''}',
                      style: TextStyle(color: vc.textDim, fontSize: 13),
                    ),
                  ),
              ],
            );
          },
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Готово'))],
      ),
    );
  }

  void _journal(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    final lines = List.of(app.journal.reversed);
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Журнал сети', style: TextStyle(color: vc.text)),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: lines.isEmpty
              ? Text('Пока пусто', style: TextStyle(color: vc.textDim))
              : ListView.builder(
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      lines[i],
                      style: TextStyle(color: vc.textDim, fontSize: 11.5, fontFamily: 'monospace'),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: app.journal.join('\n')));
              showVeilToast(context, 'Журнал скопирован — пришли его разработчику');
            },
            child: const Text('Копировать'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  void _add(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    final ctrl = TextEditingController(text: 'wss://');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Адрес ретранслятора', style: TextStyle(color: vc.text)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          style: TextStyle(color: vc.text, fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(
            onPressed: () {
              final url = ctrl.text.trim();
              if (url.startsWith('wss://') && url.length > 8 && !app.relays.contains(url)) {
                app.setRelays([...app.relays, url]);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    ).whenComplete(ctrl.dispose);
  }
}
