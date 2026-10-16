import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../utils.dart';
import '../widgets/avatar.dart';
import 'chat_screen.dart';

/// Избранное: отмеченные звёздочкой сообщения из всех чатов. Хранится только
/// на телефоне. Касание — открыть сообщение в его чате.
class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const FavoritesScreen());

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final vc = app.colors;
    final items = app.starredMessages;
    return Scaffold(
      backgroundColor: vc.bg,
      appBar: AppBar(
        backgroundColor: vc.bg,
        foregroundColor: vc.text,
        elevation: 0,
        title: const Text('Избранное'),
      ),
      body: items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.star_outline_rounded, size: 56, color: vc.textFaint),
                    const SizedBox(height: 12),
                    Text(
                      'Здесь будут важные сообщения. Долгое нажатие на сообщение → «В избранное».',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: vc.textDim, height: 1.4),
                    ),
                  ],
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 40),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final (c, m) = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => Navigator.of(context).push(ChatScreen.route(c, jumpTo: m.id)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Avatar.contact(c, size: 24, showOnline: false),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                c.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: vc.text, fontWeight: FontWeight.w700),
                              ),
                            ),
                            Text(
                              '${fmtDay(m.time)}, ${fmtTime(m.time)}',
                              style: TextStyle(color: vc.textFaint, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: MediaQuery.sizeOf(context).width * 0.78,
                            ),
                            child: IgnorePointer(
                              child: BubbleBody(m: m, contact: c, showName: true),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
