import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/games/lots.dart';
import 'package:veil/games/sea.dart';
import 'package:veil/games/ttt.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Игры, жребий, рисунок, эффекты, истории и дни рождения — между двумя
/// телефонами через ретранслятор.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_fun');
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
    for (var i = 0; i < 150; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  /// Два друга: Алиса и Боб.
  Future<(AppState, Live, AppState, Live)> friends() async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final aliceId = aliceLive.keys!.pub;
    await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);
    return (alice, aliceLive, bob, bobLive);
  }

  Message at(AppState app, String chat, String id) =>
      app.messagesOf(chat).firstWhere((m) => m.id == id);

  test('игры: ходы доходят, морской бой отвечает сам, жребий честный', () async {
    final (alice, aliceLive, bob, bobLive) = await friends();
    final bobId = bobLive.keys!.pub, aliceId = aliceLive.keys!.pub;

    // Крестики-нолики: ход Алисы, ответ Боба.
    final t = alice.sendGame(bobId, Game(type: 'ttt'));
    await until(() => bob.messagesOf(aliceId).any((m) => m.id == t.id), what: 'игра у Боба');
    expect(alice.gameMove(bobId, t, '4'), isTrue);
    expect(alice.gameMove(bobId, t, '0'), isFalse, reason: 'не её ход');
    await until(() => at(bob, aliceId, t.id).game!.moves.length == 1, what: 'ход Алисы');
    expect(bob.gameMove(aliceId, at(bob, aliceId, t.id), '4'), isFalse, reason: 'клетка занята');
    expect(bob.gameMove(aliceId, at(bob, aliceId, t.id), '0'), isTrue);
    await until(() => t.game!.moves.length == 2, what: 'ход Боба');
    expect((t.game!.state as Ttt).cells[0], 1);

    // Кубик: Боб бросает свою половину сам, Алиса раскрывает — у обоих одно.
    final r0 = Lot.random();
    final d = alice.sendGame(bobId, Game(type: 'dice', commit: Lot.hash(r0), secret: r0));
    await until(() => (d.game!.state as Lot?)?.result != null, what: 'кубик брошен');
    await until(
      () => bob
          .messagesOf(aliceId)
          .any(
            (m) => m.id == d.id && (m.game!.state as Lot).result == (d.game!.state as Lot).result,
          ),
      what: 'у Боба то же число',
    );
    expect(at(bob, aliceId, d.id).game!.secret, isNull, reason: 'секрет Алисы не ушёл');

    // Морской бой: Боб расставляет, Алиса стреляет по его кораблю — телефон
    // Боба отвечает сам.
    final a = SeaLayout.random(), b = SeaLayout.random();
    final sea = alice.sendGame(
      bobId,
      Game(type: 'sea', commit: seaCommit(a.encode(), 'sa'), secret: '${a.encode()}.sa'),
    );
    await until(() => bob.messagesOf(aliceId).any((m) => m.id == sea.id), what: 'бой у Боба');
    final bs = at(bob, aliceId, sea.id);
    expect(bs.game!.status().turn, 1, reason: 'Бобу расставлять');
    expect(
      bob.gameSetup(aliceId, bs, '${b.encode()}.sb', 'h${seaCommit(b.encode(), 'sb')}'),
      isTrue,
    );
    await until(() => (sea.game!.state as Sea).ready, what: 'расстановка Боба');
    final target = b.cells.first;
    expect(alice.gameMove(bobId, sea, 's$target'), isTrue);
    await until(() => (sea.game!.state as Sea).shots[0][target] != null, what: 'ответ на выстрел');
    expect((sea.game!.state as Sea).shots[0][target], anyOf('h', 'k'));
    expect(sea.game!.status().turn, 0, reason: 'попала — стреляет ещё');

    await aliceLive.close();
    await bobLive.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('рисунок вдвоём, эффекты, ответ на историю', () async {
    final (alice, aliceLive, bob, bobLive) = await friends();
    final bobId = bobLive.keys!.pub, aliceId = aliceLive.keys!.pub;

    final pic = alice.sendDrawing(bobId);
    await until(() => bob.messagesOf(aliceId).any((m) => m.id == pic.id), what: 'рисунок');
    Stroke stroke(String id, String by) =>
        Stroke(id: id, by: by, color: 0xFFFF0000, width: 10, pts: [100, 100, 500, 500, 900, 120]);
    alice.drawAdd(bobId, pic, stroke('s1', alice.myKey));
    await until(() => at(bob, aliceId, pic.id).drawing!.strokes.length == 1, what: 'штрих');
    final got = at(bob, aliceId, pic.id).drawing!.strokes.single;
    expect(got.by, aliceId, reason: 'автор — по подписи, а не по словам');
    expect(got.pts, [100, 100, 500, 500, 900, 120]);
    bob.drawAdd(aliceId, at(bob, aliceId, pic.id), stroke('s2', bob.myKey));
    await until(() => pic.drawing!.strokes.length == 2, what: 'штрих Боба');
    // Отменить можно только свой штрих.
    bob.drawUndo(aliceId, at(bob, aliceId, pic.id));
    await until(() => pic.drawing!.strokes.length == 1, what: 'отмена');
    expect(pic.drawing!.strokes.single.id, 's1');

    // Эффекты.
    final fx = alice.send(bobId, 'ура!', fx: 'fireworks');
    await until(() => bob.messagesOf(aliceId).any((m) => m.id == fx.id), what: 'эффект');
    final fxAtBob = at(bob, aliceId, fx.id);
    expect(fxAtBob.effect, 'fireworks');
    expect(fxAtBob.fxSeen, isFalse);
    expect(fx.fxSeen, isTrue, reason: 'у себя показан при отправке');
    bob.markFxSeen(aliceId, fxAtBob);
    expect(fxAtBob.fxSeen, isTrue);
    expect(
      Message(id: 'x', mine: false, text: 'С днём рождения, Боб!', time: DateTime.now()).effect,
      'confetti',
    );
    expect(Message(id: 'x', mine: false, text: 'с др 🎉', time: DateTime.now()).effect, 'confetti');
    expect(Message(id: 'x', mine: false, text: 'сдружились', time: DateTime.now()).effect, isNull);

    // Ответ на историю приходит в личку с пометкой.
    final reply = bob.send(aliceId, 'класс!', story: '📷 Фото из истории');
    await until(() => alice.messagesOf(bobId).any((m) => m.id == reply.id), what: 'ответ');
    expect(at(alice, bobId, reply.id).story, '📷 Фото из истории');

    await aliceLive.close();
    await bobLive.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('истории: текст и фото, просмотры, удаление; день рождения', () async {
    final (alice, aliceLive, bob, bobLive) = await friends();
    final bobId = bobLive.keys!.pub, aliceId = aliceLive.keys!.pub;
    await until(() => alice.contact(bobId)?.request == false, what: 'дружба');

    final st = await alice.postStory(kind: 't', text: 'Всем привет!', bg: 2);
    expect(st, isNotNull);
    expect(alice.myStories, hasLength(1));
    // Кольцо появляется, когда история записана в базу.
    await until(() => bob.contact(aliceId)?.hasStory ?? false, what: 'история у Боба');
    expect(bob.contact(aliceId)!.storyUnseen, isTrue);
    expect(bob.storyContacts.map((c) => c.id), [aliceId]);
    final atBob = bob.storiesOf(aliceId).single;
    expect(atBob.text, 'Всем привет!');
    expect(atBob.bg, 2);

    await bob.viewStory(atBob);
    expect(bob.contact(aliceId)!.storyUnseen, isFalse);
    await until(() => alice.myStories.single.viewers.containsKey(bobId), what: 'просмотр');

    // Фото-история: куски уходят на ретранслятор, у друга — по запросу.
    final src = File('${tmp.path}/pic.jpg')..writeAsBytesSync(List.generate(30000, (i) => i % 251));
    final photo = await alice.postStory(
      kind: 'p',
      path: src.path,
      meta: Attachment(name: 'story.jpg', mime: 'image/jpeg', size: 30000, width: 10, height: 10),
    );
    expect(photo, isNotNull);
    await until(() => bob.storiesOf(aliceId).length == 2, what: 'фото у Боба');
    // Заранее скачанное фото — забываем, чтобы скачать заново: два запроса
    // сразу (заранее и по нажатию) получают одну загрузку, и оба дожидаются.
    final ph = bob.storiesOf(aliceId).last;
    await until(() => ph.att!.path != null, what: 'фото скачано заранее');
    File(ph.att!.path!).deleteSync();
    ph.att!.path = null;
    final both = await Future.wait([
      bob.storyFile(ph),
      bob.storyFile(ph),
    ]).timeout(const Duration(seconds: 30));
    expect(both[0], isNotNull);
    expect(both[1], both[0]);
    expect(File(both[0]!).readAsBytesSync(), src.readAsBytesSync());

    // Удалить у всех.
    await alice.deleteStory(alice.myStories.first);
    await until(() => bob.storiesOf(aliceId).length == 1, what: 'удалена у Боба');
    expect(bob.storiesOf(aliceId).single.kind, 'p');

    // Чужая «история» из группы или от незнакомца не принимается — проверено
    // в Live; здесь — что истёкшая не показывается.
    final old = Story(
      id: 'old',
      author: aliceId,
      kind: 't',
      text: 'вчера',
      time: DateTime.now().subtract(const Duration(hours: 25)),
    );
    bob.stories[aliceId]!.add(old);
    expect(bob.storiesOf(aliceId).any((s) => s.id == 'old'), isFalse);

    // День рождения: Алиса указала дату — Боб видит её и напоминание.
    final now = DateTime.now();
    final md = '${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    alice.setBirthday(md);
    await until(() => bob.contact(aliceId)?.birthday == md, what: 'дата у Боба');
    expect(bob.birthdayOf(bob.contact(aliceId)!), 0);
    await bob.checkBirthdays();
    final settings = await bobLive.store.getJson('settings');
    expect((settings!['bdn'] as Map).keys.single, '$aliceId:0');
    alice.setBirthday(null);
    await until(() => bob.contact(aliceId)?.birthday == null, what: 'дату убрали');

    await aliceLive.close();
    await bobLive.close();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('дни рождения: сегодня, завтра, 29 февраля', () {
    expect(AppState.birthdayIn('03-12', DateTime(2026, 3, 12)), 0);
    expect(AppState.birthdayIn('03-13', DateTime(2026, 3, 12)), 1);
    expect(AppState.birthdayIn('03-14', DateTime(2026, 3, 12)), isNull);
    expect(AppState.birthdayIn('01-01', DateTime(2026, 12, 31)), 1);
    expect(AppState.birthdayIn('02-29', DateTime(2026, 2, 28)), 0, reason: 'невисокосный год');
    expect(AppState.birthdayIn('02-29', DateTime(2028, 2, 28)), 1);
    expect(cleanBirthday('02-30'), isNull);
    expect(cleanBirthday('13-01'), isNull);
    expect(cleanBirthday('12-31'), '12-31');
  });
}
