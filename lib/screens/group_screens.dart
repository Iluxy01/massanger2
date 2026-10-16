import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'chat_screen.dart';

const _groupEmojis = ['👥', '🏕️', '🎉', '💼', '🎮', '📚', '⚽', '🎵', '🍕', '✈️', '🏠', '❤️'];

/// Выбрать друзей (несколько). null — передумали.
Future<List<String>?> pickFriends(
  BuildContext context, {
  Set<String> exclude = const {},
  String title = 'Выбери друзей',
  String action = 'Готово',
  int max = GroupInfo.maxMembers - 1,
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  backgroundColor: Colors.transparent,
  builder: (_) => _FriendPicker(exclude: exclude, title: title, action: action, max: max),
);

class _FriendPicker extends StatefulWidget {
  const _FriendPicker({
    required this.exclude,
    required this.title,
    required this.action,
    required this.max,
  });

  final Set<String> exclude;
  final String title;
  final String action;
  final int max;

  @override
  State<_FriendPicker> createState() => _FriendPickerState();
}

class _FriendPickerState extends State<_FriendPicker> {
  final _picked = <String>{};

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final friends = [
      for (final c in app.friends)
        if (!c.blocked && !c.request && !widget.exclude.contains(c.id)) c,
    ]..sort((a, b) => a.name.compareTo(b.name));
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      expand: false,
      builder: (_, scroll) => Material(
        color: vc.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(color: vc.text, fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '${_picked.length}/${widget.max}',
                    style: TextStyle(color: vc.textDim, fontSize: 13),
                  ),
                ],
              ),
            ),
            Expanded(
              child: friends.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'Некого добавить — сначала добавь друзей по QR-коду',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: vc.textDim),
                        ),
                      ),
                    )
                  : ListView(
                      controller: scroll,
                      children: [
                        for (final c in friends)
                          CheckboxListTile(
                            value: _picked.contains(c.id),
                            onChanged: (v) => setState(() {
                              if (v == true && _picked.length < widget.max) {
                                _picked.add(c.id);
                              } else {
                                _picked.remove(c.id);
                              }
                            }),
                            secondary: Avatar.contact(c, size: 42),
                            title: Text(
                              c.name,
                              style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
                            ),
                            activeColor: context.accent.mid,
                            controlAffinity: ListTileControlAffinity.trailing,
                          ),
                      ],
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: AccentButton(
                  label: widget.action,
                  icon: Icons.check_rounded,
                  onTap: _picked.isEmpty ? null : () => Navigator.of(context).pop(_picked.toList()),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── Новая группа ─────────────────────────────

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const CreateGroupScreen());

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _name = TextEditingController();
  String _emoji = _groupEmojis.first;
  int _color = 1;
  final _members = <String>{};
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _name.text.trim();
    if (name.isEmpty || _members.isEmpty || _busy) return;
    setState(() => _busy = true);
    final app = context.appRead;
    app.tick(HapticKind.medium);
    final g = await app.createGroup(
      name: name.length > 40 ? name.substring(0, 40) : name,
      emoji: _emoji,
      colorIndex: _color,
      pubs: _members.toList(),
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(ChatScreen.route(g));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final friends = [
      for (final c in app.friends)
        if (!c.blocked && !c.request) c,
    ]..sort((a, b) => a.name.compareTo(b.name));
    final ready = _name.text.trim().isNotEmpty && _members.isNotEmpty;

    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Новая группа'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                children: [
                  Center(
                    child: Avatar(emoji: _emoji, colors: gradientAt(_color), size: 96),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _name,
                    maxLength: 40,
                    onChanged: (_) => setState(() {}),
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: 'Название группы',
                      hintStyle: TextStyle(color: vc.textFaint),
                      filled: true,
                      fillColor: vc.surface,
                      counterText: '',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      for (final e in _groupEmojis)
                        Pressable(
                          onTap: () => setState(() => _emoji = e),
                          child: Container(
                            width: 44,
                            height: 44,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: e == _emoji ? acc.a.withValues(alpha: 0.25) : vc.surface,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: e == _emoji ? acc.mid : Colors.transparent),
                            ),
                            child: Text(e, style: const TextStyle(fontSize: 22)),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < avatarGradients.length; i++)
                        Pressable(
                          onTap: () => setState(() => _color = i),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: i == _color ? 30 : 24,
                            height: i == _color ? 30 : 24,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(colors: avatarGradients[i]),
                              border: i == _color ? Border.all(color: vc.text, width: 2) : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Участники · ${_members.length}',
                    style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  if (friends.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        'Сначала добавь друзей по QR-коду — потом их можно позвать в группу.',
                        style: TextStyle(color: vc.textDim),
                      ),
                    ),
                  for (final c in friends)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _members.contains(c.id),
                      onChanged: (v) => setState(() {
                        if (v == true && _members.length < GroupInfo.maxMembers - 1) {
                          _members.add(c.id);
                        } else {
                          _members.remove(c.id);
                        }
                      }),
                      secondary: Avatar.contact(c, size: 42),
                      title: Text(
                        c.name,
                        style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
                      ),
                      activeColor: acc.mid,
                      controlAffinity: ListTileControlAffinity.trailing,
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: AccentButton(
                label: 'Создать группу',
                icon: Icons.group_add_rounded,
                onTap: ready && !_busy ? _create : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────────── О группе ─────────────────────────────

class GroupInfoScreen extends StatelessWidget {
  const GroupInfoScreen({super.key, required this.group});

  final Contact group;

  static Route<void> route(Contact g) =>
      MaterialPageRoute(builder: (_) => GroupInfoScreen(group: g));

  Future<void> _edit(BuildContext context) async {
    final app = context.appRead;
    final vc = app.colors;
    final name = TextEditingController(text: group.name);
    var emoji = group.emoji;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          backgroundColor: vc.elevated,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text('Группа', style: TextStyle(color: vc.text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                maxLength: 40,
                autofocus: true,
                style: TextStyle(color: vc.text),
                decoration: const InputDecoration(hintText: 'Название'),
              ),
              Wrap(
                spacing: 4,
                children: [
                  for (final e in _groupEmojis)
                    InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => set(() => emoji = e),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: e == emoji ? context.accent.a.withValues(alpha: 0.25) : null,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(e, style: const TextStyle(fontSize: 20)),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Отмена', style: TextStyle(color: vc.textDim)),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
          ],
        ),
      ),
    );
    final n = name.text.trim();
    name.dispose();
    if (ok == true && n.isNotEmpty) await app.editGroup(group.id, name: n, emoji: emoji);
  }

  Future<void> _add(BuildContext context) async {
    final app = context.appRead;
    final info = group.group!;
    final picked = await pickFriends(
      context,
      exclude: {for (final m in info.members) m.pub},
      title: 'Добавить в группу',
      action: 'Добавить',
      max: GroupInfo.maxMembers - info.members.length,
    );
    if (picked != null && picked.isNotEmpty) await app.addMembers(group.id, picked);
  }

  Future<bool> _confirm(BuildContext context, String title, String text, String action) async {
    final vc = context.vc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text(title, style: TextStyle(color: vc.text)),
        content: Text(text, style: TextStyle(color: vc.textDim, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Отмена', style: TextStyle(color: vc.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action, style: const TextStyle(color: VeilColors.danger)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final g = group;
    final info = g.group!;
    final admin = info.admin == app.me && !info.left;
    final members = [...info.members]
      ..sort((a, b) {
        if (a.pub == info.admin) return -1;
        if (b.pub == info.admin) return 1;
        return app.memberName(g.id, a.pub).compareTo(app.memberName(g.id, b.pub));
      });
    final muted = app.muted.contains(g.id);

    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        actions: [
          if (admin)
            IconButton(
              tooltip: 'Изменить',
              onPressed: () => _edit(context),
              icon: const Icon(Icons.edit_rounded),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 40),
        children: [
          Center(
            child: Hero(tag: 'avatar-${g.id}', child: Avatar.contact(g, size: 110)),
          ),
          const SizedBox(height: 14),
          Center(
            child: Text(
              g.name,
              textAlign: TextAlign.center,
              style: TextStyle(color: vc.text, fontSize: 26, fontWeight: FontWeight.w800),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              info.left ? 'ты больше не участник' : membersLabel(info.members.length),
              style: TextStyle(color: vc.textDim),
            ),
          ),
          const SizedBox(height: 18),
          Glass(
            radius: 20,
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const GradientIcon(Icons.lock_rounded, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Сообщение уходит каждому участнику отдельным зашифрованным конвертом. '
                    'Сервера с перепиской нет.',
                    style: TextStyle(color: vc.textDim, fontSize: 12.5, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Участники',
                  style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w700),
                ),
              ),
              if (admin && info.members.length < GroupInfo.maxMembers)
                TextButton.icon(
                  onPressed: () => _add(context),
                  icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                  label: const Text('Добавить'),
                ),
            ],
          ),
          for (final m in members)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Avatar(emoji: m.emoji, colors: m.colors, size: 42),
              title: Text(
                m.pub == app.me ? 'Ты' : app.memberName(g.id, m.pub),
                style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
              ),
              subtitle: m.pub == info.admin
                  ? Text(
                      'администратор',
                      style: TextStyle(color: context.accent.mid, fontSize: 12.5),
                    )
                  : null,
              trailing: admin && m.pub != app.me
                  ? IconButton(
                      tooltip: 'Удалить из группы',
                      icon: Icon(Icons.remove_circle_outline_rounded, color: vc.textDim),
                      onPressed: () async {
                        final name = app.memberName(g.id, m.pub);
                        if (await _confirm(
                          context,
                          'Удалить $name?',
                          '$name больше не будет получать сообщения группы.',
                          'Удалить',
                        )) {
                          await app.removeMember(g.id, m.pub);
                        }
                      },
                    )
                  : null,
            ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: !muted,
            onChanged: (_) => app.toggleMute(g.id),
            title: Text('Уведомления', style: TextStyle(color: vc.text)),
            activeThumbColor: context.accent.mid,
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final nav = Navigator.of(context);
              if (info.left) {
                if (await _confirm(
                  context,
                  'Удалить группу?',
                  'Переписка группы будет стёрта с этого телефона.',
                  'Удалить',
                )) {
                  await app.deleteContact(g.id);
                  nav.popUntil((r) => r.isFirst);
                }
                return;
              }
              if (await _confirm(
                context,
                'Выйти из группы?',
                'Остальные увидят, что ты вышел(а). Переписка останется у тебя.',
                'Выйти',
              )) {
                await app.leaveGroup(g.id);
              }
            },
            icon: Icon(
              info.left ? Icons.delete_outline_rounded : Icons.logout_rounded,
              color: VeilColors.danger,
            ),
            label: Text(
              info.left ? 'Удалить группу' : 'Выйти из группы',
              style: const TextStyle(color: VeilColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// «3 участника», «5 участников».
String membersLabel(int n) {
  final d = n % 10, h = n % 100;
  final word = d == 1 && h != 11
      ? 'участник'
      : d >= 2 && d <= 4 && (h < 12 || h > 14)
      ? 'участника'
      : 'участников';
  return '$n $word';
}
