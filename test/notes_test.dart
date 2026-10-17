import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// «Заметки», черновики, пересылка в несколько чатов.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_notes');
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

  test('«Заметки» никуда не отправляются, но хранятся', () async {
    final secrets = MemorySecrets();
    final (alice, live) = await phone('Алиса', secrets: secrets);
    await until(() => live.pool!.onlineCount > 0);
    final notes = alice.notes();
    expect(alice.friends.any((c) => c.isNotes), isFalse, reason: 'не «друг»');
    // Дать уйти стартовым сигналам («я в сети»), потом считать.
    await Future<void>.delayed(const Duration(seconds: 1));
    final before = relay.published;
    final m = alice.send(notes.id, 'купить хлеб');
    expect(m.status, MsgStatus.read, reason: 'сразу «готово»');
    alice.react(notes.id, m, '👍');
    alice.userTyping(notes.id);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(await live.store.outboxIds(), isEmpty, reason: 'ничего не в очереди');
    expect(relay.published, before, reason: 'в сеть ничего не ушло');
    expect(alice.chatList.any((c) => c.isNotes), isTrue);
    await live.close();

    // После перезапуска — на месте.
    final (again, live2) = await phone('Алиса', secrets: secrets);
    expect(again.messagesOf(Contact.notesId).map((x) => x.text), ['купить хлеб']);
    expect(again.contact(Contact.notesId)?.name, 'Заметки');
    await live2.close();
  });

  test('черновик переживает перезапуск и держит чат в списке', () async {
    final secrets = MemorySecrets();
    final (alice, live) = await phone('Алиса', secrets: secrets);
    final (bob, bobLive) = await phone('Боб');
    final bobId = bobLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    expect(alice.chatList.any((c) => c.id == bobId), isFalse, reason: 'пока пусто');
    alice.saveDraft(bobId, 'не забыть сказать про');
    expect(alice.chatList.first.id, bobId, reason: 'чат с черновиком — в списке');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await live.close();

    final (again, live2) = await phone('Алиса', secrets: secrets);
    expect(again.drafts[bobId], 'не забыть сказать про');
    expect(again.chatList.any((c) => c.id == bobId), isTrue);
    // Отправили — черновик ушёл (и из базы тоже).
    again.send(bobId, 'не забыть сказать про пятницу');
    expect(again.drafts[bobId], isNull);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await live2.close();
    final (third, live3) = await phone('Алиса', secrets: secrets);
    expect(third.drafts, isEmpty);
    await live3.close();
    await bobLive.close();
  });

  test('пересылка сразу в несколько чатов, включая «Заметки»', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    final (carl, carlLive) = await phone('Карл');
    await until(
      () => [aliceLive, bobLive, carlLive].every((l) => l.pool!.onlineCount > 0),
      what: 'связь',
    );
    final bobId = bobLive.keys!.pub, carlId = carlLive.keys!.pub;
    final aliceId = aliceLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await alice.addContact(Invite.parse(carl.inviteLink)!);
    final m = alice.send(alice.notes().id, 'адрес: ул. Звёздная, 5');
    for (final to in [bobId, carlId]) {
      await alice.forward(Contact.notesId, m, to);
    }
    await until(
      () =>
          bob.messagesOf(aliceId).any((x) => x.text == m.text) &&
          carl.messagesOf(aliceId).any((x) => x.text == m.text),
      what: 'пересланное у обоих',
    );
    await aliceLive.close();
    await bobLive.close();
    await carlLive.close();
  });
}
