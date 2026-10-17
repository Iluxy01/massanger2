import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/widgets/effects.dart';

/// Вход по отпечатку: кнопка на экране блокировки, PIN остаётся запасным.
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 15; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('отпечаток не открывает без подтверждения; PIN работает', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await state.setPin('1234');
    state.biometric = true;
    await tester.pumpWidget(VeilApp(state: state));
    state.lock();
    await settle(tester);
    // Кнопка отпечатка есть; в тестах датчика нет — остаёмся на замке.
    final bio = find.byWidgetPredicate(
      (w) => w is GradientIcon && w.icon == Icons.fingerprint_rounded,
    );
    expect(bio, findsOneWidget);
    await tester.tap(bio);
    await settle(tester);
    expect(state.locked, isTrue);
    for (final d in ['1', '2', '3', '4']) {
      await tester.tap(find.text(d).last);
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(state.locked, isFalse);
    // Выключили PIN — выключился и отпечаток.
    await state.setPin(null);
    expect(state.biometric, isFalse);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
