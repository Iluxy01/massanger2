import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import '../widgets/visual.dart';
import 'chat_look.dart';
import 'chat_screen.dart';

const _groupEmojis = ['👥', '🏕️', '🎉', '💼', '🎮', '📚', '⚽', '🎵', '🍕', '✈️', '🏠', '❤️'];
const _channelEmojis = ['📢', '📰', '💡', '🎨', '🎬', '🎵', '📷', '🧠', '💻', '🌍', '⚡', '❤️'];

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
  const CreateGroupScreen({super.key, this.channel = false});

  /// Канал: пишу только я, подписчиков можно добавить и позже.
  final bool channel;

  static Route<void> route({bool channel = false}) =>
      MaterialPageRoute(builder: (_) => CreateGroupScreen(channel: channel));

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _name = TextEditingController();
  late String _emoji = (widget.channel ? _channelEmojis : _groupEmojis).first;
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
    if (name.isEmpty || (_members.isEmpty && !widget.channel) || _busy) return;
    setState(() => _busy = true);
    final app = context.appRead;
    app.tick(HapticKind.medium);
    final title = name.length > 40 ? name.substring(0, 40) : name;
    final g = widget.channel
        ? await app.createChannel(
            name: title,
            emoji: _emoji,
            colorIndex: _color,
            pubs: _members.toList(),
          )
        : await app.createGroup(
            name: title,
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
    final channel = widget.channel;
    final ready = _name.text.trim().isNotEmpty && (_members.isNotEmpty || channel);
    final max = channel ? GroupInfo.maxSubscribers : GroupInfo.maxMembers - 1;
    final emojis = channel ? _channelEmojis : _groupEmojis;

    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: Text(channel ? 'Новый канал' : 'Новая группа'),
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
                      hintText: channel ? 'Название канала' : 'Название группы',
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
                      for (final e in emojis)
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
                  if (channel) ...[
                    Glass(
                      radius: 18,
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        'Публикуешь только ты. Подписчики не видят друг друга и не могут '
                        'писать в канал. Позвать можно друзей сейчас, а остальных — '
                        'по пригласительной ссылке из описания канала.',
                        style: TextStyle(color: vc.textDim, fontSize: 13, height: 1.4),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  Text(
                    channel
                        ? 'Подписать друзей · ${_members.length}'
                        : 'Участники · ${_members.length}',
                    style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  if (friends.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(
                        channel
                            ? 'Друзей пока нет — пригласи подписчиков ссылкой после создания.'
                            : 'Сначала добавь друзей по QR-коду — потом их можно позвать в группу.',
                        style: TextStyle(color: vc.textDim),
                      ),
                    ),
                  for (final c in friends)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _members.contains(c.id),
                      onChanged: (v) => setState(() {
                        if (v == true && _members.length < max) {
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
                label: channel ? 'Создать канал' : 'Создать группу',
                icon: channel ? Icons.campaign_rounded : Icons.group_add_rounded,
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
          title: Text(group.isChannel ? 'Канал' : 'Группа', style: TextStyle(color: vc.text)),
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
                  for (final e in group.isChannel ? _channelEmojis : _groupEmojis)
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
      title: info.channel ? 'Подписать друзей' : 'Добавить в группу',
      action: info.channel ? 'Подписать' : 'Добавить',
      max: info.limit - info.members.length,
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
    final channel = info.channel;
    // В канале подписчиков видит только автор.
    final showMembers = !channel || admin;
    final listed = channel ? members.where((m) => m.pub != info.admin).toList() : members;

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
              channel
                  ? (info.left
                        ? 'ты не подписан(а)'
                        : admin
                        ? 'канал · ${subscribersLabel(info.subscribers)}'
                        : 'канал · автор: ${app.memberName(g.id, info.admin)}')
                  : info.left
                  ? 'ты больше не участник'
                  : membersLabel(info.members.length),
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
                    channel
                        ? 'Каждый пост уходит каждому подписчику отдельным зашифрованным '
                              'конвертом. Сервера нет, подписчики не видят друг друга.'
                        : 'Сообщение уходит каждому участнику отдельным зашифрованным конвертом. '
                              'Сервера с перепиской нет.',
                    style: TextStyle(color: vc.textDim, fontSize: 12.5, height: 1.35),
                  ),
                ),
              ],
            ),
          ),
          if (channel && admin) ...[const SizedBox(height: 18), _ChannelInvite(channel: g)],
          const SizedBox(height: 18),
          if (showMembers)
            Row(
              children: [
                Expanded(
                  child: Text(
                    channel ? 'Подписчики · ${info.subscribers}' : 'Участники',
                    style: TextStyle(color: vc.textDim, fontWeight: FontWeight.w700),
                  ),
                ),
                if (admin && info.members.length < info.limit)
                  TextButton.icon(
                    onPressed: () => _add(context),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                    label: Text(channel ? 'Подписать' : 'Добавить'),
                  ),
              ],
            ),
          if (showMembers && channel && listed.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'Пока никого. Подпиши друзей или отправь ссылку.',
                style: TextStyle(color: vc.textDim),
              ),
            ),
          for (final m in showMembers ? listed : const <GroupMember>[])
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
                      tooltip: channel ? 'Отписать' : 'Удалить из группы',
                      icon: Icon(Icons.remove_circle_outline_rounded, color: vc.textDim),
                      onPressed: () async {
                        final name = app.memberName(g.id, m.pub);
                        if (await _confirm(
                          context,
                          channel ? 'Отписать $name?' : 'Удалить $name?',
                          channel
                              ? '$name больше не будет получать посты канала.'
                              : '$name больше не будет получать сообщения группы.',
                          channel ? 'Отписать' : 'Удалить',
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const GradientIcon(Icons.palette_rounded, size: 22),
            title: Text('Оформление чата', style: TextStyle(color: vc.text)),
            subtitle: Text(
              'Свой фон и цвет — только у тебя',
              style: TextStyle(color: vc.textDim, fontSize: 12.5),
            ),
            trailing: Icon(Icons.chevron_right_rounded, color: vc.textFaint),
            onTap: () => Navigator.of(context).push(ChatLookScreen.route(g)),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              final nav = Navigator.of(context);
              final what = channel ? 'канал' : 'группу';
              if (info.left) {
                if (await _confirm(
                  context,
                  'Удалить $what?',
                  channel
                      ? 'Посты канала будут стёрты с этого телефона.'
                      : 'Переписка группы будет стёрта с этого телефона.',
                  'Удалить',
                )) {
                  await app.deleteContact(g.id);
                  nav.popUntil((r) => r.isFirst);
                }
                return;
              }
              final (title, text, action) = channel
                  ? admin
                        ? (
                            'Закрыть канал?',
                            'Подписчики увидят, что канал закрыт, и новых постов не будет. '
                                'Посты останутся у всех.',
                            'Закрыть',
                          )
                        : (
                            'Отписаться?',
                            'Новые посты больше не придут. Уже полученные останутся.',
                            'Отписаться',
                          )
                  : (
                      'Выйти из группы?',
                      'Остальные увидят, что ты вышел(а). Переписка останется у тебя.',
                      'Выйти',
                    );
              if (await _confirm(context, title, text, action)) {
                await app.leaveGroup(g.id);
              }
            },
            icon: Icon(
              info.left ? Icons.delete_outline_rounded : Icons.logout_rounded,
              color: VeilColors.danger,
            ),
            label: Text(
              info.left
                  ? 'Удалить ${channel ? 'канал' : 'группу'}'
                  : channel
                  ? (admin ? 'Закрыть канал' : 'Отписаться')
                  : 'Выйти из группы',
              style: const TextStyle(color: VeilColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// «3 подписчика», «5 подписчиков».
String subscribersLabel(int n) {
  final d = n % 10, h = n % 100;
  final word = d == 1 && h != 11
      ? 'подписчик'
      : d >= 2 && d <= 4 && (h < 12 || h > 14)
      ? 'подписчика'
      : 'подписчиков';
  return '$n $word';
}

/// Пригласительная ссылка канала: QR, «поделиться», «новая ссылка».
class _ChannelInvite extends StatelessWidget {
  const _ChannelInvite({required this.channel});
  final Contact channel;

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final link = app.channelLink(channel.id);
    if (link == null) return const SizedBox.shrink();
    return Glass(
      radius: 22,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            'Пригласительная ссылка',
            style: TextStyle(color: vc.text, fontWeight: FontWeight.w700, fontSize: 16),
          ),
          const SizedBox(height: 4),
          Text(
            'По ней подпишется любой, у кого есть Veil: отсканирует QR в «Добавить друга» '
            'или вставит ссылку. Ты при этом должен(на) хоть иногда быть в сети.',
            textAlign: TextAlign.center,
            style: TextStyle(color: vc.textDim, fontSize: 12.5, height: 1.35),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
            child: QrImageView(
              data: link,
              size: 180,
              padding: EdgeInsets.zero,
              gapless: true,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: Colors.white,
              eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0F0F18)),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Color(0xFF0F0F18),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    final text = 'Подписывайся на канал «${channel.name}» в Veil: $link';
                    try {
                      await SharePlus.instance.share(ShareParams(text: text));
                    } catch (_) {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        showVeilToast(context, 'Ссылка скопирована', icon: Icons.copy_rounded);
                      }
                    }
                  },
                  icon: const Icon(Icons.ios_share_rounded, size: 18),
                  label: const Text('Поделиться'),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () async {
                    await app.resetChannelLink(channel.id);
                    if (context.mounted) {
                      showVeilToast(
                        context,
                        'Новая ссылка готова — старая больше не работает',
                        icon: Icons.link_rounded,
                      );
                    }
                  },
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Новая ссылка'),
                ),
              ),
            ],
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

/// Выбрать чаты (друзей, группы, «Заметки») — например, куда переслать.
/// Можно отметить несколько сразу. null или пусто — передумали.
Future<List<Contact>?> pickChats(BuildContext context, {String title = 'Переслать в…'}) =>
    showModalBottomSheet<List<Contact>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ChatsPicker(title: title),
    );

