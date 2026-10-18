import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/recovery.dart';
import 'package:veil/core/store.dart';
import 'package:veil/core/transfer.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Вход на новом телефоне: перенос по QR и ключ восстановления.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_move');
  });

  tearDown(() async {
    await relay.stop();
    await tmp.delete(recursive: true);
  });

  Future<(AppState, Live)> phone(String name, {bool profile = true}) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: MemorySecrets(),
      dbFactory: databaseFactoryFfi,
      dbPath: '${tmp.path}/$name.db',
      connector: (_) => WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relay.port}')),
      mediaDir: '${tmp.path}/$name-media',
      tempDir: (await Directory('${tmp.path}/$name-tmp').create()).path,
    );
    if (profile && !app.onboarded) {
      await app.createProfile(name: name, emoji: '🦊', colorIndex: 2);
    }
    return (app, live);
  }

  Future<void> until(bool Function() cond, {String? what}) async {
    for (var i = 0; i < 150; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  test('перенос по коду: друзья, переписка, настройки — и дальше на связи', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final aliceId = aliceLive.keys!.pub, bobId = bobLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);
    final hi = bob.send(aliceId, 'Привет! Как дела?');
    await until(() => alice.messagesOf(bobId).any((m) => m.id == hi.id), what: 'письмо');
    alice.send(bobId, 'Отлично 🙂');
    alice.setAccent(3);

    // Старый телефон: пакет на ретрансляторы, код — на экран.
    final ticket = await alice.prepareTransfer();
    final code = ticket.encode();
    expect(code, startsWith('veil://move?'));
    expect(code.length, lessThan(600), reason: 'помещается в QR');
    final parsed = TransferTicket.parse(code)!;
    expect(parsed.key, ticket.key);
    expect(parsed.sha, ticket.sha);

    // Новый телефон: ещё без профиля — сканирует код.
    final (alice2, alice2Live) = await phone('Алиса-новый', profile: false);
    expect(alice2.onboarded, isFalse);
    await alice2.receiveTransfer(parsed);
    expect(alice2.onboarded, isTrue);
    expect(alice2Live.keys!.pub, aliceId);
    expect(alice2.profile!.name, 'Алиса');
    expect(alice2.accentIndex, 3);
    final bob2 = alice2.contact(bobId)!;
    expect(bob2.request, isFalse);
    expect(
      alice2.messagesOf(bobId).map((m) => m.text),
      containsAll(['Привет! Как дела?', 'Отлично 🙂']),
    );

    // И дальше на связи: Боб пишет — новый телефон получает.
    await until(() => alice2Live.pool!.onlineCount > 0);
    final next = bob.send(aliceId, 'Ты с нового телефона?');
    await until(
      () => alice2.messagesOf(bobId).any((m) => m.id == next.id),
      what: 'на новом телефоне',
    );
    await alice.finishTransfer();
    await aliceLive.close();
    await alice2Live.close();
    await bobLive.close();
  });

  test('код переноса: чужое и испорченное не принимается', () {
    expect(TransferTicket.parse('veil://add?x=1'), isNull);
    expect(TransferTicket.parse('veil://move?k=abc'), isNull);
    expect(TransferTicket.parse('hello'), isNull);
  });

  test('вход по ключу восстановления: тот же аккаунт, пришедшее — заявками', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final aliceId = aliceLive.keys!.pub, bobId = bobLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);
    final hi = bob.send(aliceId, 'Не забудь ключи');
    await until(() => alice.messagesOf(bobId).any((m) => m.id == hi.id), what: 'письмо');
    final words = (await alice.recoveryWords())!;
    expect(words, hasLength(24));
    await aliceLive.close();

    // Новый телефон, только 24 слова.
    final (alice2, alice2Live) = await phone('Алиса-ключ', profile: false);
    final priv = Recovery.parse(words.join(' '));
    await alice2.createProfile(name: 'Алиса', emoji: '🦊', colorIndex: 2, priv: priv);
    expect(alice2Live.keys!.pub, aliceId);
    expect(alice2.recoverySaved, isTrue);
    await until(() => alice2.messagesOf(bobId).any((m) => m.id == hi.id), what: 'старое письмо');
    expect(alice2.contact(bobId)!.request, isTrue, reason: 'друзей подтверждаем заново');
    await alice2Live.close();
    await bobLive.close();
  });
}
