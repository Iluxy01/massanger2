import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/app.dart';
import 'package:veil/core/store.dart';
import 'package:veil/screens/cover_screens.dart';
import 'package:veil/screens/lock_screen.dart';
import 'package:veil/screens/settings_tab.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';

import 'ui_test.dart' show settle;

/// «Тайник»: скрытые чаты, PIN «под принуждением», маскировка.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('скрытый чат не виден нигде, пока тайник закрыт', () async {
    final app = AppState.demo();
    await app.setVaultPin('1111');
    app.toggleStar('alice', app.messagesOf('alice').first);
    app.setHidden('alice', true);
    expect(app.chatList.any((c) => c.id == 'alice'), isFalse);
    expect(app.friends.any((c) => c.id == 'alice'), isFalse);
    expect(app.starredMessages, isEmpty);
    expect(app.totalUnread, 1, reason: 'непрочитанные Алисы не светятся в счётчике');
    expect(app.hiddenChats.single.id, 'alice');
    expect(await app.checkVault('1111'), isTrue);
    expect(await app.checkVault('2222'), isFalse);
    // Открыли тайник с экрана блокировки — видно до следующей блокировки.
    await app.setPin('1234');
    app.lock();
    expect(await app.unlockWith('1111'), isTrue);
    expect(app.locked, isFalse);
    expect(app.chatList.any((c) => c.id == 'alice'), isTrue);
    app.lock();
    expect(app.vaultOpen, isFalse);
    expect(app.chatList.any((c) => c.id == 'alice'), isFalse);
    // Без PIN тайника скрытые чаты возвращаются.
    await app.setVaultPin(null);
    expect(app.chatList.any((c) => c.id == 'alice'), isTrue);
    app.dispose();
  });

  test('PIN «под принуждением»: тайника как будто нет; занятые PIN не повторить', () async {
    final app = AppState.demo();
    await app.setPin('1234');
    await app.setVaultPin('1111');
    await app.setDuressPin('0000');
    app.setHidden('kate', true);
    expect(await app.pinTaken('1234'), isTrue);
    expect(await app.pinTaken('1111'), isTrue);
    expect(await app.pinTaken('0000'), isTrue);
    expect(await app.pinTaken('5555'), isFalse);
    app.lock();
    expect(await app.unlockWith('9999'), isFalse);
    expect(app.locked, isTrue);
    expect(await app.unlockWith('0000'), isTrue);
    expect((app.locked, app.decoy), (false, true));
    expect(app.hiddenChats, isEmpty);
    expect(await app.checkVault('1111'), isFalse, reason: 'тайник не открывается');
    app.setHidden('alice', true);
    expect(app.contact('alice')!.hidden, isFalse, reason: 'ничего не меняется');
    // Обычный вход — всё как было.
    app.lock();
    expect(await app.unlockWith('1234'), isTrue);
    expect(app.decoy, isFalse);
    expect(app.hiddenChats.single.id, 'kate');
    app.dispose();
  });

  test('PIN «под принуждением» со стиранием и секреты в Keystore', () async {
    final tmp = await Directory.systemTemp.createTemp('veil_vault');
    final secrets = MemorySecrets();
    Future<(AppState, Live)> boot() async {
      final app = AppState();
      final live = await Live.boot(
        app,
        secrets: secrets,
        dbFactory: databaseFactoryFfi,
        dbPath: '${tmp.path}/v.db',
        network: false,
        mediaDir: '${tmp.path}/media',
      );
      if (!app.onboarded) await app.createProfile(name: 'Я', emoji: '🦊', colorIndex: 1);
      return (app, live);
    }

    var (app, live) = await boot();
    await app.setPin('1234');
    await app.setVaultPin('1111');
    await app.setDuressPin('0000', wipe: true);
    // Только соль и хэш — самих PIN нигде нет.
    for (final k in ['pin', 'vault', 'duress']) {
      expect(secrets.data[k], contains(':'));
      expect(secrets.data[k], isNot(contains('1234')));
    }
    await live.close();
    (app, live) = await boot();
    expect((app.locked, app.vaultSet, app.duressSet, app.duressWipe), (true, true, true, true));
    expect(await app.unlockWith('0000'), isTrue);
    expect(app.onboarded, isFalse, reason: 'всё стёрто');
    expect(secrets.data['vault'], isNull);
    await app.live?.close();
    await tmp.delete(recursive: true);
  });

  test('калькулятор-обложка считает по-настоящему', () {
    double? c(String e) => _CalcProbe.calc(e);
    expect(c('2+3×4'), 14);
    expect(c('10÷4'), 2.5);
    expect(c('7−10'), -3);
    expect(c('5÷0'), isNull);
    expect(c('1,5+1,5'), 3);
    expect(_CalcProbe.fmt(2.5), '2,5');
    expect(_CalcProbe.fmt(4), '4');
  });

  testWidgets('вкладка «Тайник» в настройках; при «принуждении» всё выключено', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo();
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await state.setPin('1234');
    await state.setVaultPin('1111');
    await state.setDuressPin('0000');
    state.locked = false;
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    navigatorKey.currentState!.push(VaultSettingsScreen.route());
    await settle(tester);
    for (final t in ['Скрытые чаты', 'PIN «ПОД ПРИНУЖДЕНИЕМ»', 'Маскировка значка']) {
      expect(find.textContaining(t.toUpperCase()), findsWidgets, reason: t);
    }
    expect(find.text('Открыть тайник'), findsOneWidget);
    expect(find.text('Прячет тайник'), findsOneWidget);
    // Вход «под принуждением» — тайника как будто нет.
    state.lock();
    await state.unlockWith('0000');
    await settle(tester);
    expect(find.text('Открыть тайник'), findsNothing);
    expect(find.text('Прячет тайник'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });

  testWidgets('маскировка: калькулятор, код и «=» открывают Veil', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo();
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await state.setDisguise(1, code: '2580');
    state.lock();
    await tester.pumpWidget(VeilApp(state: state));
    await settle(tester);
    expect(find.byType(CalculatorCover), findsOneWidget);
    // Обычный счёт — ничего не выдаёт.
    for (final k in ['1', '2', '+', '3', '=']) {
      await tester.tap(find.text(k).last);
      await tester.pump();
    }
    await settle(tester);
    expect(find.text('15'), findsWidgets);
    expect(state.covered, isTrue);
    await tester.tap(find.text('C'));
    for (final k in ['2', '5', '8', '0', '=']) {
      await tester.tap(find.text(k).last);
      await tester.pump();
    }
    await settle(tester);
    expect(state.covered, isFalse);
    expect(find.byType(CalculatorCover), findsNothing);
    expect(find.byType(LockScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}

/// Доступ к арифметике калькулятора-обложки.
typedef _CalcProbe = CalculatorCoverMath;
