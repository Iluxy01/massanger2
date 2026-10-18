import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/screens/chat_screen.dart';
import 'package:veil/screens/contacts_tab.dart';
import 'package:veil/screens/settings_tab.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/theme/palette.dart';
import 'package:veil/theme/skin.dart';
import 'package:veil/theme/sky.dart';
import 'package:veil/widgets/effects.dart';
import 'package:veil/widgets/slow_clock.dart';
import 'package:veil/widgets/visual.dart';

/// Плавность и батарея: готовые картинки фонов, «медленные» часы анимаций.
void main() {
  Sky sky(int id, [Map<String, int> opts = const {}]) {
    final s = Skin.of(id, opts);
    return Sky(skin: s, c: s.colors ?? VeilColors.darkColors, acc: s.accent ?? accents[0]);
  }

  test('фон рисуется в картинку один раз и берётся из кэша', () {
    var draws = 0;
    void draw(Canvas c) => draws++;
    final a = SkyCache.get('test-a', const Size(40, 30), 2, draw);
    final b = SkyCache.get('test-a', const Size(40, 30), 2, draw);
    expect(identical(a, b), isTrue);
    expect(draws, 1);
    expect((a.width, a.height), (80, 60), reason: 'в физических пикселях');
    SkyCache.get('test-a', const Size(41, 30), 2, draw);
    expect(draws, 2, reason: 'другой размер — новая картинка');
  });

  test('что у фона движется', () {
    expect(sky(1).moves, isTrue);
    expect(sky(1, {'tb': 2}).moves, isFalse, reason: 'чистый фон Терминала стоит');
    expect(sky(2).moves, isTrue);
    expect(sky(3, {'lb': 1}).moves, isFalse, reason: 'горошек не двигается');
    expect(sky(3).moves, isTrue);
    expect(sky(2) == sky(2), isTrue);
    expect(sky(2) == sky(2, {'ch': 1}), isFalse);
  });

  testWidgets('часы анимаций: идут, только когда нужно и видно', (tester) async {
    final clock = SlowClock()
      ..fps = 20
      ..period = const Duration(seconds: 1);
    var enabled = true;
    late StateSetter set;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, s) {
          set = s;
          return TickerMode(
            enabled: enabled,
            child: Builder(
              builder: (context) {
                clock.attach(context);
                return const SizedBox();
              },
            ),
          );
        },
      ),
    );
    expect(clock.running.value, isFalse, reason: 'по настройкам не нужно');
    clock
      ..wanted = true
      ..sync();
    expect(clock.running.value, isTrue);
    // Скрыт (другая вкладка, перекрыт экраном) — стоит.
    set(() => enabled = false);
    await tester.pump();
    expect(clock.running.value, isFalse);
    set(() => enabled = true);
    await tester.pump();
    expect(clock.running.value, isTrue);
    // Приложение свёрнуто — стоит.
    Activity.setResumed(false);
    expect(clock.running.value, isFalse);
    Activity.setResumed(true);
    expect(clock.running.value, isTrue);
    // Давно не трогали — засыпает; касание будит.
    clock
      ..idle = Duration.zero
      ..sync();
    expect(clock.running.value, isFalse);
    clock
      ..idle = const Duration(minutes: 1)
      ..sync();
    Activity.poke();
    expect(clock.running.value, isTrue);
    await tester.pumpWidget(const SizedBox());
    clock.dispose();
  });

  testWidgets('градиентный значок рисуется без отдельного слоя и находится', (tester) async {
    final state = AppState.demo();
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: const MaterialApp(home: Center(child: GradientIcon(Icons.bolt_rounded))),
      ),
    );
    expect(find.byIcon(Icons.bolt_rounded), findsOneWidget);
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.getSize(find.byType(GradientIcon)), const Size(24, 24));
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('фон на всех стилях и уровнях рисуется без ошибок', (tester) async {
    final state = AppState.demo();
    for (final id in [0, 1, 2, 3]) {
      for (final look in [0, 1, 2]) {
        final s = Skin.of(id, const {'cs': 2});
        await tester.pumpWidget(
          AppScope(
            state: state,
            child: Visual(
              look: look,
              motion: 2,
              skin: s,
              child: const MaterialApp(home: AuroraBackground(animate: true)),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));
        await tester.pump(const Duration(milliseconds: 120));
        expect(tester.takeException(), isNull, reason: 'стиль $id, оформление $look');
      }
    }
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  Future<AppState> launch(WidgetTester tester, {int skin = 0}) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    if (skin > 0) state.setSkin(skin);
    await tester.pumpWidget(VeilApp(state: state));
    await tester.pump(const Duration(milliseconds: 100));
    return state;
  }

  Future<void> frames(WidgetTester tester, int n) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('скрытые вкладки заранее рисуются невидимо — первое переключение не дёргает', (
    tester,
  ) async {
    final state = await launch(tester);
    RenderRepaintBoundary boundary(Type tab) => tester.renderObject(
      find.ancestor(of: find.byType(tab), matching: find.byType(RepaintBoundary)).first,
    );
    double opacity(Type tab) => tester
        .widget<AnimatedOpacity>(
          find.ancestor(of: find.byType(tab), matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;
    // Сразу после запуска скрытые вкладки ещё ни разу не рисовались.
    expect(boundary(SettingsTab).debugLayer, isNull);
    expect(boundary(ContactsTab).debugLayer, isNull);
    await frames(tester, 20);
    expect(boundary(ContactsTab).debugLayer, isNotNull, reason: 'Друзья уже нарисованы');
    expect(boundary(SettingsTab).debugLayer, isNotNull, reason: 'Профиль уже нарисован');
    // И снова полностью скрыты.
    expect(opacity(ContactsTab), 0);
    expect(opacity(SettingsTab), 0);
    // Переключение — сдвигом, без масштаба (масштаб заново растрирует весь текст).
    expect(
      find.ancestor(of: find.byType(SettingsTab), matching: find.byType(AnimatedScale)),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('nav-2')));
    await frames(tester, 5);
    expect(opacity(SettingsTab), 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('Космос: переход в чат масштабирует готовую картинку, а не текст', (tester) async {
    final state = await launch(tester, skin: 2);
    await frames(tester, 15);
    await tester.tap(find.byWidgetPredicate((w) => w is Hero && w.tag == 'avatar-alice').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 60));
    // Посреди перехода: экран чата снят в картинку.
    final snap = tester.widgetList<SnapshotWidget>(find.byType(SnapshotWidget));
    expect(snap.any((w) => w.controller.allowSnapshotting), isTrue);
    await frames(tester, 10);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(
      tester
          .widgetList<SnapshotWidget>(find.byType(SnapshotWidget))
          .any((w) => w.controller.allowSnapshotting),
      isFalse,
      reason: 'переход закончился — экран живой',
    );
    navigatorKey.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      tester
          .widgetList<SnapshotWidget>(find.byType(SnapshotWidget))
          .any((w) => w.controller.allowSnapshotting),
      isTrue,
      reason: 'и назад — тоже картинкой',
    );
    await frames(tester, 10);
    expect(find.byType(ChatScreen), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
