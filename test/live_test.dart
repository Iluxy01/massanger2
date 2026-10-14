import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/relay_pool.dart';
import 'package:veil/core/store.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Два «телефона» переписываются через локальный ретранслятор.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil');
  });

  tearDown(() async {
    await relay.stop();
    await tmp.delete(recursive: true);
  });

  Future<(AppState, Live)> phone(String name, {MemorySecrets? secrets, String? db}) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: secrets ?? MemorySecrets(),
      dbFactory: databaseFactoryFfi,
      dbPath: db ?? '${tmp.path}/$name.db',
      connector: (_) => WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relay.port}')),
      mediaDir: '${tmp.path}/$name-media',
    );
    if (!app.onboarded) {
      await app.createProfile(name: name, emoji: '🦊', colorIndex: 2);
    }
    return (app, live);
  }

  Future<void> until(bool Function() cond, {String? what}) async {
    for (var i = 0; i < 100; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  test('переписка, отчёты, реакции, заявка и восстановление из базы', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final bobSecrets = MemorySecrets();
    final (bob, bobLive) = await phone('Боб', secrets: bobSecrets);
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);

    // Алиса сканирует QR Боба.
    final invite = Invite.parse(bob.inviteLink)!;
    expect(invite.card.name, 'Боб');
    final c = await alice.addContact(invite);
    expect(c.id, bobLive.keys!.pub);

    // Боб получает «привет» и видит Алису как заявку.
    await until(() => bob.contact(aliceLive.keys!.pub) != null, what: 'hello');
    final aliceAtBob = bob.contact(aliceLive.keys!.pub)!;
    expect(aliceAtBob.name, 'Алиса');
    expect(aliceAtBob.request, isTrue);

    // Сообщение: ⏱ → ✓ → ✓✓
    alice.send(c.id, 'Привет, Боб! 👋');
    final sent = alice.messagesOf(c.id).last;
    await until(() => bob.messagesOf(aliceAtBob.id).isNotEmpty, what: 'сообщение');
    expect(bob.messagesOf(aliceAtBob.id).single.text, 'Привет, Боб! 👋');
    await until(() => bob.unread[aliceAtBob.id] == 1, what: 'непрочитанное');
    await until(() => sent.status == MsgStatus.delivered, what: 'доставлено');

    // Боб открывает чат → Алиса видит «прочитано».
    bob.openChat = aliceAtBob.id;
    bob.markRead(aliceAtBob.id);
    await until(() => sent.status == MsgStatus.read, what: 'прочитано');

    // Ответ с цитатой, секретное сообщение и реакция.
    final quoted = bob.messagesOf(aliceAtBob.id).last;
    bob.send(aliceAtBob.id, 'И тебе привет', replyTo: quoted);
    expect(aliceAtBob.request, isFalse, reason: 'ответ = принять заявку');
    bob.send(aliceAtBob.id, 'пароль 1234', secret: true);
    await until(() => alice.messagesOf(c.id).length == 3, what: 'ответы');
    final reply = alice.messagesOf(c.id)[1];
    expect(reply.replyTo?.id, sent.id);
    expect(alice.messagesOf(c.id)[2].secret, isTrue);

    alice.react(c.id, reply, '🔥');
    final bobsMsg = bob.messagesOf(aliceAtBob.id)[1];
    await until(() => bobsMsg.reaction == '🔥', what: 'реакция');

    // «Печатает…» (эфемерно)
    alice.userTyping(c.id);
    await until(() => bob.typing.contains(aliceAtBob.id), what: 'печатает');

    // Профиль обновился у друга.
    alice.updateProfile(name: 'Алиса К.', emoji: '🌸');
    await until(() => aliceAtBob.name == 'Алиса К.', what: 'профиль');

    // Эфемерные события ретранслятор не хранит.
    expect(relay.stored.every((e) => e['kind'] == 1059), isTrue);
    // А в хранимых конвертах не видно ни отправителя, ни текста.
    for (final e in relay.stored) {
      expect(e['pubkey'], isNot(aliceLive.keys!.pub));
      expect(e['pubkey'], isNot(bobLive.keys!.pub));
      expect(e['content'], isNot(contains('Привет')));
    }

    // Подтверждённые сообщения уходят из очереди переотправки.
    await until(() => sent.status == MsgStatus.read);
    expect(
      (await aliceLive.store.outboxIds()).contains(sent.id),
      isFalse,
      reason: 'после «доставлено» не переотправляем',
    );

    // Боб «перезапускает телефон» — всё на месте, из зашифрованной базы.
    await bobLive.close();
    final (bob2, bob2Live) = await phone('Боб', secrets: bobSecrets);
    expect(bob2.profile!.name, 'Боб');
    expect(bob2Live.keys!.pub, bobLive.keys!.pub);
    final msgs = bob2.messagesOf(aliceAtBob.id);
    expect(msgs.map((m) => m.text), ['Привет, Боб! 👋', 'И тебе привет', 'пароль 1234']);
    expect(msgs[1].replyTo?.id, msgs[0].id);
    expect(bob2.contact(aliceAtBob.id)!.name, 'Алиса К.');

    // Пока Боб «выключен», Алиса пишет — после включения сообщение приходит.
    await bob2Live.close();
    alice.send(c.id, 'Ты где?');
    await until(() => relay.stored.length >= 8);
    final (bob3, bob3Live) = await phone('Боб', secrets: bobSecrets);
    await until(
      () => bob3.messagesOf(aliceAtBob.id).any((m) => m.text == 'Ты где?'),
      what: 'офлайн-доставка',
    );
    expect(bob3.messagesOf(aliceAtBob.id).where((m) => m.text == 'Ты где?').length, 1);

    // Текст в базе зашифрован.
    final raw = await File('${tmp.path}/Боб.db').readAsBytes();
    expect(String.fromCharCodes(raw).contains('Ты где'), isFalse);

    await bob3Live.close();
    await aliceLive.close();
  });

  test('сообщение уходит после восстановления связи', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0);
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);

    final port = relay.port;
    await relay.stop();
    await until(() => aliceLive.pool!.onlineCount == 0, what: 'обрыв');
    alice.send(c.id, 'после обрыва');
    final m = alice.messagesOf(c.id).last;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(m.status, MsgStatus.sending);

    // Ретранслятор вернулся на том же порту.
    relay = FakeRelay();
    await relay.startOn(port);
    await until(() => m.status.index >= MsgStatus.sent.index, what: 'отправка из очереди');
    await until(
      () => bob.messagesOf(aliceLive.keys!.pub).any((x) => x.text == 'после обрыва'),
      what: 'доставка после обрыва',
    );
    await aliceLive.close();
    await bobLive.close();
  });

  test('статус «в сети»: появляется сразу и пропадает при сворачивании', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceLive.keys!.pub) != null, what: 'hello');
    bob.acceptRequest(aliceLive.keys!.pub);
    final bobAtAlice = c;
    final aliceAtBob = bob.contact(aliceLive.keys!.pub)!;

    // Боб пишет — Алиса видит его «в сети».
    bob.send(aliceAtBob.id, 'тут?');
    await until(() => bobAtAlice.online, what: 'в сети');

    // Боб свернул приложение — у Алисы сразу «не в сети» и время последнего визита.
    bob.setForeground(false);
    await until(() => !bobAtAlice.online, what: 'не в сети');
    expect(bobAtAlice.lastSeen, isNotNull);

    // Вернулся — снова в сети (пинг при возвращении).
    bob.setForeground(true);
    await until(() => bobAtAlice.online, what: 'снова в сети');

    await aliceLive.close();
    await bobLive.close();
  });

  test('удаление друга и повторный запрос', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    alice.send(c.id, 'раз');
    await until(() => bob.messagesOf(aliceLive.keys!.pub).isNotEmpty);

    await bob.deleteContact(aliceLive.keys!.pub);
    expect(bob.contact(aliceLive.keys!.pub), isNull);
    expect(bob.messagesOf(aliceLive.keys!.pub), isEmpty);
    expect(await bobLive.store.contacts(), isEmpty);

    // Алиса пишет снова — у Боба она появляется заявкой, старой переписки нет.
    alice.send(c.id, 'два');
    await until(() => bob.messagesOf(aliceLive.keys!.pub).isNotEmpty, what: 'заявка');
    expect(bob.contact(aliceLive.keys!.pub)!.request, isTrue);
    expect(bob.messagesOf(aliceLive.keys!.pub).map((m) => m.text), ['два']);
    await aliceLive.close();
    await bobLive.close();
  });

  test('«замёрзшее» соединение обнаруживается и переподключается', () async {
    final pool = RelayPool(
      ['ws://127.0.0.1:${relay.port}'],
      idleProbe: const Duration(seconds: 1),
      probeTimeout: const Duration(seconds: 1),
    );
    pool.start();
    await until(() => pool.onlineCount == 1, what: 'подключение');
    relay.frozen = true;
    await until(() => pool.onlineCount == 0, what: 'обнаружен обрыв');
    relay.frozen = false;
    await until(() => pool.onlineCount == 1, what: 'переподключение');
    await pool.close();
  });

  test('неподтверждённое сообщение уходит после перезапуска', () async {
    final aSecrets = MemorySecrets();
    var (alice, aliceLive) = await phone('Алиса', secrets: aSecrets);
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    final port = relay.port;
    await relay.stop();
    await until(() => aliceLive.pool!.onlineCount == 0);
    alice.send(c.id, 'переживу перезапуск');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Как будто очередь потерялась (старая версия) — сообщение всё равно уйдёт.
    await aliceLive.store.dequeueMessages(await aliceLive.store.outboxIds());
    await aliceLive.close();

    relay = FakeRelay();
    await relay.startOn(port);
    (alice, aliceLive) = await phone('Алиса', secrets: aSecrets);
    await until(
      () => bob.messagesOf(aliceLive.keys!.pub).any((m) => m.text == 'переживу перезапуск'),
      what: 'доставка после перезапуска',
    );
    final m = alice.messagesOf(c.id).single;
    await until(() => m.status.index >= MsgStatus.delivered.index, what: 'доставлено');
    await aliceLive.close();
    await bobLive.close();
  });

  test('база старой версии (v1) обновляется', () async {
    final path = '${tmp.path}/old.db';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
          await db.execute('CREATE TABLE contacts (id TEXT PRIMARY KEY, data BLOB)');
          await db.execute(
            'CREATE TABLE messages (id TEXT PRIMARY KEY, chat TEXT, ts INTEGER, data BLOB)',
          );
          await db.execute('CREATE TABLE seen (id TEXT PRIMARY KEY, ts INTEGER)');
          await db.execute(
            'CREATE TABLE outbox (id TEXT PRIMARY KEY, chat TEXT, msg TEXT, event TEXT, ts INTEGER)',
          );
          await db.insert('kv', {'k': 'since', 'v': '${nowSec()}'});
        },
      ),
    );
    await old.close();
    final store = (await Store.open(MemorySecrets(), factory: databaseFactoryFfi, path: path))!;
    await store.queue('m1', 'chat', {'t': 'msg', 'id': 'm1', 'text': 'x'});
    final due = await store.outboxDue();
    expect(due.single.payload['text'], 'x');
    expect(await store.get('since'), isNotNull);
    await store.close();
  });

  test('PIN хранится как хэш', () async {
    final secrets = MemorySecrets();
    final (app, live) = await phone('Пин', secrets: secrets);
    await app.setPin('2580');
    expect(secrets.data['pin'], isNot(contains('2580')));
    expect(await app.checkPin('2580'), isTrue);
    expect(await app.checkPin('0000'), isFalse);
    await app.setPin(null);
    expect(app.hasPin, isFalse);
    await live.close();
  });
}
