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

/// Каналы: автор и подписчики через локальный ретранслятор.
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

  test('канал: пишет только автор, вступление по ссылке, отписка', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    final (carl, carlLive) = await phone('Карл');
    await until(
      () => [aliceLive, bobLive, carlLive].every((l) => l.pool!.onlineCount > 0),
      what: 'связь',
    );
    final aliceId = aliceLive.keys!.pub;
    final bobId = bobLive.keys!.pub, carlId = carlLive.keys!.pub;
    // Алиса дружит с Бобом; Карла она не знает.
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);

    final ch = await alice.createChannel(
      name: 'Новости',
      emoji: '📢',
      colorIndex: 1,
      pubs: [bobId],
    );
    expect(ch.isChannel, isTrue);
    expect(alice.messagesOf(ch.id), isEmpty, reason: 'служебное — не в ленте автора');
    await until(() => bob.contact(ch.id) != null, what: 'канал у Боба');
    final atBob = bob.contact(ch.id)!;
    expect(atBob.isChannel, isTrue);
    expect(atBob.request, isFalse, reason: 'подписал друг');
    expect(atBob.group!.admin, aliceId);
    expect(atBob.group!.members.map((m) => m.pub), [aliceId], reason: 'подписчиков не видно');

    final post = alice.send(ch.id, 'Первый пост 🎉');
    await until(() => bob.messagesOf(ch.id).any((m) => m.id == post.id), what: 'пост у Боба');
    await until(() => post.status.index >= MsgStatus.delivered.index, what: 'доставлено');

    // Подписчик написать в канал не может: автор его сообщение не примет.
    final hack = bob.send(ch.id, 'я тоже автор');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(alice.messagesOf(ch.id).any((m) => m.id == hack.id), isFalse);

    // Карл вступает по ссылке — сразу, без «принять?».
    final link = alice.channelLink(ch.id)!;
    final inv = ChannelInvite.parse('Подписывайся: $link')!;
    expect(inv.name, 'Новости');
    expect(carl.joinChannel(inv), isTrue);
    await until(() => carl.contact(ch.id) != null, what: 'канал у Карла', seconds: 20);
    expect(carl.contact(ch.id)!.request, isFalse, reason: 'сам просился');
    expect(alice.contact(ch.id)!.group!.subscribers, 2);
    expect(bob.contact(ch.id)!.group!.members.length, 1, reason: 'Боб не узнал о Карле');

    final second = alice.send(ch.id, 'Второй пост');
    await until(
      () => [bob, carl].every((a) => a.messagesOf(ch.id).any((m) => m.id == second.id)),
      what: 'второй пост у обоих',
    );

    // Неверный код — не пускает.
    final (dan, danLive) = await phone('Дэн');
    await until(() => danLive.pool!.onlineCount > 0);
    await alice.resetChannelLink(ch.id);
    dan.joinChannel(inv); // старая ссылка
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(alice.contact(ch.id)!.group!.has(danLive.keys!.pub), isFalse);

    // Автор отписывает Боба: он больше не получает посты.
    await alice.removeMember(ch.id, bobId);
    await until(() => bob.contact(ch.id)!.group!.left, what: 'Боб отписан');
    // Карл отписывается сам — у Алисы в ленте канала ничего лишнего.
    await carl.leaveGroup(ch.id);
    await until(() => !alice.contact(ch.id)!.group!.has(carlId), what: 'Карл отписался');
    expect(alice.messagesOf(ch.id).map((m) => m.id), [post.id, second.id]);
    final third = alice.send(ch.id, 'Третий');
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(bob.messagesOf(ch.id).any((m) => m.id == third.id), isFalse);
    expect(carl.messagesOf(ch.id).any((m) => m.id == third.id), isFalse);

    for (final l in [aliceLive, bobLive, carlLive, danLive]) {
      await l.close();
    }
  });
}
