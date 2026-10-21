import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/screens/chat_look.dart';
import 'package:veil/screens/contact_screen.dart';
import 'package:veil/games/sea.dart';
import 'package:veil/games/word.dart';
import 'package:veil/models/models.dart';
import 'package:veil/screens/draw_screen.dart';
import 'package:veil/screens/game_screen.dart';
import 'package:veil/screens/stories.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/widgets/fx_layer.dart';
import 'package:veil/widgets/game_views.dart';
import 'package:veil/widgets/wallpaper.dart';

/// Новые развлечения на экране (демо-режим, без сети).
void main() {
  Future<void> settle(WidgetTester tester, [int frames = 15]) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AppState> launch(WidgetTester tester, {void Function(AppState)? before}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    before?.call(state);
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  Future<void> openChat(WidgetTester tester, String id) async {
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-$id').first);
    await settle(tester);
  }

  void noErrors(WidgetTester tester) {
    final e = tester.takeException();
    if (e != null) fail('$e');
  }

  testWidgets('истории: лента, просмотр касанием, своя текстовая', (tester) async {
    final state = await launch(tester);
    expect(find.byKey(const ValueKey('story-me')), findsOneWidget);
    // Непросмотренные — первыми, просмотренная (Катя) — после.
    final xs = [
      for (final id in ['alice', 'max', 'kate'])
        tester.getTopLeft(find.byKey(ValueKey('story-$id'))).dx,
    ];
    expect(xs[0] < xs[2] && xs[1] < xs[2], isTrue);
    expect(state.contact('alice')!.storyUnseen, isTrue);

    await tester.tap(find.byKey(const ValueKey('story-alice')));
    await settle(tester, 5);
    expect(find.byType(StoryViewer), findsOneWidget);
    expect(find.textContaining('кофейню'), findsOneWidget);
    // Касание справа — следующая.
    await tester.tapAt(const Offset(350, 420));
    await settle(tester, 5);
    expect(find.textContaining('выставку'), findsOneWidget);
    expect(state.contact('alice')!.storyUnseen, isFalse);
    // Ответ уходит в личку с пометкой.
    await tester.enterText(find.byKey(const ValueKey('story-reply')), 'иду!');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester, 3);
    final reply = state.messagesOf('alice').last;
    expect(reply.text, 'иду!');
    expect(reply.story, contains('выставку'));
    await tester.tap(find.byTooltip('Закрыть'));
    await settle(tester);
    expect(find.byType(StoryViewer), findsNothing);
    noErrors(tester);

    // Своя текстовая история.
    await tester.tap(find.byKey(const ValueKey('story-me')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('compose-text')));
    await settle(tester, 5);
    await tester.enterText(find.byKey(const ValueKey('story-text')), 'Мой день');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('story-publish')));
    await settle(tester);
    expect(state.myStories.single.text, 'Мой день');
    noErrors(tester);
    await settle(tester, 30);
    await close(tester, state);
  });

  testWidgets('игры и жребий: меню, крестики-нолики, кубик', (tester) async {
    final state = await launch(tester);
    await openChat(tester, 'alice');
    await tester.tap(find.byKey(const ValueKey('attach')));
    await settle(tester, 5);
    for (final k in ['attach-game', 'attach-lot', 'attach-draw']) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    await tester.tap(find.byKey(const ValueKey('attach-game')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('pick-ttt')));
    await settle(tester, 5);
    final game = state.messagesOf('alice').last;
    expect(game.game?.type, 'ttt');
    expect(find.byType(GameContent), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ttt-4')));
    await settle(tester, 15);
    expect(game.game!.moves.first, '04');
    expect(game.game!.moves, hasLength(2), reason: 'демо-соперник ответил');

    await tester.tap(find.byKey(const ValueKey('attach')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('attach-lot')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('pick-dice')));
    await settle(tester, 20);
    final dice = state.messagesOf('alice').lastWhere((m) => m.game?.type == 'dice');
    expect(dice.game!.status().over, isTrue);
    expect(find.text('Честно ✓'), findsOneWidget);
    noErrors(tester);
    await close(tester, state);
  });

  testWidgets('в группе нет игр и жребия', (tester) async {
    final state = await launch(tester);
    final g = state.contacts.firstWhere((c) => c.isGroup && !c.isChannel);
    await openChat(tester, g.id);
    await tester.tap(find.byKey(const ValueKey('attach')));
    await settle(tester, 5);
    expect(find.byKey(const ValueKey('attach-game')), findsNothing);
    expect(find.byKey(const ValueKey('attach-lot')), findsNothing);
    expect(find.byKey(const ValueKey('attach-draw')), findsOneWidget);
    await close(tester, state);
  });

  testWidgets('эффект из меню отправки: играет и сам исчезает', (tester) async {
    final state = await launch(tester);
    await openChat(tester, 'max');
    await tester.enterText(find.byKey(const ValueKey('field')), 'ура');
    await tester.pump();
    await tester.longPress(find.byIcon(Icons.arrow_upward_rounded));
    await settle(tester, 5);
    await tester.tap(find.text('С эффектом'));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('fx-hearts')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final m = state.messagesOf('max').lastWhere((x) => x.mine);
    expect(m.fx, 'hearts');
    final layer = find.descendant(of: find.byType(FxLayer), matching: find.byType(CustomPaint));
    expect(layer, findsOneWidget, reason: 'эффект идёт');
    await settle(tester, 40);
    expect(layer, findsNothing, reason: 'после — слоя нет');
    noErrors(tester);
    await close(tester, state);
  });

  testWidgets('рисунок: штрих пальцем и отмена', (tester) async {
    final state = await launch(tester);
    await openChat(tester, 'alice');
    await tester.tap(find.byKey(const ValueKey('attach')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('attach-draw')));
    await settle(tester);
    expect(find.byType(DrawScreen), findsOneWidget);
    final pic = state.messagesOf('alice').last;
    final canvas = find.byKey(const ValueKey('draw-canvas'));
    final start = tester.getCenter(canvas);
    final g = await tester.startGesture(start);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(start + Offset(i * 8.0, i * 5.0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    expect(pic.drawing!.strokes, hasLength(1));
    expect(pic.drawing!.strokes.single.pts.length, greaterThan(4));
    await tester.tap(find.byKey(const ValueKey('draw-undo')));
    await tester.pump();
    expect(pic.drawing!.strokes, isEmpty);
    noErrors(tester);
    await close(tester, state);
  });

  testWidgets('день рождения: торт в списке и «Поздравить» с конфетти', (tester) async {
    final now = DateTime.now();
    final md = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final state = await launch(tester, before: (s) => s.contact('max')!.birthday = md);
    expect(find.text('🎂'), findsWidgets);
    await openChat(tester, 'max');
    await tester.tap(find.byKey(const ValueKey('greet')));
    await tester.pump();
    final m = state.messagesOf('max').last;
    expect(m.text, 'С днём рождения! 🎉');
    expect(m.fx, 'confetti');
    await settle(tester, 40);
    expect(find.byKey(const ValueKey('greet')), findsNothing, reason: 'уже поздравили');
    noErrors(tester);
    await close(tester, state);
  });

  testWidgets('оформление чата: фон и цвет', (tester) async {
    final state = await launch(tester);
    await openChat(tester, 'alice');
    await tester.tap(find.text('Алиса').last);
    await settle(tester);
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('chat-look')),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    await tester.tap(find.byKey(const ValueKey('chat-look')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('wp-2')));
    await settle(tester, 3);
    expect(state.contact('alice')!.wallpaper, 'p:2');
    await tester.tap(find.byKey(const ValueKey('ca-7')));
    await settle(tester, 3);
    expect(state.contact('alice')!.chatAccent, 7);
    // Назад в чат — там свой фон.
    Navigator.of(tester.element(find.byType(ChatLookScreen))).pop();
    await settle(tester);
    Navigator.of(tester.element(find.byType(ContactScreen))).pop();
    await settle(tester);
    expect(find.byType(ChatWallpaper), findsOneWidget);
    noErrors(tester);
    await close(tester, state);
  });

  testWidgets('полноэкранные игры: шашки, морской бой, угадай слово', (tester) async {
    final state = await launch(tester);
    await openChat(tester, 'alice');
    Future<Message> incoming(Game g) async {
      final m = Message(
        id: 'g-${g.type}',
        mine: false,
        text: '',
        time: DateTime.now(),
        kind: MsgKind.game,
        game: g,
      );
      state.messagesOf('alice').add(m);
      state.notifyChanged();
      await settle(tester, 3);
      return m;
    }

    Future<void> open(Message m) async {
      Navigator.of(
        tester.element(find.byType(GameContent).first),
      ).push(GameScreen.route('alice', m.id));
      await settle(tester);
    }

    // Угадай слово: друг загадал — угадываем буквами.
    final w = await incoming(Game(type: 'word', word: 'КОТ', hint: 'мяукает'));
    await open(w);
    expect(find.text('Подсказка: мяукает'), findsOneWidget);
    for (final l in ['К', 'Ы', 'О', 'Т']) {
      await tester.tap(find.byKey(ValueKey('key-$l')));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect((w.game!.state as WordGame).winner, 1);
    expect(find.text('Угадано! 🎉'), findsOneWidget);
    Navigator.of(tester.element(find.byType(GameScreen))).pop();
    await settle(tester);

    // Морской бой: друг позвал — расставляем и «Готов к бою».
    final a = SeaLayout.random();
    final sea = await incoming(Game(type: 'sea', commit: seaCommit(a.encode(), 'x')));
    await open(sea);
    expect(find.text('Готов к бою'), findsOneWidget);
    await tester.tap(find.text('Перемешать'));
    await tester.pump();
    await tester.tap(find.text('Готов к бою'));
    await settle(tester, 3);
    expect(sea.game!.moves.single, startsWith('1h'));
    expect(sea.game!.myLayout, isNotNull, reason: 'своя расстановка запомнена');
    expect(find.byKey(const ValueKey('sea-enemy')), findsOneWidget);
    Navigator.of(tester.element(find.byType(GameScreen))).pop();
    await settle(tester);

    // Шашки: свою начинаем — ход касаниями «откуда» и «куда».
    await tester.tap(find.byKey(const ValueKey('attach')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('attach-game')));
    await settle(tester, 5);
    await tester.tap(find.byKey(const ValueKey('pick-chk')));
    await settle(tester, 5);
    final chk = state.messagesOf('alice').lastWhere((m) => m.game?.type == 'chk');
    await open(chk);
    final board = tester.getRect(find.byType(CheckersBoard));
    Offset cell(String n) {
      final c = 'abcdefgh'.indexOf(n[0]), r = 8 - int.parse(n[1]);
      final k = board.width / 8;
      return board.topLeft + Offset((c + 0.5) * k, (r + 0.5) * k);
    }

    await tester.tapAt(cell('c3'));
    await tester.pump();
    await tester.tapAt(cell('d4'));
    await settle(tester, 3);
    expect(chk.game!.moves.first, '042-35');
    noErrors(tester);
    await close(tester, state);
  });
}
