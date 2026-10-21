import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'chat_screen.dart';
import 'group_screens.dart';
import 'settings_tab.dart' show openVault;
import 'stories.dart';
import '../widgets/visual.dart';

class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});

  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  bool _searching = false;
  bool _compact = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final c = _scroll.offset > 56;
      if (c != _compact) setState(() => _compact = c);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) _search.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final q = _search.text.trim().toLowerCase();
    var chats = app.chatList;
    if (q.isNotEmpty) {
      chats = chats
          .where(
            (c) =>
                c.name.toLowerCase().contains(q) ||
                (app.lastMessage(c.id)?.preview.toLowerCase().contains(q) ?? false),
          )
          .toList();
    }
    final online = app.friends.where((c) => c.online).toList();
    final top = MediaQuery.paddingOf(context).top;

    return Stack(
      children: [
        CustomScrollView(
          controller: _scroll,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, top + 12, 12, 0),
                child: Row(
                  children: [
                    GestureDetector(
                      // Долгое нажатие на «Veil» — тайник (если он есть).
                      onLongPress: app.vaultSet && !app.decoy ? () => openVault(context) : null,
                      child: GradientText(
                        'Veil',
                        style: const TextStyle(
                          fontSize: 38,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    const _E2EChip(),
                    if (app.vaultOpen && !app.decoy) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Тайник открыт до блокировки',
                        child: Icon(Icons.lock_open_rounded, color: app.accent.mid, size: 20),
                      ),
                    ],
                    if (app.ultra) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: 'Режим «Ультра»: экономия батареи',
                        child: Icon(Icons.bolt_rounded, color: app.accent.mid, size: 22),
                      ),
                    ],
                    const Spacer(),
                    _RoundIcon(
                      icon: _searching ? Icons.close_rounded : Icons.search_rounded,
                      onTap: _toggleSearch,
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: AnimatedSize(
                duration: const Duration(milliseconds: 300).by(context),
                curve: Curves.easeOutCubic,
                child: _searching
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                        child: Glass(
                          radius: 16,
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: TextField(
                            controller: _search,
                            autofocus: true,
                            onChanged: (_) => setState(() {}),
                            style: TextStyle(color: vc.text),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: 'Поиск по чатам',
                              hintStyle: TextStyle(color: vc.textFaint),
                              icon: Icon(Icons.search_rounded, color: vc.textDim, size: 20),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ),
            if (!_searching) SliverToBoxAdapter(child: StoriesRow(online: online)),
            if (!_searching && app.archivedChats.isNotEmpty)
              SliverToBoxAdapter(child: _ArchiveRow(count: app.archivedChats.length)),
            if (chats.isEmpty)
              SliverFillRemaining(hasScrollBody: false, child: _EmptyState(searching: q.isNotEmpty))
            else
              SliverPadding(
                padding: const EdgeInsets.only(top: 8, bottom: 140),
                sliver: SliverList.builder(
                  itemCount: chats.length,
                  itemBuilder: (_, i) => Reveal(
                    key: ValueKey(chats[i].id),
                    index: i,
                    child: _ChatTile(contact: chats[i]),
                  ),
                ),
              ),
          ],
        ),
        // Компактная стеклянная шапка, появляется при прокрутке.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !_compact,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 220).by(context),
              opacity: _compact ? 1 : 0,
              child: Glass(
                blur: 20,
                radius: 0,
                border: false,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, top + 8, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        'Чаты',
                        style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.lock_rounded, size: 14, color: vc.textDim),
                      const Spacer(),
                      _RoundIcon(
                        icon: Icons.arrow_upward_rounded,
                        onTap: () => _scroll.animateTo(
                          0,
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeOutCubic,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 22,
          bottom: MediaQuery.paddingOf(context).bottom + 92,
          child: _NewChatButton(),
        ),
      ],
    );
  }
}

class _E2EChip extends StatelessWidget {
  const _E2EChip();

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Pressable(
      onTap: () => showVeilToast(
        context,
        'Все чаты зашифрованы. Сообщения хранятся только на устройствах собеседников.',
        icon: Icons.lock_rounded,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: VeilColors.success.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: VeilColors.success.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_rounded, size: 12, color: VeilColors.success),
            const SizedBox(width: 4),
            Text(
              'E2E',
              style: TextStyle(
                color: vc.dark ? VeilColors.success : const Color(0xFF14946A),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      scale: 0.85,
      onTap: onTap,
      child: Glass(
        radius: 22,
        child: SizedBox(
          width: 44,
          height: 44,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 250).by(context),
            transitionBuilder: (c, a) => RotationTransition(
              turns: Tween(begin: 0.75, end: 1.0).animate(a),
              child: FadeTransition(opacity: a, child: c),
            ),
            child: Icon(icon, key: ValueKey(icon), color: context.vc.text, size: 22),
          ),
        ),
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({required this.contact});

  final Contact contact;

  Future<bool> _confirmClear(BuildContext context) async {
    final vc = context.vc;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: vc.elevated,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text('Удалить чат с ${contact.name}?', style: TextStyle(color: vc.text)),
        content: Text(
          'Переписка будет стёрта с этого телефона навсегда. Восстановить её не получится — копий на сервере нет.',
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
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final acc = app.accent;
    final c = contact;
    // Чат может быть в списке только из-за черновика — без сообщений.
    final last = app.lastMessage(c.id);
    final unread = app.unread[c.id] ?? 0;
    final pinned = app.pinned.contains(c.id);
    final typing = app.typingIndicators && app.typing.contains(c.id);
    final typer = app.typingBy[c.id];
    final draft = app.drafts[c.id];

    Widget preview;
    if (typing) {
      preview = Row(
        key: const ValueKey('typing'),
        children: [
          Flexible(
            child: GradientText(
              typer == null ? 'печатает' : '${app.memberName(c.id, typer)} печатает',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          const TypingDots(size: 5),
        ],
      );
    } else {
      final String body;
      if (draft != null || last == null) {
        body = draft ?? '';
      } else {
        // «Скрывать текст в списке» — только что сообщение есть.
        body = app.hidePreviews && last.kind != MsgKind.event
            ? (unread > 0 ? 'Новое сообщение' : 'Сообщение')
            : app.previewOf(c.id, last);
      }
      preview = Text.rich(
        key: ValueKey('text${last?.id}$draft'),
        TextSpan(
          children: [
            if (draft != null)
              const TextSpan(
                text: 'Черновик: ',
                style: TextStyle(color: VeilColors.danger),
              )
            else if (last != null && last.mine && last.kind != MsgKind.event)
              TextSpan(
                text: 'Вы: ',
                style: TextStyle(color: vc.text.withValues(alpha: 0.8)),
              ),
            TextSpan(text: body),
          ],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: vc.textDim, fontSize: 14),
      );
    }

    return Dismissible(
      key: ValueKey('dismiss-${c.id}'),
      background: _SwipeBg(
        alignment: Alignment.centerLeft,
        gradient: acc.gradient,
        icon: pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded,
        label: pinned ? 'Открепить' : 'Закрепить',
        color: acc.onAccent,
      ),
      secondaryBackground: const _SwipeBg(
        alignment: Alignment.centerRight,
        gradient: LinearGradient(colors: [Color(0xFFFF7A45), VeilColors.danger]),
        icon: Icons.delete_rounded,
        label: 'Удалить',
        color: Colors.white,
      ),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          app.tick(HapticKind.medium);
          app.togglePin(c.id);
          return false;
        }
        return _confirmClear(context);
      },
      onDismissed: (_) => app.clearChat(c.id),
      child: Pressable(
        scale: 0.98,
        onTap: () => Navigator.of(context).push(ChatScreen.route(c)),
        onLongPress: () => _quickActions(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Hero(tag: 'avatar-${c.id}', child: Avatar.contact(c, size: 58)),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  c.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: vc.text,
                                    fontSize: 16.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              if (c.verified) ...[
                                const SizedBox(width: 4),
                                const GradientIcon(Icons.verified_rounded, size: 16),
                              ],
                              if (context.appRead.birthdayOf(c) == 0)
                                const Padding(
                                  padding: EdgeInsets.only(left: 4),
                                  child: Text('🎂', style: TextStyle(fontSize: 15)),
                                ),
                              if (c.isChannel) ...[
                                const SizedBox(width: 4),
                                Icon(Icons.campaign_rounded, size: 16, color: vc.textDim),
                              ],
                              if (app.muted.contains(c.id)) ...[
                                const SizedBox(width: 4),
                                Icon(Icons.volume_off_rounded, size: 15, color: vc.textFaint),
                              ],
                            ],
                          ),
                        ),
                        if (last != null && last.mine && !typing && !c.isNotes) ...[
                          StatusTicks(status: last.status),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          fmtListTime(app.chatTime(c.id)),
                          style: TextStyle(
                            color: unread > 0 ? acc.mid : vc.textFaint,
                            fontSize: 12.5,
                            fontWeight: unread > 0 ? FontWeight.w700 : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250).by(context),
                            layoutBuilder: (cur, prev) =>
                                Stack(alignment: Alignment.centerLeft, children: [...prev, ?cur]),
                            child: preview,
                          ),
                        ),
                        if (pinned && unread == 0)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Transform.rotate(
                              angle: 0.6,
                              child: Icon(Icons.push_pin_rounded, size: 16, color: vc.textFaint),
                            ),
                          ),
                        if (unread > 0) ...[
                          const SizedBox(width: 6),
                          _UnreadBadge(count: unread, muted: app.muted.contains(c.id)),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _quickActions(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(12),
        child: Glass(
          radius: 28,
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar.contact(contact, size: 64),
              const SizedBox(height: 8),
              Text(
                contact.name,
                style: TextStyle(color: vc.text, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              _SheetAction(
                icon: Icons.push_pin_rounded,
                label: app.pinned.contains(contact.id) ? 'Открепить' : 'Закрепить',
                onTap: () {
                  app.togglePin(contact.id);
                  Navigator.pop(ctx);
                },
              ),
              _SheetAction(
                icon: app.muted.contains(contact.id)
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                label: app.muted.contains(contact.id) ? 'Включить звук' : 'Без звука',
                onTap: () {
                  app.toggleMute(contact.id);
                  Navigator.pop(ctx);
                },
              ),
              if ((app.unread[contact.id] ?? 0) > 0)
                _SheetAction(
                  icon: Icons.mark_chat_read_rounded,
                  label: 'Отметить прочитанным',
                  onTap: () {
                    app.markRead(contact.id);
                    Navigator.pop(ctx);
                  },
                )
              else
                _SheetAction(
                  icon: Icons.mark_chat_unread_rounded,
                  label: 'Пометить непрочитанным',
                  onTap: () {
                    app.markUnread(contact.id);
                    Navigator.pop(ctx);
                  },
                ),
              if (app.vaultSet && !app.decoy)
                _SheetAction(
                  icon: contact.hidden ? Icons.lock_open_rounded : Icons.lock_rounded,
                  label: contact.hidden ? 'Вернуть из тайника' : 'Спрятать в тайник',
                  onTap: () {
                    app.setHidden(contact.id, !contact.hidden);
                    Navigator.pop(ctx);
                  },
                ),
              _SheetAction(
                icon: app.archived.contains(contact.id)
                    ? Icons.unarchive_rounded
                    : Icons.archive_rounded,
                label: app.archived.contains(contact.id) ? 'Вернуть из архива' : 'В архив',
                onTap: () {
                  app.toggleArchive(contact.id);
                  Navigator.pop(ctx);
                },
              ),
              _SheetAction(
                icon: Icons.delete_rounded,
                label: 'Удалить чат',
                danger: true,
                onTap: () async {
                  Navigator.pop(ctx);
                  if (await _confirmClear(context)) app.clearChat(contact.id);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = danger ? VeilColors.danger : context.vc.text;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
      onTap: onTap,
    );
  }
}

class _SwipeBg extends StatelessWidget {
  const _SwipeBg({
    required this.alignment,
    required this.gradient,
    required this.icon,
    required this.label,
    required this.color,
  });

  final Alignment alignment;
  final Gradient gradient;
  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      alignment: alignment,
      decoration: BoxDecoration(gradient: gradient, borderRadius: BorderRadius.circular(22)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  const _UnreadBadge({required this.count, required this.muted});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final vc = context.vc;
    return TweenAnimationBuilder<double>(
      key: ValueKey(count),
      tween: Tween(begin: 0.4, end: 1),
      duration: const Duration(milliseconds: 450).by(context),
      curve: Curves.elasticOut,
      builder: (_, s, c) => Transform.scale(scale: s, child: c),
      child: Container(
        constraints: const BoxConstraints(minWidth: 22),
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: muted ? null : acc.gradient,
          color: muted ? vc.textFaint : null,
          borderRadius: BorderRadius.circular(11),
          boxShadow: muted
              ? null
              : [BoxShadow(color: acc.mid.withValues(alpha: 0.5), blurRadius: 10)],
        ),
        child: Text(
          '$count',
          style: TextStyle(
            color: muted ? vc.bg : acc.onAccent,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _NewChatButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    final skin = context.skin;
    return Pressable(
      scale: 0.88,
      onTap: () => _pickContact(context),
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          gradient: acc.gradient,
          borderRadius: BorderRadius.circular(22 * skin.radius),
          boxShadow: [
            BoxShadow(
              color: acc.mid.withValues(alpha: skin.id == 1 ? 0.3 : 0.55),
              blurRadius: skin.glow ? 32 : 24,
              offset: Offset(0, skin.glow ? 0 : 8),
            ),
          ],
        ),
        child: Icon(Icons.edit_rounded, color: acc.onAccent, size: 26),
      ),
    );
  }

  void _pickContact(BuildContext context) {
    final app = context.appRead;
    final vc = app.colors;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        minChildSize: 0.4,
        expand: false,
        builder: (_, scroll) => Material(
          color: vc.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          clipBehavior: Clip.antiAlias,
          child: ListView(
            controller: scroll,
            children: [
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: vc.textFaint,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text(
                  'Новый чат',
                  style: TextStyle(color: vc.text, fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              _NewAction(
                icon: Icons.group_add_rounded,
                title: 'Новая группа',
                subtitle: 'до ${GroupInfo.maxMembers} человек',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(CreateGroupScreen.route());
                },
              ),
              _NewAction(
                icon: Icons.campaign_rounded,
                title: 'Новый канал',
                subtitle: 'Пишешь ты — читают подписчики (до ${GroupInfo.maxSubscribers})',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(CreateGroupScreen.route(channel: true));
                },
              ),
              _NewAction(
                icon: Icons.edit_note_rounded,
                title: 'Заметки для себя',
                subtitle: 'Только на этом телефоне',
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(ChatScreen.route(app.notes()));
                },
              ),
              for (final (i, c) in app.friends.indexed)
                Reveal(
                  index: i,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    leading: Avatar.contact(c, size: 46),
                    title: Text(
                      c.name,
                      style: TextStyle(color: vc.text, fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      c.online ? 'в сети' : fmtLastSeen(c.lastSeen),
                      style: TextStyle(
                        color: c.online ? VeilColors.success : vc.textDim,
                        fontSize: 13,
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.of(context).push(ChatScreen.route(c));
                    },
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.searching});
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Padding(
      padding: const EdgeInsets.fromLTRB(40, 40, 40, 160),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 900).by(context),
            curve: Curves.elasticOut,
            builder: (_, s, c) => Transform.scale(scale: s, child: c),
            child: Text(searching ? '🔍' : '🕊️', style: const TextStyle(fontSize: 64)),
          ),
          const SizedBox(height: 16),
          Text(
            searching ? 'Ничего не нашлось' : 'Тут пока тихо',
            style: TextStyle(color: vc.text, fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            searching
                ? 'Попробуй другое имя или слово'
                : 'Добавь друга по QR-коду и начни переписку — она останется только между вами',
            textAlign: TextAlign.center,
            style: TextStyle(color: vc.textDim, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// Строка «Архив (3)» над списком чатов.
class _ArchiveRow extends StatelessWidget {
  const _ArchiveRow({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Pressable(
      scale: 0.98,
      onTap: () => Navigator.of(context).push(ArchiveScreen.route()),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
        child: Row(
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(color: vc.surface, shape: BoxShape.circle),
              child: Icon(Icons.archive_rounded, color: vc.textDim),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Архив',
                style: TextStyle(color: vc.text, fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            Text('$count', style: TextStyle(color: vc.textDim)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, color: vc.textDim),
          ],
        ),
      ),
    );
  }
}

/// Архивные чаты.
class ArchiveScreen extends StatelessWidget {
  const ArchiveScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const ArchiveScreen());

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final chats = app.archivedChats;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Архив'),
      ),
      body: chats.isEmpty
          ? Center(
              child: Text('Архив пуст', style: TextStyle(color: vc.textDim)),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'Чаты в архиве не мешают в общем списке. Вернуть — долгое нажатие.',
                    style: TextStyle(color: vc.textDim, fontSize: 13),
                  ),
                ),
                for (final c in chats) _ChatTile(contact: c),
              ],
            ),
    );
  }
}

/// Тайник: скрытые чаты. Открывается по PIN тайника.
class VaultScreen extends StatelessWidget {
  const VaultScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const VaultScreen());

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final chats = app.hiddenChats;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Тайник'),
      ),
      body: chats.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  'Здесь пусто. Спрятать чат — долгое нажатие на него в списке → '
                  '«Спрятать в тайник».',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: vc.textDim, height: 1.4),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                for (final c in chats)
                  app.lastMessage(c.id) == null
                      ? ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                          leading: Avatar.contact(c, size: 52),
                          title: Text(c.name, style: TextStyle(color: vc.text)),
                          subtitle: Text('Нет сообщений', style: TextStyle(color: vc.textDim)),
                          onTap: () => Navigator.of(context).push(ChatScreen.route(c)),
                          onLongPress: () => app.setHidden(c.id, false),
                        )
                      : _ChatTile(contact: c),
              ],
            ),
    );
  }
}

/// Пункт в начале листа «Новый чат»: группа, канал, заметки.
class _NewAction extends StatelessWidget {
  const _NewAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final acc = context.accent;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
      leading: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(shape: BoxShape.circle, gradient: acc.gradient),
        child: Icon(icon, color: acc.onAccent),
      ),
      title: Text(
        title,
        style: TextStyle(color: vc.text, fontWeight: FontWeight.w700),
      ),
      subtitle: Text(subtitle, style: TextStyle(color: vc.textDim, fontSize: 13)),
      onTap: onTap,
    );
  }
}
