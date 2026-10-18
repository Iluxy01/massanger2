import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:veil/app.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/recovery.dart';
import 'package:veil/screens/account_screens.dart';
import 'package:veil/screens/home_screen.dart';
import 'package:veil/screens/onboarding_screen.dart';
import 'package:veil/screens/settings_tab.dart';
import 'package:veil/state/app_state.dart';

/// Регистрация и вход (демо-режим, без сети).
void main() {
  Future<void> settle(WidgetTester tester, [int n = 10]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AppState> launch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    expect(find.byType(OnboardingScreen), findsOneWidget);
    return state;
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await tester.tap(find.text(text).last);
    await settle(tester, 8);
  }

  Future<void> close(WidgetTester tester, AppState state) async {
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  }

  testWidgets('новый аккаунт: ключи, 24 слова с проверкой, защита, уведомления', (tester) async {
    final state = await launch(tester);
    await tapText(tester, 'Далее');
    await tapText(tester, 'Далее');
    await tapText(tester, 'Создать аккаунт');
    expect(find.text('Кто ты?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Маша');
    await tester.pump();
    await tapText(tester, 'Сгенерировать ключи');
    await settle(tester, 45); // анимация создания ключей
    await tapText(tester, 'Дальше');
    // Профиль уже есть, но главный экран — только после всех шагов.
    expect(state.onboarded, isTrue);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Ключ восстановления'), findsOneWidget);
    final words = (await state.recoveryWords())!;
    expect(find.byType(RecoveryWordsGrid), findsOneWidget);
    expect(find.text(words.first), findsOneWidget);

    await tapText(tester, 'Я записал(а)');
    // Проверка: выбрать три спрошенных слова.
    var picked = 0;
    for (var i = 0; i < words.length; i++) {
      final chip = find.byKey(ValueKey('check-$i-${words[i]}'));
      if (chip.evaluate().isEmpty) continue;
      await tester.tap(chip);
      await settle(tester, 3);
      picked++;
      if (picked == 3) break;
    }
    expect(picked, 3);
    await settle(tester, 8);
    expect(state.recoverySaved, isTrue);
    expect(find.text('Защити Veil'), findsOneWidget);
    await tapText(tester, 'Без PIN-кода');
    expect(find.text('Мгновенные уведомления'), findsOneWidget);
    await tapText(tester, 'Войти в Veil');
    await settle(tester, 10);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(state.setupPending, isFalse);
    expect(state.profile!.name, 'Маша');
    expect(tester.takeException(), isNull);
    await close(tester, state);
  });

  testWidgets('вход по ключу восстановления на новом телефоне', (tester) async {
    final state = await launch(tester);
    final old = Keys.generate();
    await tapText(tester, 'У меня уже есть аккаунт');
    expect(find.text('Вход в аккаунт'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('login-2')));
    await settle(tester);
    expect(find.byType(KeyLoginScreen), findsOneWidget);
    final words = Recovery.toWords(old.priv);
    // Опечатка в последнем слове — понятная ошибка.
    await tester.enterText(
      find.byKey(const ValueKey('recovery-input')),
      [...words.take(23), words[0] == 'zoo' ? 'abandon' : 'zoo'].join(' '),
    );
    await tester.pump();
    await tapText(tester, 'Дальше');
    expect(find.byType(KeyLoginScreen), findsOneWidget);
    expect(find.textContaining('не сходятся'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('recovery-input')), words.join(' '));
    await tester.pump();
    await tapText(tester, 'Дальше');
    expect(find.text('Ключ подошёл. Как тебя показывать друзьям?'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Маша');
    await tester.pump();
    await tapText(tester, 'Войти');
    expect(find.text('Защити Veil'), findsOneWidget);
    expect(state.profile!.fingerprint, old.pub, reason: 'тот же аккаунт');
    expect(state.recoverySaved, isTrue);
    await tapText(tester, 'Без PIN-кода');
    await tapText(tester, 'Войти в Veil');
    await settle(tester, 10);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, state);
  });

  testWidgets('профиль: ключ восстановления и перенос', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('nav-2')));
    await settle(tester);
    await tester.scrollUntilVisible(
      find.text('Ключ восстановления'),
      300,
      scrollable: find
          .descendant(of: find.byType(SettingsTab), matching: find.byType(Scrollable))
          .first,
    );
    expect(find.textContaining('Не записан'), findsOneWidget);
    // Наверх видимой области — чтобы плитку не закрывала нижняя панель вкладок.
    await tester.ensureVisible(find.text('Ключ восстановления'));
    await settle(tester);
    await tester.tap(find.text('Ключ восстановления'));
    await settle(tester);
    expect(find.byType(RecoveryWordsGrid), findsOneWidget);
    final words = (await state.recoveryWords())!;
    expect(find.text(words.last), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Показать как nsec'),
      200,
      scrollable: find
          .descendant(of: find.byType(RecoveryKeyScreen), matching: find.byType(Scrollable))
          .first,
    );
    await tapText(tester, 'Показать как nsec (для других приложений Nostr)');
    expect(find.textContaining('nsec1'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, state);
  });
}
