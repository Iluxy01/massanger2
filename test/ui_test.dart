import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/widgets/avatar.dart';
import 'package:veil/widgets/visual.dart';

/// Проверки визуальных исправлений (демо-режим, без сети).
void main() {
  Future<AppState> launch(WidgetTester tester, {bool banner = true}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = banner;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    return state;
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  testWidgets('при перелёте аватарки у эмодзи нет «двух полосок»', (tester) async {
    final state = await launch(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    // Середина перехода — аватарка «летит» в оверлее, где нет Material.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final flying = find.text('🦊');
    expect(flying, findsWidgets);
    for (final el in flying.evaluate()) {
      final text = el.widget as Text;
      final style = DefaultTextStyle.of(el).style.merge(text.style);
      expect(style.decoration, anyOf(isNull, TextDecoration.none), reason: 'подчёркивание');
    }
    await settle(tester);
    await close(tester, state);
  });

  testWidgets('галочки: ✓ доставлено, ✓✓ прочитано', (tester) async {
    final state = AppState.demo();
    Future<void> show(MsgStatus s) => tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(
          home: Material(
            child: StatusTicks(key: ValueKey(s), status: s, color: Colors.white),
          ),
        ),
      ),
    );
    await show(MsgStatus.delivered);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.done_rounded), findsOneWidget);
    expect(find.byIcon(Icons.done_all_rounded), findsNothing);
    await show(MsgStatus.read);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byIcon(Icons.done_all_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('секретное сообщение открывается и скрывается касанием', (tester) async {
    final state = await launch(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    final secret = state.messagesOf('alice').firstWhere((m) => m.secret);
    expect(secret.revealed, isFalse);
    final eye = find.byIcon(Icons.visibility_rounded);
    await tester.dragUntilVisible(eye, find.byType(ListView), const Offset(0, 250));
    await settle(tester);
    expect(eye, findsOneWidget);

    await tester.tap(eye);
    await settle(tester);
    expect(secret.revealed, isTrue, reason: 'первое касание открывает');
    expect(find.byIcon(Icons.visibility_rounded), findsNothing);

    await tester.tap(find.text('cosmos_2024!'));
    await settle(tester);
    expect(secret.revealed, isFalse, reason: 'второе касание скрывает');
    await close(tester, state);
  });

  testWidgets('всплывающее окошко можно отключить', (tester) async {
    for (final on in [true, false]) {
      final state = await launch(tester, banner: on);
      // В демо Катя присылает сообщение через 6 секунд после запуска.
      for (var i = 0; i < 70; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('сейчас'), on ? findsOneWidget : findsNothing, reason: 'banner=$on');
      await close(tester, state);
    }
  });

  testWidgets('уровни оформления и анимаций: все работают и сохраняются', (tester) async {
    // Без всплывашки: она тоже из стекла и сбила бы подсчёт.
    final state = await launch(tester, banner: false);
    int blurs() => find.byType(BackdropFilter).evaluate().length;
    final normal = blurs();

    for (final look in [0, 2, 1]) {
      for (final motion in [0, 1, 3, 2]) {
        state.setLook(look);
        state.setMotion(motion);
        await settle(tester);
        final v = Visual.of(tester.element(find.byType(Scaffold).first));
        expect((v.look, v.motion), (look, motion));
        // Заходим в чат и выходим — без ошибок на любом уровне.
        await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
        await settle(tester);
        expect(find.text('Что берём на крышу?'), findsOneWidget);
        navigatorKey.currentState!.pop();
        await settle(tester);
        if (look == 0) expect(blurs(), 0, reason: 'минимум — без размытия');
        if (look == 2) expect(blurs(), greaterThan(normal), reason: 'максимум — стекло везде');
      }
    }
    expect(blurs(), normal, reason: 'по умолчанию всё как раньше');

    // Сохраняются вместе с остальными настройками.
    state.setLook(0);
    state.setMotion(3);
    final copy = AppState.demo()..applySettings(state.settingsForTest);
    expect((copy.look, copy.motion), (0, 3));
    copy.dispose();
    await close(tester, state);
  });

  testWidgets('опрос: голос, проценты, отмена голоса', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    final poll = state.messagesOf('alice').firstWhere((m) => m.kind == MsgKind.poll);
    expect(find.text('Что берём на крышу?'), findsOneWidget);
    expect(find.text('Проголосовали: 1'), findsOneWidget);
    expect(find.text('100%'), findsNothing, reason: 'до своего голоса результаты скрыты');

    await tester.tap(find.text('Какао'));
    await settle(tester);
    expect(poll.poll!.of('me'), [1]);
    expect(find.text('Проголосовали: 2'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    await tester.tap(find.text('Чай в термосе'));
    await settle(tester);
    expect(poll.poll!.of('me'), [0], reason: 'один вариант — голос переносится');
    expect(find.text('50%'), findsNWidgets(2));

    await tester.tap(find.text('Чай в термосе'));
    await settle(tester);
    expect(poll.poll!.of('me'), isEmpty, reason: 'повторное касание — отозвать');
    await close(tester, state);
  });

  testWidgets('геопозиция, фото и документ в пузырях', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await settle(tester);
    expect(find.text('Геопозиция · ±15 м'), findsOneWidget);
    Navigator.of(tester.element(find.text('Геопозиция · ±15 м'))).pop();
    await settle(tester);

    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-kate').first);
    await settle(tester);
    // Фото ещё не скачано: размытое превью, размер и кнопка «скачать».
    expect(find.text('Тот самый закат'), findsOneWidget);
    expect(find.text('822 КБ'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward_rounded), findsNWidgets(2));
    expect(find.text('Маршрут_поездки.pdf'), findsOneWidget);
    expect(find.text('1,3 МБ · скачать'), findsOneWidget);
    // В списке чатов — понятная подпись.
    expect(
      state.messagesOf('kate').firstWhere((m) => m.kind == MsgKind.file).preview,
      '📎 Маршрут_поездки.pdf',
    );
    await close(tester, state);
  });

  testWidgets('меню вложений: опрос и геопозиция отправляются', (tester) async {
    final state = await launch(tester, banner: false);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-dima').first);
    await settle(tester);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await settle(tester);
    for (final label in ['Фото', 'Камера', 'Видео', 'Файл', 'Место', 'Опрос']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }

    await tester.tap(find.text('Опрос'));
    await settle(tester);
    expect(find.text('Новый опрос'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Во сколько созвон?');
    await tester.enterText(fields.at(1), '19:00');
    await tester.enterText(fields.at(2), '20:00');
    await tester.pump();
    await tester.tap(find.text('Отправить опрос'));
    await settle(tester);
    final sent = state.lastMessage('dima')!;
    expect(sent.kind, MsgKind.poll);
    expect(sent.poll!.question, 'Во сколько созвон?');
    expect(sent.poll!.options, ['19:00', '20:00']);
    expect(find.text('Во сколько созвон?'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add_rounded));
    await settle(tester);
    await tester.tap(find.text('Место'));
    await settle(tester);
    expect(find.text('Отправить геопозицию'), findsOneWidget);
    await tester.tap(find.text('Отправить геопозицию'));
    await settle(tester);
    final geo = state.lastMessage('dima')!;
    expect(geo.kind, MsgKind.geo);
    expect(geo.geo!.lat, closeTo(55.75, 0.01));
    await close(tester, state);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
