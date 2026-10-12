import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/app_state.dart';
import '../theme/palette.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import '../widgets/effects.dart';
import 'add_friend_screen.dart';
import 'chat_screen.dart';
import 'contact_screen.dart';

class ContactsTab extends StatelessWidget {
  const ContactsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final top = MediaQuery.paddingOf(context).top;
    final sorted = [...app.contacts]..sort((a, b) => a.name.compareTo(b.name));
    final online = sorted.where((c) => c.online).length;

    // Группировка по первой букве.
    final rows = <Object>[];
    String? letter;
    for (final c in sorted) {
      final l = c.name.characters.first.toUpperCase();
      if (l != letter) {
        rows.add(l);
        letter = l;
      }
      rows.add(c);
    }

    return Stack(
      children: [
        const Positioned.fill(child: AuroraBackground(intensity: 0.4)),
        ListView(
          padding: EdgeInsets.fromLTRB(20, top + 12, 20, 140),
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          children: [
            Text(
              'Друзья',
              style: TextStyle(
                color: vc.text,
                fontSize: 36,
                fontWeight: FontWeight.w900,
                letterSpacing: -1.2,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${sorted.length} в контактах · $online в сети',
              style: TextStyle(color: vc.textDim, fontSize: 14),
            ),
            const SizedBox(height: 20),
            Reveal(child: _AddFriendCard()),
            const SizedBox(height: 12),
            Reveal(index: 1, child: _InviteCard()),
            const SizedBox(height: 12),
            for (final (i, r) in rows.indexed)
              if (r is String)
                Padding(
                  padding: const EdgeInsets.only(top: 18, bottom: 6, left: 4),
                  child: GradientText(
                    r,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
                  ),
                )
              else
                Reveal(
                  index: i + 2,
                  child: _ContactTile(contact: r as Contact),
                ),
          ],
        ),
      ],
    );
  }
}

class _AddFriendCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final acc = context.accent;
    return Pressable(
      onTap: () => Navigator.of(context).push(AddFriendScreen.route()),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: acc.gradient,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: acc.mid.withValues(alpha: 0.4),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(Icons.qr_code_scanner_rounded, color: acc.onAccent, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Добавить друга',
                    style: TextStyle(
                      color: acc.onAccent,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Покажи свой QR или отсканируй код друга — без номера телефона',
                    style: TextStyle(color: acc.onAccent.withValues(alpha: 0.85), fontSize: 13),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: acc.onAccent),
          ],
        ),
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    return Pressable(
      onTap: () => shareInvite(context),
      child: Glass(
        radius: 20,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const SizedBox(width: 4),
            const GradientIcon(Icons.link_rounded, size: 24),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                'Пригласить друга по ссылке',
                style: TextStyle(color: vc.text, fontWeight: FontWeight.w600),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: vc.textFaint),
          ],
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact});
  final Contact contact;

  @override
  Widget build(BuildContext context) {
    final vc = context.vc;
    final c = contact;
    return Pressable(
      scale: 0.98,
      onTap: () => Navigator.of(context).push(ContactScreen.route(c)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Hero(tag: 'avatar-${c.id}', child: Avatar.contact(c, size: 50)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        c.name,
                        style: TextStyle(color: vc.text, fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      if (c.verified) ...[
                        const SizedBox(width: 4),
                        const GradientIcon(Icons.verified_rounded, size: 15),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.online ? 'в сети' : (c.bio.isNotEmpty ? c.bio : fmtLastSeen(c.lastSeen)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: c.online ? VeilColors.success : vc.textDim,
                      fontSize: 13.5,
                    ),
                  ),
                ],
              ),
            ),
            Pressable(
              scale: 0.85,
              onTap: () => Navigator.of(context).push(ChatScreen.route(c)),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: vc.elevated, shape: BoxShape.circle),
                child: const Center(child: GradientIcon(Icons.chat_bubble_rounded, size: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
