import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'chat_screen.dart';

/// Профиль друга: код безопасности, исчезающие сообщения, блокировка.
class ContactScreen extends StatelessWidget {
  const ContactScreen({super.key, required this.contact});

  final Contact contact;

  static Route<void> route(Contact c) =>
      MaterialPageRoute(builder: (_) => ContactScreen(contact: c));

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final c = contact;
    final me = app.profile;
    final safety = safetyNumber(me?.fingerprint ?? 'me', c.fingerprint);
    final msgs = app.messagesOf(c.id);
    final voice = msgs.where((m) => m.kind == MsgKind.voice).length;
    final top = MediaQuery.paddingOf(context).top;

    return Scaffold(
      backgroundColor: vc.bg,
      body: Stack(
        children: [
          Positioned.fill(child: _HeaderGlow(colors: c.colors)),
          ListView(
            padding: EdgeInsets.fromLTRB(20, top + 56, 20, 40),
            children: [
              Center(
                child: Hero(tag: 'avatar-${c.id}', child: Avatar.contact(c, size: 120)),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    c.name,
                    style: TextStyle(
                      color: vc.text,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  if (c.verified) ...[
                    const SizedBox(width: 6),
                    const GradientIcon(Icons.verified_rounded, size: 24),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  c.online ? 'в сети' : fmtLastSeen(c.lastSeen),
                  style: TextStyle(color: c.online ? VeilColors.success : vc.textDim),
                ),
              ),
              if (c.bio.isNotEmpty) ...[
                const SizedBox(height: 10),
                Center(
                  child: Text(
                    '«${c.bio}»',
                    style: TextStyle(color: vc.textDim, fontStyle: FontStyle.italic),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  _Action(
                    icon: Icons.chat_bubble_rounded,
                    label: 'Чат',
                    onTap: () {
                      final nav = Navigator.of(context);
                      if (nav.canPop()) nav.pop();
                      if (app.openChat != c.id) nav.push(ChatScreen.route(c));
                    },
                  ),
                  _Action(
                    icon: Icons.call_rounded,
                    label: 'Звонок',
                    onTap: () => showVeilToast(
                      context,
                      'Звонки — в следующей версии',
                      icon: Icons.call_rounded,
                    ),
                  ),
                  _Action(
                    icon: app.muted.contains(c.id)
                        ? Icons.notifications_off_rounded
                        : Icons.notifications_rounded,
                    label: app.muted.contains(c.id) ? 'Без звука' : 'Звук',
                    onTap: () => app.toggleMute(c.id),
                  ),
                  _Action(
                    icon: Icons.ios_share_rounded,
                    label: 'Поделиться',
                    onTap: () => showVeilToast(
                      context,
                      'Контакт можно передать только через QR',
                      icon: Icons.qr_code_rounded,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _Card(
                children: [
                  Row(
                    children: [
                      const GradientIcon(Icons.shield_rounded, size: 22),
                      const SizedBox(width: 10),
                      Text(
                        'Код безопасности',
                        style: TextStyle(color: vc.text, fontSize: 17, fontWeight: FontWeight.w700),
                      ),
                      const Spacer(),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        transitionBuilder: (ch, a) => ScaleTransition(scale: a, child: ch),
                        child: c.verified
                            ? Container(
                                key: const ValueKey('v'),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: VeilColors.success.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text(
                                  'ПРОВЕРЕН',
                                  style: TextStyle(
                                    color: VeilColors.success,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1,
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(key: ValueKey('n')),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      KeyIdenticon(seed: safety.join(), size: 92),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          children: [
                            for (final g in safety)
                              Text(
                                g,
                                style: TextStyle(
                                  color: vc.text,
                                  fontFamily: 'monospace',
                                  fontSize: 14,
                                  letterSpacing: 1,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Сравни этот код и картинку на телефоне ${c.name}. Если всё совпадает — никто не подменил ваше соединение.',
                    style: TextStyle(color: vc.textDim, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  AccentButton(
                    label: c.verified ? 'Снять отметку' : 'Отметить как проверенный',
                    icon: c.verified ? Icons.close_rounded : Icons.verified_rounded,
                    onTap: () {
                      app.tick(HapticKind.medium);
                      app.toggleVerified(c.id);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Card(
                children: [
                  Row(
                    children: [
                      Icon(Icons.timer_outlined, color: vc.text),
                      const SizedBox(width: 10),
                      Text(
                        'Исчезающие сообщения',
                        style: TextStyle(color: vc.text, fontSize: 16, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _Segmented(
                    values: const [0, 5, 60, 1440, 10080],
                    labels: const ['Выкл', '5 мин', '1 час', '1 день', 'Неделя'],
                    selected: c.disappearing,
                    onChanged: (v) => app.setDisappearing(c.id, v),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Card(
                children: [
                  _InfoRow(icon: Icons.forum_rounded, label: 'Сообщений', value: '${msgs.length}'),
                  _InfoRow(icon: Icons.mic_rounded, label: 'Голосовых', value: '$voice'),
                  _InfoRow(
                    icon: Icons.phone_android_rounded,
                    label: 'Где хранится',
                    value: 'только на телефоне',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _Card(
                children: [
                  _DangerRow(
                    icon: Icons.cleaning_services_rounded,
                    label: 'Очистить переписку',
                    onTap: () {
                      app.clearChat(c.id);
                      showVeilToast(
                        context,
                        'Переписка стёрта с устройства',
                        icon: Icons.delete_sweep_rounded,
                      );
                    },
                  ),
                  _DangerRow(
                    icon: Icons.block_rounded,
                    label: c.blocked ? 'Разблокировать' : 'Заблокировать',
                    onTap: () => app.toggleBlocked(c.id),
                  ),
                  _DangerRow(
                    icon: Icons.person_remove_rounded,
                    label: 'Удалить из друзей',
                    onTap: () => _confirmDelete(context, c),
                  ),
                ],
              ),
            ],
          ),
          Positioned(
            top: top + 4,
            left: 8,
            child: Glass(
              radius: 22,
              blur: 10,
              child: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: Icon(Icons.arrow_back_ios_new_rounded, color: vc.text, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderGlow extends StatelessWidget {
  const _HeaderGlow({required this.colors});
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [0, 0.45],
          colors: [
            colors.first.withValues(alpha: vc.dark ? 0.35 : 0.22),
            vc.bg,
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Pressable(
          onTap: onTap,
          child: Glass(
            radius: 18,
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                GradientIcon(icon, size: 24),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(color: vc.textDim, fontSize: 12)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: vc.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: vc.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<int> values;
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < values.length; i++)
          Pressable(
            onTap: () => onChanged(values[i]),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                gradient: values[i] == selected ? acc.gradient : null,
                color: values[i] == selected ? null : vc.elevated,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                labels[i],
                style: TextStyle(
                  color: values[i] == selected ? acc.onAccent : vc.textDim,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: vc.textDim),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(color: vc.text)),
          const Spacer(),
          Text(value, style: TextStyle(color: vc.textDim)),
        ],
      ),
    );
  }
}

class _DangerRow extends StatelessWidget {
  const _DangerRow({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: VeilColors.danger),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(color: VeilColors.danger, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _confirmDelete(BuildContext context, Contact c) async {
  final app = context.appRead;
  final vc = app.colors;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: vc.elevated,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      title: Text('Удалить ${c.name}?', style: TextStyle(color: vc.text)),
      content: Text(
        'Контакт и вся переписка будут стёрты с этого телефона. Чтобы снова '
        'переписываться, нужно будет заново обменяться кодами.',
        style: TextStyle(color: vc.textDim, height: 1.4),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text('Отмена', style: TextStyle(color: vc.textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Удалить', style: TextStyle(color: VeilColors.danger)),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  Navigator.of(context).popUntil((r) => r.isFirst);
  await app.deleteContact(c.id);
  if (context.mounted) {
    showVeilToast(context, '${c.name} удалён(а)', icon: Icons.person_remove_rounded);
  }
}
