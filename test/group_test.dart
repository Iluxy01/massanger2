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

/// Групповые чаты: три «телефона» через локальный ретранслятор.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_group');
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

  Future<void> until(bool Function() cond, {String? what, int seconds = 12}) async {
    for (var i = 0; i < seconds * 10; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  test('группа: создание, переписка незнакомых участников, удаление, выход', () async {
    final aliceSecrets = MemorySecrets();
    var (alice, aliceLive) = await phone('Алиса', secrets: aliceSecrets);
    final (bob, bobLive) = await phone('Боб');
    final (carol, carolLive) = await phone('Кира');
    await until(
      () => [aliceLive, bobLive, carolLive].every((l) => l.pool!.onlineCount > 0),
      what: 'связь',
    );
    final bobId = bobLive.keys!.pub, carolId = carolLive.keys!.pub;
    final aliceId = aliceLive.keys!.pub;
    // Алиса дружит с обоими; Боб и Кира друг друга не знают.
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await alice.addContact(Invite.parse(carol.inviteLink)!);
    await until(() => bob.contact(aliceId) != null && carol.contact(aliceId) != null);
    bob.acceptRequest(aliceId);

    final g = await alice.createGroup(
      name: 'Поход',
      emoji: '🏕️',
      colorIndex: 3,
      pubs: [bobId, carolId],
    );
    expect(g.isGroup, isTrue);
    expect(g.group!.members.map((m) => m.pub), [aliceId, bobId, carolId]);
    expect(alice.friends.any((c) => c.isGroup), isFalse, reason: 'группа — не друг');

    // Оба узнают о группе из первого же сообщения.
    await until(
      () => bob.contact(g.id) != null && carol.contact(g.id) != null,
      what: 'группа у участников',
    );
    final atBob = bob.contact(g.id)!;
    expect(atBob.name, 'Поход');
    expect(atBob.emoji, '🏕️');
    expect(atBob.request, isFalse, reason: 'позвал друг');
    expect(carol.contact(g.id)!.request, isTrue, reason: 'Алиса для Киры — ещё заявка');
    final created = bob.messagesOf(g.id).single;
    expect(created.kind, MsgKind.event);
    expect(created.from, aliceId);
    expect(bob.memberName(g.id, aliceId), 'Алиса');
    // Кира принимает приглашение.
    carol.acceptRequest(g.id);

    // Боб пишет в группу — сообщение у Алисы и у Киры, которая Боба не знает.
    final hi = bob.send(g.id, 'Всем привет! Беру палатку ⛺');
    await until(
      () => [alice, carol].every((a) => a.messagesOf(g.id).any((m) => m.text == hi.text)),
      what: 'сообщение Боба у всех',
    );
    final atCarol = carol.messagesOf(g.id).firstWhere((m) => m.text == hi.text);
    expect(atCarol.from, bobId);
    expect(carol.memberName(g.id, bobId), 'Боб');
    expect(carol.contact(bobId), isNull, reason: 'Боб не стал «заявкой» у Киры');
    expect(carol.unread[g.id], greaterThan(0));
    await until(() => hi.status == MsgStatus.delivered, what: 'доставлено');

    // Ответ с цитатой и голос в опросе.
    final poll = alice.sendPoll(g.id, Poll(question: 'Когда?', options: ['Сб', 'Вс']));
    await until(() => carol.messagesOf(g.id).any((m) => m.id == poll.id), what: 'опрос');
    carol.vote(g.id, carol.messagesOf(g.id).firstWhere((m) => m.id == poll.id), [1]);
    await until(() => poll.poll!.votes[carolId]?.first == 1, what: 'голос Киры у Алисы');
    await until(
      () => bob.messagesOf(g.id).firstWhere((m) => m.id == poll.id).poll!.votes[carolId] != null,
      what: 'голос Киры у Боба',
    );

    // Алиса удаляет Киру: та узнаёт, и новые сообщения ей уже не приходят.
    await alice.removeMember(g.id, carolId);
    await until(() => carol.contact(g.id)!.group!.left, what: 'Кира удалена');
    await until(() => !bob.contact(g.id)!.group!.has(carolId), what: 'состав у Боба');
    bob.send(g.id, 'без Киры');
    await until(
      () => alice.messagesOf(g.id).any((m) => m.text == 'без Киры'),
      what: 'сообщение у Алисы',
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(carol.messagesOf(g.id).any((m) => m.text == 'без Киры'), isFalse);

    // Перезапуск Алисы: группа и переписка на месте.
    await aliceLive.close();
    (alice, aliceLive) = await phone('Алиса', secrets: aliceSecrets);
    final again = alice.contact(g.id)!;
    expect(again.group!.members.map((m) => m.pub), [aliceId, bobId]);
    expect(alice.messagesOf(g.id).any((m) => m.text == hi.text), isTrue);

    // Боб выходит — Алиса видит, что остался одна.
    await bob.leaveGroup(g.id);
    expect(bob.contact(g.id)!.group!.left, isTrue);
    await until(() => !alice.contact(g.id)!.group!.has(bobId), what: 'Боб вышел');
    expect(alice.messagesOf(g.id).last.ev, 'leave');

    await aliceLive.close();
    await bobLive.close();
    await carolLive.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('администратор выходит — права переходят следующему', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final bobId = bobLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    final g = await alice.createGroup(name: 'Двое', emoji: '👥', colorIndex: 0, pubs: [bobId]);
    await until(() => bob.contact(g.id) != null, what: 'группа у Боба');
    await alice.leaveGroup(g.id);
    await until(() => bob.contact(g.id)!.group!.admin == bobId, what: 'Боб — администратор');
    expect(bob.contact(g.id)!.group!.members.map((m) => m.pub), [bobId]);
    await aliceLive.close();
    await bobLive.close();
  });
}
