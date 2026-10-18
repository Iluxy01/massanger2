import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/state/app_state.dart';

void main() {
  testWidgets('онбординг → профиль → главный экран', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo();
    await tester.pumpWidget(VeilApp(state: state));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Пропустить'), findsOneWidget);

    await state.createProfile(name: 'Тест', emoji: '🦊', colorIndex: 0);
    await tester.pump(const Duration(milliseconds: 100));
    // Профиль есть, но главный экран — только после последнего шага настройки.
    expect(find.text('Пропустить'), findsOneWidget);
    state.finishSetup();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Veil'), findsWidgets);
    expect(find.text('Алиса'), findsWidgets);

    // Открываем чат и вкладку профиля.
    await tester.tap(find.text('Алиса').first);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Сообщение'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'привет');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('привет'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('вкладки переключаются туда и обратно', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo();
    state.createProfile(name: 'Тест', emoji: '🦊', colorIndex: 0);
    await tester.pumpWidget(VeilApp(state: state));
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    double opacityOf(Finder f) {
      final o = tester.widget<AnimatedOpacity>(
        find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).last,
      );
      return o.opacity;
    }

    await settle();
    // Чаты → Профиль → Друзья → Чаты: видимой должна быть только активная вкладка.
    for (final (tab, visible, hidden) in [
      (2, 'Мой QR-код', 'Добавить друга'),
      (1, 'Добавить друга', 'Мой QR-код'),
      (0, 'Сейчас в сети'.toUpperCase(), 'Добавить друга'),
    ]) {
      await tester.tap(find.byKey(ValueKey('nav-$tab')));
      await settle();
      final e = tester.takeException();
      if (e != null) fail('tab $tab: $e');
      expect(opacityOf(find.text(visible, skipOffstage: false)), 1, reason: 'tab $tab');
      expect(opacityOf(find.text(hidden, skipOffstage: false).first), 0, reason: 'tab $tab');
    }
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
