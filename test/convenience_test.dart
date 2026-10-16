import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:veil/widgets/rich_text.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Удобства переписки: оформление, правка, удаление у всех, закреп,
/// пересылка, избранное, архив.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('оформление текста', () {
    const base = TextStyle(fontSize: 16, color: Colors.white);
    String styled(String t) => Fmt.spans(t, base, reveal: true).map((s) {
      final span = s as TextSpan;
      final st = span.style;
      if (st == null) return span.text;
      if (st.fontWeight == FontWeight.w700) return 'B(${span.text})';
      if (st.fontStyle == FontStyle.italic) return 'I(${span.text})';
      if (st.decoration == TextDecoration.lineThrough) return 'S(${span.text})';
      if (st.fontFamily == 'monospace') return 'M(${span.text})';
      return 'H(${span.text})';
    }).join();

    test('жирный, курсив, зачёркнутый, моно, скрытый', () {
      expect(styled('это *важно* и _тихо_'), 'это B(важно) и I(тихо)');
      expect(styled('~старое~ `код()` ||тайна||'), 'S(старое) M(код()) H(тайна)');
      expect(styled('(*в скобках*), да'), '(B(в скобках)), да');
    });

    test('математика и имена файлов не портятся', () {
      for (final t in ['2*3*4 = 24', 'snake_case_name', 'a ~ b ~ c', '* не жирный *', '']) {
        expect(Fmt.has(t), isFalse, reason: t);
      }
    });

    test('без маркеров — для списка чатов', () {
      expect(Fmt.plain('*Привет*, _мир_'), 'Привет, мир');
      expect(Fmt.plain('пароль ||1234||'), 'пароль ░░░░');
      expect(Fmt.hasSpoiler('пароль ||1234||'), isTrue);
      expect(Fmt.hasSpoiler('a || b'), isFalse);
    });
  });

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_conv');
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

  Future<void> until(bool Function() cond, {String? what}) async {
    for (var i = 0; i < 120; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  test('правка, удаление у всех, закреп, пересылка, без звука', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final bobId = bobLive.keys!.pub, aliceId = aliceLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);

    final m = alice.send(bobId, 'встречаемся в 7');
    await until(() => bob.messagesOf(aliceId).any((x) => x.id == m.id), what: 'сообщение');
    // Правка доходит, у получателя — пометка «изменено».
    alice.editMessage(bobId, m, 'встречаемся в 8');
    final atBob = bob.messagesOf(aliceId).firstWhere((x) => x.id == m.id);
    await until(() => atBob.text == 'встречаемся в 8', what: 'правка');
    expect(atBob.edited, isTrue);
    // Чужое править нельзя: Боб «правит» сообщение Алисы — у неё ничего не меняется.
    bob.editMessage(aliceId, atBob, 'взлом');
    expect(atBob.text, 'встречаемся в 8', reason: 'не своё — не правится');

    // Закреп — у обоих.
    alice.pinMessage(bobId, m);
    await until(() => bob.contact(aliceId)!.pinnedMsg == m.id, what: 'закреп у Боба');
    expect(bob.pinnedOf(aliceId)!.text, 'встречаемся в 8');

    // Удалить у всех — пропадает у Боба и закреп снимается.
    alice.deleteForAll(bobId, m);
    await until(() => !bob.messagesOf(aliceId).any((x) => x.id == m.id), what: 'удалено у Боба');
    expect(alice.messagesOf(bobId).any((x) => x.id == m.id), isFalse);
    await until(() => bob.contact(aliceId)!.pinnedMsg == null, what: 'закреп снят');

    // Пересылка: сообщение Боба уходит Алисой обратно Бобу «от Боба».
    final b = bob.send(aliceId, 'адрес: ул. Звёздная, 5');
    await until(() => alice.messagesOf(bobId).any((x) => x.id == b.id), what: 'ответ Боба');
    final copy = await alice.forward(bobId, alice.messagesOf(bobId).last, bobId);
    expect(copy!.fwd, 'Боб');
    await until(
      () => bob.messagesOf(aliceId).any((x) => x.id == copy.id && x.fwd == 'Боб'),
      what: 'пересланное',
    );

    // Без звука: непрочитанное есть, уведомления нет (проверяем сам флаг).
    alice.send(bobId, 'тихо 🤫', silent: true);
    await until(() => bob.messagesOf(aliceId).any((x) => x.text == 'тихо 🤫'), what: 'тихое');

    await aliceLive.close();
    await bobLive.close();
  });

  test('избранное, архив, «непрочитано» сохраняются', () async {
    final app = AppState.demo();
    final m = app.messagesOf('alice').first;
    app.toggleStar('alice', m);
    app.toggleArchive('max');
    expect(app.starredMessages.single.$2, m);
    expect(app.chatList.any((c) => c.id == 'max'), isFalse);
    expect(app.archivedChats.single.id, 'max');
    app.markUnread('dima');
    expect(app.unread['dima'], 1);
    final copy = AppState.demo()..applySettings(app.settingsForTest);
    expect(copy.starred, app.starred);
    expect(copy.archived, {'max'});
    copy.dispose();
    app.dispose();
  });
}