class _ChatsPicker extends StatefulWidget {
  const _ChatsPicker({required this.title});
  final String title;

  @override
  State<_ChatsPicker> createState() => _ChatsPickerState();
}

class _ChatsPickerState extends State<_ChatsPicker> {
  final _picked = <String>[];
  late final Contact _notes = context.appRead.notes();

  static String _chats(int n) {
    final d = n % 10, h = n % 100;
    final w = d == 1 && h != 11
        ? 'чат'
        : d >= 2 && d <= 4 && (h < 12 || h > 14)
        ? 'чата'
        : 'чатов';
    return '$n $w';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    // «Заметки» первыми, потом недавние чаты, потом остальные друзья.
    final seen = <String>{};
    final chats = [
      for (final c in [_notes, ...app.chatList, ...app.archivedChats, ...app.friends])
        if (!c.blocked && !(c.group?.left ?? false) && seen.add(c.id)) c,
    ];
    final byId = {for (final c in chats) c.id: c};
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
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(color: vc.text, fontSize: 20, fontWeight: FontWeight.w800),
                    ),
                  ),
                  if (_picked.isNotEmpty)
                    Text(
                      'Выбрано: ${_picked.length}',
                      style: TextStyle(color: vc.textDim, fontSize: 13),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scroll,
                itemCount: chats.length,
                itemBuilder: (_, i) {
                  final c = chats[i];
                  final on = _picked.contains(c.id);
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    leading: Avatar.contact(c, size: 44, showOnline: false),
                    title: Text(
                      c.name,
                      style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
                    ),
                    subtitle: c.isNotes
                        ? Text(
                            'Только на этом телефоне',
                            style: TextStyle(color: vc.textDim, fontSize: 12.5),
                          )
                        : c.group == null
                        ? null
                        : Text(
                            membersLabel(c.group!.members.length),
                            style: TextStyle(color: vc.textDim, fontSize: 12.5),
                          ),
                    trailing: AnimatedContainer(
                      duration: const Duration(milliseconds: 180).by(context),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: on ? acc.gradient : null,
                        border: on ? null : Border.all(color: vc.textFaint, width: 2),
                      ),
                      child: on ? Icon(Icons.check_rounded, size: 16, color: acc.onAccent) : null,
                    ),
                    onTap: () {
                      app.tick(HapticKind.selection);
                      setState(() => on ? _picked.remove(c.id) : _picked.add(c.id));
                    },
                    // Долгое нажатие — сразу в этот один чат.
                    onLongPress: () => Navigator.pop(context, [c]),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: AccentButton(
                  label: _picked.length > 1 ? 'Переслать в ${_chats(_picked.length)}' : 'Переслать',
                  icon: Icons.send_rounded,
                  onTap: _picked.isEmpty
                      ? null
                      : () => Navigator.pop(context, [for (final id in _picked) ?byId[id]]),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
