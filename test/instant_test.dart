import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/app.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Мгновенные уведомления: Veil в фоне, телефон спит.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('связь в фоне', () {
    late FakeRelay relay;
    late Directory tmp;

    setUp(() async {
      relay = FakeRelay();
      await relay.start();
      tmp = await Directory.systemTemp.createTemp('veil_instant');
    });

    tearDown(() async {
      await relay.stop();
      await tmp.delete(recursive: true);
    });

    Future<(AppState, Live)> phone(String name) async {
      final app = AppState();
      final live = await Live.boot(
        app,
        secrets: MemorySecrets(),
        dbFactory: databaseFactoryFfi,
        dbPath: '${tmp.path}/$name.db',
        connector: (_) => WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relay.port}')),
        mediaDir: '${tmp.path}/$name-media',
      );
      if (!app.onboarded) await app.createProfile(name: name, emoji: '🦊', colorIndex: 2);
      return (app, live);
    }

    Future<void> until(bool Function() cond, {String? what, int tenths = 120}) async {
      for (var i = 0; i < tenths; i++) {
        if (cond()) return;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      fail('не дождались: ${what ?? ''}');
    }

    test('будильник службы сразу переподключает и забирает пропущенное', () async {
      final (alice, aliceLive) = await phone('Алиса');
      final (bob, bobLive) = await phone('Боб');
      await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
      final aliceId = aliceLive.keys!.pub, bobId = bobLive.keys!.pub;
      await alice.addContact(Invite.parse(bob.inviteLink)!);
      await until(() => bob.contact(aliceId) != null, what: 'hello');
      bob.acceptRequest(aliceId);
      // Алиса свернула Veil.
      alice.setForeground(false);
      expect(alice.foreground, isFalse);

      // Ретранслятор пропал: попытки переподключиться всё реже (2, 4, 8 с…).
      final port = relay.port;
      await relay.stop();
      await until(() => aliceLive.pool!.onlineCount == 0, what: 'обрыв');
      final m = bob.send(aliceId, 'Ты тут?');
      await Future<void>.delayed(const Duration(seconds: 7));
      await relay.startOn(port);

      // Будильник у обоих: Боб отправляет накопившееся, Алиса — забирает,
      // не дожидаясь своей следующей попытки (через ~8 с).
      final sw = Stopwatch()..start();
      await bobLive.keepAlive();
      await aliceLive.keepAlive();
      await until(
        () => alice.messagesOf(bobId).any((x) => x.id == m.id),
        what: 'сообщение после будильника',
        tenths: 35,
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 4)));
      expect(aliceLive.pool!.onlineCount, greaterThan(0));
      await aliceLive.close();
      await bobLive.close();
    });

    test('будильник без сети и после закрытия не зависает', () async {
      final (_, live) = await phone('Алиса');
      await relay.stop();
      final sw = Stopwatch()..start();
      await live.keepAlive();
      expect(sw.elapsed, lessThan(const Duration(seconds: 16)));
      await live.close();
      await live.keepAlive();
    });
  });

  testWidgets('окно закрыли и открыли снова — приложение живо, всё на месте', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    final state = AppState.demo()..inAppBanner = false;
    await state.createProfile(name: 'Тест', emoji: '🐼', colorIndex: 1);
    await tester.pumpWidget(VeilApp(state: state));
    await tester.pump(const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(state.foreground, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(state.windowless, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(state.windowless, isFalse);
    expect(state.foreground, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    state.dispose();
  });
}
