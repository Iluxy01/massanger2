import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/background.dart';
import 'package:veil/core/notifier.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Ответ из шторки уведомлений.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_reply');
  });

  tearDown(() async {
    await relay.stop();
    await tmp.delete(recursive: true);
  });

  Future<(AppState, Live)> phone(String name, {MemorySecrets? secrets}) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: secrets ?? MemorySecrets(),
      dbFactory: databaseFactoryFfi,
      dbPath: '${tmp.path}/$name.db',
      connector: (_) => WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relay.port}')),
      mediaDir: '${tmp.path}/$name-media',
    );
    if (!app.onboarded) await app.createProfile(name: name, emoji: '🦊', colorIndex: 2);
    return (app, live);
  }

  Future<void> until(bool Function() cond, {String? what}) async {
    for (var i = 0; i < 120; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  test('ответ из шторки уходит через живое приложение', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final aliceId = aliceLive.keys!.pub, bobId = bobLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);
    final hi = bob.send(aliceId, 'Ты где?');
    await until(() => alice.messagesOf(bobId).any((m) => m.id == hi.id), what: 'вопрос');

    // Фоновый поток уведомлений отдаёт ответ живому приложению и ждёт «принято».
    listenNotificationReplies(alice);
    final port = IsolateNameServer.lookupPortByName(SystemNotify.portName)!;
    final ack = ReceivePort();
    port.send({'c': bobId, 't': '  Уже еду 🚕 ', 'ack': ack.sendPort});
    expect(await ack.first.timeout(const Duration(seconds: 2)), isTrue);
    ack.close();
    await until(
      () => bob.messagesOf(aliceId).any((m) => m.text == 'Уже еду 🚕'),
      what: 'ответ у Боба',
    );
    expect(alice.unread[bobId], isNull, reason: 'чат прочитан');
    // Пустой ответ и ответ в чужой канал — ничего не отправляют.
    final before = alice.messagesOf(bobId).length;
    alice.replyFromNotification(bobId, '   ');
    alice.replyFromNotification('g_${'0' * 32}', 'привет');
    expect(alice.messagesOf(bobId).length, before);
    IsolateNameServer.removePortNameMapping(SystemNotify.portName);
    await aliceLive.close();
    await bobLive.close();
  });
}
