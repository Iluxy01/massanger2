import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/models/models.dart';
import 'package:veil/screens/chat_screen.dart';
import 'package:veil/screens/chats_tab.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/widgets/stickers.dart';

/// Каналы, «Заметки» и стикеры на экране (демо-режим, без сети).
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AppState> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  Future<void> openNewChat(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: find.byType(ChatsTab), matching: find.byIcon(Icons.edit_rounded)),
    );
    await settle(tester);
  }

  testWidgets('новый канал: создание, пост, ссылка-приглашение', (tester) async {
    final state = await launch(tester);
    await openNewChat(tester);
    await tester.tap(find.text('Новый канал'));
    await settle(tester);
    expect(find.text('Создать канал'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Новости района');
    await tester.pump();
    // Подписчиков можно не звать сразу.
    await tester.tap(find.text('Создать канал'));
    await settle(tester);
    final ch = state.contacts.firstWhere((c) => c.isChannel);
    expect(ch.name, 'Новости района');
    expect(find.text('канал · 0 подписчиков'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Завтра отключат воду');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text('Завтра отключат воду'), findsOneWidget);
    expect(state.channelLink(ch.id), startsWith('veil://ch?'));
    // Описание канала: ссылка и QR.
    await tester.tap(find.text('Новости района').first);
    await settle(tester);
    expect(find.text('Пригласительная ссылка'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Закрыть канал'), 300);
    await settle(tester);
    expect(find.text('Закрыть канал'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, state);
  });

  testWidgets('подписчик канала только читает', (tester) async {
    final state = await launch(tester);
    final admin = state.friends.first;
    final ch = Contact(id: 'g_${'a' * 32}', name: 'Чужой канал', emoji: '📢', colorIndex: 2)
      ..group = GroupInfo(
        members: [GroupMember(pub: admin.id, name: admin.name, emoji: admin.emoji, color: 1)],
        admin: admin.id,
        ver: 1,
        channel: true,
      );
    state.contacts.add(ch);
    state
        .messagesOf(ch.id)
        .add(
          Message(
            id: 'p1',
            mine: false,
            text: 'Пост автора',
            time: DateTime.now(),
            from: admin.id,
            status: MsgStatus.delivered,
          ),
        );
    state.notifyChanged();
    await settle(tester);
    await tester.tap(find.text('Чужой канал'));
    await settle(tester);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.text('Публикует только автор канала'), findsOneWidget);
    expect(find.text('Пост автора'), findsOneWidget);
    expect(find.text(admin.name), findsNothing, reason: 'без имени автора над постом');
    // Звук канала — прямо с нижней панели.
    await tester.tap(find.text('Со звуком'));
    await settle(tester);
    expect(state.muted.contains(ch.id), isTrue);
    expect(find.text('Без звука'), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('«Заметки»: из меню нового чата, без галочек и звонка', (tester) async {
    final state = await launch(tester);
    await openNewChat(tester);
    await tester.tap(find.text('Заметки для себя'));
    await settle(tester);
    expect(find.text('только на этом телефоне'), findsOneWidget);
    expect(find.byIcon(Icons.call_outlined), findsNothing);
    await tester.enterText(find.byType(TextField).last, 'Код от домофона 1234');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester);
    expect(find.text('Код от домофона 1234'), findsOneWidget);
    expect(state.messagesOf(Contact.notesId).single.status, MsgStatus.read);
    await close(tester, state);
  });

  testWidgets('панель стикеров: отправка стикера из набора', (tester) async {
    final state = await launch(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('stickers')));
    await settle(tester);
    expect(find.text('Стикеры'), findsOneWidget);
    expect(find.text('Из фото'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stk-cool')));
    await settle(tester);
    final m = state.messagesOf('alice').last;
    expect(m.kind, MsgKind.sticker);
    expect(m.sticker, 'cool');
    // В ленте — сам стикер, без пузыря.
    expect(
      find.byWidgetPredicate((w) => w is VeilSticker && w.spec.id == 'cool' && w.size == 150),
      findsOneWidget,
    );
    // Вкладка GIF.
    await tester.tap(find.text('GIF'));
    await settle(tester);
    expect(find.text('С телефона'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, state);
  });
}
