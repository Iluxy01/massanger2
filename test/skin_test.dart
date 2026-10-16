import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/screens/settings_tab.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/theme/palette.dart';
import 'package:veil/theme/skin.dart';
import 'package:veil/widgets/avatar.dart';
import 'package:veil/widgets/visual.dart';

/// Стили оформления: Терминал, Космос, Лимонад.
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

  Visual visualOf(WidgetTester tester) => Visual.of(tester.element(find.byType(Scaffold).first));

  test('у каждого стиля свои цвета, формы и характер анимаций', () {
    final term = Skin.of(1, const {});
    final cosmos = Skin.of(2, const {});
    final lemon = Skin.of(3, const {});
    expect(Skin.of(0, const {}).colors, isNull, reason: 'Veil — цвета из обычных настроек');
    expect(term.colors!.dark && cosmos.colors!.dark, isTrue);
    expect(lemon.colors!.dark, isFalse, reason: 'Лимонад — светлый');
    expect(term.font, 'monospace');
    expect(Skin.of(1, const {'tf': 1}).font, isNull, reason: 'моно только в сообщениях');
    expect(term.speed < 1 && cosmos.speed > 1, isTrue);
    expect(term.radius < 1 && lemon.radius > 1, isTrue);
    expect(term.appear, Appear.type);
    expect(cosmos.appear, Appear.float);
    expect(Skin.of(3, const {'la': 1}).appear, Appear.bounce);
    expect(Skin.of(1, const {'tc': 2}).accent!.name, 'Циан');
    expect(Skin.of(2, const {'cn': 9}).accent, isNotNull, reason: 'лишнее значение не ломает');
    for (final id in [1, 2, 3]) {
      for (final o in Skin.options[id]!) {
        expect(o.labels.length, o.hints.length, reason: o.key);
      }
    }
  });

  test('стиль и его настройки сохраняются; «Ультра» возвращает классику', () {
    final a = AppState.demo();
    a.setSkin(2);
    a.setSkinOpt('ch', 1);
    a.setSkinOpt('cn', 1);
    expect(a.skin.id, 2);
    expect(a.skin.opt('ch'), 1);
    expect(a.accent.name, 'Синяя');
    final b = AppState.demo()..applySettings(a.settingsForTest);
    expect(b.skinId, 2);
    expect(b.skin.opt('ch'), 1);
    expect(b.skin.opt('cn'), 1);
    expect(b.colors.bg, a.colors.bg);
    // Старые настройки (без стиля) — классический Veil.
    final c = AppState.demo()..applySettings({'accent': 2, 'dark': false});
    expect(c.skin.id, 0);
    expect(c.accent, accents[2]);
    expect(c.colors.dark, isFalse);
    a.setUltra(true);
    expect(a.skin.id, 0);
    expect(a.colors.bg, VeilColors.amoledColors.bg);
    a.setUltra(false);
    expect(a.skin.id, 2, reason: 'выбор не потерян');
    for (final s in [a, b, c]) {
      s.dispose();
    }
  });

  testWidgets('выбор стиля в настройках и его мелкие настройки', (tester) async {
    final state = await launch(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is Avatar && w.size == 26).last);
    await settle(tester);
    final scroll = find
        .descendant(of: find.byType(SettingsTab), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.text('Стиль · Veil'), 300, scrollable: scroll);
    await settle(tester);
    expect(find.text('Тёмная тема'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('skin-1')));
    await settle(tester);
    expect(state.skinId, 1);
    expect(visualOf(tester).skin.id, 1);
    expect(find.text('Стиль · Терминал'), findsOneWidget);
    expect(find.text('Тёмная тема'), findsNothing, reason: 'у стиля свои цвета');
    expect(find.text('Моноширинный шрифт'), findsOneWidget);
    await tester.tap(find.text('Янтарный'));
    await settle(tester);
    expect(state.skinOpts['tc'], 1);
    expect(state.accent.name, 'Янтарный');
    // Другой стиль — свои настройки.
    await tester.tap(find.byKey(const ValueKey('skin-2')));
    await settle(tester);
    expect(find.text('Чёрная дыра'), findsOneWidget);
    expect(find.text('Моноширинный шрифт'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('skin-0')));
    await settle(tester);
    expect(find.text('Тёмная тема'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, state);
  });

  for (final id in [1, 2, 3]) {
    testWidgets('стиль ${Skin.names[id]}: экраны и переписка без ошибок', (tester) async {
      final state = await launch(tester);
      state.setSkin(id);
      // Самые «тяжёлые» настройки стиля: чёрная дыра, много звёзд, пружины.
      state.setSkinOpt('cs', 2);
      state.setSkinOpt('la', 1);
      state.setSkinOpt('tb', 1);
      for (final (look, motion) in [(2, 3), (1, 2), (0, 0)]) {
        state.setLook(look);
        state.setMotion(motion);
        await settle(tester);
        final v = visualOf(tester);
        expect(v.skin.id, id);
        expect(state.colors.bg, Skin.of(id, state.skinOpts).colors!.bg);
        // Чат: отправка (анимация появления), «печатает», назад.
        await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
        await settle(tester);
        await tester.enterText(find.byType(TextField).last, 'Проверка $look$motion');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
        // Середина анимации появления.
        await tester.pump(const Duration(milliseconds: 60));
        await tester.pump(const Duration(milliseconds: 60));
        await settle(tester);
        expect(find.text('Проверка $look$motion'), findsOneWidget);
        await navigatorKey.currentState!.maybePop();
        await settle(tester);
        // Профиль и настройки.
        await tester.tap(find.byWidgetPredicate((w) => w is Avatar && w.size == 26).last);
        await settle(tester);
        await tester.scrollUntilVisible(
          find.text('Стиль · ${Skin.names[id]}'),
          300,
          scrollable: find
              .descendant(of: find.byType(SettingsTab), matching: find.byType(Scrollable))
              .first,
        );
        await settle(tester);
        await tester.tap(
          find.byWidgetPredicate(
            (w) => w is Icon && w.icon == Icons.chat_bubble_rounded && w.size == null,
          ),
        );
        await settle(tester);
        expect(tester.takeException(), isNull);
      }
      await close(tester, state);
    });
  }
}
