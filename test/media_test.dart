import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/media.dart';
import 'package:veil/core/nostr.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Вложения: фото, файлы, голосовые, геопозиция и опросы между двумя «телефонами».
///
/// Три ретранслятора, как в жизни: обычный, с пределом 64 КБ на событие и
/// «только для своих» (отказывается от крупных событий незнакомцев).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late List<FakeRelay> relays;
  late Directory tmp;
  const urls = ['ws://open.test', 'ws://small.test', 'ws://picky.test'];

  setUp(() async {
    relays = [
      FakeRelay()..noAuthorQueries = true,
      FakeRelay()..maxEventBytes = 65536,
      FakeRelay()..noAuthorQueries = true,
    ];
    relays[2]
      ..rejectBig = 'blocked: Policy violated and pubkey is not in our web of trust.'
      ..rejectBigOver = 4000;
    for (final r in relays) {
      await r.start();
    }
    tmp = await Directory.systemTemp.createTemp('veil_media');
  });

  tearDown(() async {
    for (final r in relays) {
      await r.stop();
    }
    await tmp.delete(recursive: true);
  });

  WebSocketChannel connect(Uri u, [Set<String>? only, bool tight = false]) {
    final i = urls.indexOf('ws://${u.host}');
    // «Мобильная сеть»: до остальных ретрансляторов не дотянуться.
    if (only != null && !only.contains('ws://${u.host}')) {
      return WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:1'));
    }
    // «Урезанная» мобильная сеть: соединения замерзают после ~14 КБ.
    return WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${relays[max(i, 0)].port}${tight ? '/m' : ''}'),
    );
  }

  Future<(AppState, Live)> phone(
    String name, {
    MemorySecrets? secrets,
    Set<String>? only,
    bool tight = false,
  }) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: secrets ?? MemorySecrets(),
      dbFactory: databaseFactoryFfi,
      dbPath: '${tmp.path}/$name.db',
      connector: (u) => connect(u, only, tight),
      mediaDir: '${tmp.path}/$name-media',
      tempDir: '${tmp.path}/cache',
    );
    if (!app.onboarded) {
      await app.createProfile(name: name, emoji: '🦊', colorIndex: 2);
    }
    await live.setRelays(urls);
    return (app, live);
  }

  Future<void> until(bool Function() cond, {String? what, int seconds = 15}) async {
    for (var i = 0; i < seconds * 10; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  /// Двое друзей, оба на связи со всеми тремя ретрансляторами.
  Future<(AppState, Live, AppState, Live, String, String)> friends({
    MemorySecrets? aliceSecrets,
    bool bobTight = false,
  }) async {
    final (alice, aliceLive) = await phone('Алиса', secrets: aliceSecrets);
    final (bob, bobLive) = await phone('Боб', tight: bobTight);
    await until(
      () => aliceLive.pool!.onlineCount == 3 && bobLive.pool!.onlineCount == 3,
      what: 'связь',
    );
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceLive.keys!.pub) != null, what: 'hello');
    bob.acceptRequest(aliceLive.keys!.pub);
    return (alice, aliceLive, bob, bobLive, c.id, aliceLive.keys!.pub);
  }

  Future<String> randomFile(String name, int size) async {
    final r = Random(size);
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(Uint8List.fromList(List.generate(size, (_) => r.nextInt(256))));
    return f.path;
  }

  test('кусок шифруется, подписывается и не открывается чужим ключом или номером', () {
    final key = randomBytes(32);
    final signer = Keys.generate();
    final data = randomBytes(1000);
    final e = MediaCodec.seal(signer, key, 3, data);
    expect(e.verify(), isTrue);
    expect(e.pubkey, signer.pub);
    expect(MediaCodec.indexOf(e), 3);
    expect(MediaCodec.open(key, 3, e.content), data);
    expect(MediaCodec.open(key, 4, e.content), isNull, reason: 'чужой номер');
    expect(MediaCodec.open(randomBytes(32), 3, e.content), isNull, reason: 'чужой ключ');
    // Полный кусок помещается в событие до 64 КБ.
    final big = MediaCodec.seal(signer, key, 0, randomBytes(MediaCodec.chunkSize));
    expect(big.content.length + 600, lessThan(65536));
  });

  test('файлы первой версии (AES-GCM) по-прежнему открываются', () {
    final key = randomBytes(32);
    final data = randomBytes(5000);
    final old = MediaCodec.seal(Keys.generate(), key, 2, data, scheme: 0);
    expect(MediaCodec.open(key, 2, old.content, scheme: 0), data);
    expect(MediaCodec.open(key, 2, old.content), isNull, reason: 'схемы не путаются');
  });

  test('перечитали чат во время отправки — у отправителя не висит «загрузка»', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    final src = await randomFile('big.jpg', 600 * 1024);
    final first = await alice.sendFile(
      bobId,
      kind: MsgKind.photo,
      path: src,
      name: 'big.jpg',
      mime: 'image/jpeg',
      size: 600 * 1024,
    );
    // Как при возврате из галереи: список сообщений заменяется копией из базы.
    await aliceLive.reload();
    final shown = alice.messagesOf(bobId).single;
    expect(identical(shown, first), isFalse);
    await until(() => shown.att!.uploaded, what: 'экземпляр на экране узнал об отправке');
    await until(() => alice.transfers.isEmpty, what: 'кольцо загрузки убрано');
    await until(
      () => bob.messagesOf(aliceId).isNotEmpty && bob.messagesOf(aliceId).single.att!.local,
      what: 'дошло',
    );
    await aliceLive.close();
    await bobLive.close();
  });

  test('молчащий ретранслятор не тормозит отправку', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    relays[0].frozen = true; // соединение есть, но ответов нет
    final src = await randomFile('p2.jpg', 400 * 1024);
    final sw = Stopwatch()..start();
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.photo,
      path: src,
      name: 'p2.jpg',
      mime: 'image/jpeg',
      size: 400 * 1024,
    );
    await until(() => m.att!.uploaded, what: 'залито без молчуна', seconds: 10);
    expect(sw.elapsed.inSeconds, lessThan(6), reason: 'не ждём ответа от всех');
    expect(m.att!.relays, isNot(contains('ws://open.test')));
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение');
    relays[0].frozen = false;
    await aliceLive.close();
    await bobLive.close();
  });

  test('фото: заливка кусками, автоскачивание у друга, байты совпадают', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    // Здесь второй тоже не берёт крупное — куски должны уйти в единственный подходящий.
    relays[1].maxEventBytes = 30000;
    final src = await randomFile('photo.jpg', 300 * 1024 + 123);
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.photo,
      path: src,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: File(src).lengthSync(),
      caption: 'закат 🌅',
      width: 1600,
      height: 1200,
      thumb: 'iVBORw0KGgo=',
    );
    // Файл скопирован в папку приложения, а оригинал вне кэша не тронут.
    expect(m.att!.path, startsWith('${tmp.path}/Алиса-media/'));
    expect(File(src).existsSync(), isTrue);
    await until(() => m.att!.uploaded, what: 'заливка');
    expect(m.att!.chunks, MediaCodec.chunkCount(300 * 1024 + 123));
    // Отказавшиеся запомнены и обойдены: куски лежат только там, где их приняли.
    expect(m.att!.relays, ['ws://open.test']);
    expect(aliceLive.journal.any((l) => l.contains('picky.test не берёт куски')), isTrue);
    expect(aliceLive.journal.any((l) => l.contains('small.test не берёт куски')), isTrue);
    // Отказ по куску файла не считается «поломкой» связи.
    expect(aliceLive.pool!.errorOf('ws://small.test'), isNull);

    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение');
    final got = bob.messagesOf(aliceId).single;
    expect(got.kind, MsgKind.photo);
    expect(got.text, 'закат 🌅');
    expect(got.att!.width, 1600);
    expect(got.att!.thumb, 'iVBORw0KGgo=');
    await until(() => got.att!.local, what: 'автоскачивание');
    expect(File(got.att!.path!).readAsBytesSync(), File(src).readAsBytesSync());
    expect(got.att!.path, startsWith('${tmp.path}/Боб-media/'));
    await until(() => bob.transfers.isEmpty, what: 'прогресс убран после окончания');
    await until(() => m.status == MsgStatus.delivered, what: 'доставлено');
    expect(got.preview, '📷 Фото · закат 🌅');

    // Ретранслятор видит только шифр: в кусках нет ни ключей друзей, ни данных.
    for (final r in relays) {
      for (final e in r.stored) {
        expect(e['pubkey'], isNot(aliceId));
        expect(e['pubkey'], isNot(bobLive.keys!.pub));
      }
    }
    await aliceLive.close();
    await bobLive.close();
  });

  test('от незнакомца фото само не качается — только после «принять»', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount == 3 && bobLive.pool!.onlineCount == 3);
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    final aliceId = aliceLive.keys!.pub;
    final src = await randomFile('p.jpg', 60 * 1024);
    await alice.sendFile(
      c.id,
      kind: MsgKind.photo,
      path: src,
      name: 'p.jpg',
      mime: 'image/jpeg',
      size: 60 * 1024,
    );
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'фото от заявки');
    final got = bob.messagesOf(aliceId).single;
    expect(bob.contact(aliceId)!.request, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(got.att!.local, isFalse, reason: 'от незнакомцев — только по нажатию');
    bob.acceptRequest(aliceId);
    await until(() => got.att!.local, what: 'после «принять» скачалось само');
    await aliceLive.close();
    await bobLive.close();
  });

  test('загрузка, начатая без связи, дожидается сети и завершается', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    final src = await randomFile('doc.pdf', 150 * 1024);
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.file,
      path: src,
      name: 'doc.pdf',
      mime: 'application/pdf',
      size: 150 * 1024,
    );
    await until(() => m.att!.uploaded, what: 'залито');
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение');
    final got = bob.messagesOf(aliceId).single;
    // Связь пропала (как сразу после открытия приложения), а загрузка уже началась.
    final ports = [for (final r in relays) r.port];
    for (final r in relays) {
      await r.stop();
    }
    await until(() => bobLive.pool!.onlineCount == 0, what: 'обрыв');
    bob.download(aliceId, got);
    await Future<void>.delayed(const Duration(seconds: 5));
    expect(bob.failedTransfers, isEmpty, reason: 'не сдаёмся, пока нет сети');
    for (var i = 0; i < relays.length; i++) {
      await relays[i].startOn(ports[i]);
    }
    await until(() => got.att!.local, what: 'скачалось после появления сети', seconds: 30);
    expect(File(got.att!.path!).readAsBytesSync(), File(src).readAsBytesSync());
    await aliceLive.close();
    await bobLive.close();
  });

  test('молчащий ретранслятор с кусками не держит загрузку', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    // Куски лежат у всех трёх (третий в этом тесте берёт крупное).
    relays[2].rejectBig = null;
    final src = await randomFile('doc2.pdf', 200 * 1024);
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.file,
      path: src,
      name: 'doc2.pdf',
      mime: 'application/pdf',
      size: 200 * 1024,
    );
    await until(() => m.att!.uploaded, what: 'залито');
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение');
    final got = bob.messagesOf(aliceId).single;
    // Первый из подсказанных ретрансляторов «завис»: соединение есть, ответов нет.
    final first = got.att!.relays.first;
    relays[urls.indexOf(first)].frozen = true;
    final sw = Stopwatch()..start();
    bob.download(aliceId, got);
    await until(() => got.att!.local, what: 'скачалось с другого', seconds: 15);
    expect(sw.elapsed.inSeconds, lessThan(8), reason: 'не ждём молчуна до таймаута');
    relays[urls.indexOf(first)].frozen = false;
    await aliceLive.close();
    await bobLive.close();
  });

  /// Алиса «на Wi-Fi» видит все три ретранслятора, Боб «в мобильной сети» —
  /// только третий. Все три принимают куски.
  Future<(AppState, Live, AppState, Live, String, String)> splitNetwork() async {
    relays[2].rejectBig = null;
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб', only: {'ws://picky.test'});
    await until(
      () => aliceLive.pool!.onlineCount == 3 && bobLive.pool!.onlineCount == 1,
      what: 'связь',
    );
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceLive.keys!.pub) != null, what: 'hello');
    bob.acceptRequest(aliceLive.keys!.pub);
    return (alice, aliceLive, bob, bobLive, c.id, aliceLive.keys!.pub);
  }

  test('файлы кладутся туда, где получатель на связи (Wi-Fi → мобильная сеть)', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await splitNetwork();
    // Боб пишет первым — вместе с сообщением Алиса узнаёт, где он на связи.
    bob.send(aliceId, 'я с мобильного');
    await until(() => alice.contact(bobId)!.reach.isNotEmpty, what: 'Алиса узнала сеть Боба');
    expect(alice.contact(bobId)!.reach, ['ws://picky.test']);

    final src = await randomFile('photo_m.jpg', 200 * 1024);
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.photo,
      path: src,
      name: 'photo_m.jpg',
      mime: 'image/jpeg',
      size: 200 * 1024,
    );
    await until(() => m.att!.uploaded, what: 'залито');
    expect(m.att!.relays, contains('ws://picky.test'));
    await until(
      () => bob.messagesOf(aliceId).any((x) => x.att?.local ?? false),
      what: 'Боб скачал',
      seconds: 20,
    );
    await aliceLive.close();
    await bobLive.close();
  });

  test('не нашёл кусков — попросил отправителя положить копию, и скачал', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await splitNetwork();
    // Алиса ничего не знает о сети Боба — куски уйдут в самые быстрые для неё.
    expect(alice.contact(bobId)!.reach, isEmpty);
    final src = await randomFile('voice_m.m4a', 120 * 1024);
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.voice,
      path: src,
      name: 'voice.m4a',
      mime: 'audio/mp4',
      size: 120 * 1024,
      duration: 5,
    );
    await until(() => m.att!.uploaded, what: 'залито');
    expect(m.att!.relays, isNot(contains('ws://picky.test')), reason: 'Бобу оттуда не достать');
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение дошло');
    final got = bob.messagesOf(aliceId).single;
    await until(() => got.att!.local, what: 'скачано через копию', seconds: 45);
    expect(File(got.att!.path!).readAsBytesSync(), File(src).readAsBytesSync());
    expect(bobLive.journal.any((l) => l.contains('прошу')), isTrue);
    expect(aliceLive.journal.any((l) => l.contains('копия готова: ws://picky.test')), isTrue);
    await aliceLive.close();
    await bobLive.close();
  });

  test('мобильная сеть режет соединения: файл приходит мелкими кусками', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends(bobTight: true);
    // Один из ретрансляторов не смотрит на номер куска в фильтре (как snort).
    relays[0].ignoreTagFilters = true;
    // Свежие соединения Боба замерзают после ~14 КБ — крупный кусок (~62 КБ) не пройдёт.
    final src = await randomFile('photo.jpg', 120 * 1024);
    final sent = await alice.sendFile(
      bobId,
      kind: MsgKind.photo,
      path: src,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: File(src).lengthSync(),
    );
    await until(() => sent.att!.uploaded, what: 'заливка');
    expect(sent.att!.small, isFalse, reason: 'про сеть Боба ещё ничего не известно');
    await until(
      () => bob.messagesOf(aliceId).any((m) => m.att?.local ?? false),
      what: 'фото у Боба (через мелкую копию)',
      seconds: 60,
    );
    final got = bob.messagesOf(aliceId).firstWhere((m) => m.att != null);
    expect(got.att!.small, isTrue);
    expect(await File(got.att!.path!).readAsBytes(), await File(src).readAsBytes());
    expect(relays.fold<int>(0, (a, r) => a + r.frozenByLimit), greaterThan(0));
    expect(bobLive.media.tight, isTrue);
    expect(bobLive.journal.join('\n'), contains('мелкая нарезка'));
    expect(aliceLive.journal.join('\n'), contains('мелкая копия'));

    // Боб пишет в ответ — Алиса узнаёт, что его сеть «урезана», и следующий
    // файл сразу режет мелко (без лишнего круга).
    bob.send(aliceId, 'спасибо');
    await until(() => alice.contact(bobId)?.tight ?? false, what: 'флаг сети Боба');
    final src2 = await randomFile('b.jpg', 60 * 1024 + 7);
    final second = await alice.sendFile(
      bobId,
      kind: MsgKind.photo,
      path: src2,
      name: 'b.jpg',
      mime: 'image/jpeg',
      size: File(src2).lengthSync(),
    );
    await until(() => second.att!.uploaded, what: 'заливка второго');
    expect(second.att!.small, isTrue);
    expect(second.att!.chunks, MediaCodec.chunkCount(60 * 1024 + 7, MediaCodec.smallChunk));
    await until(
      () => bob.messagesOf(aliceId).where((m) => m.att?.local ?? false).length == 2,
      what: 'второй файл у Боба',
      seconds: 40,
    );
    final got2 = bob.messagesOf(aliceId).lastWhere((m) => m.att != null);
    expect(await File(got2.att!.path!).readAsBytes(), await File(src2).readAsBytes());
    // А текст по-прежнему ходит.
    alice.send(bobId, 'дошло?');
    // (общее соединение Боба тоже могло замёрзнуть — оно переподключится)
    await until(
      () => bob.messagesOf(aliceId).any((m) => m.text == 'дошло?'),
      what: 'текст',
      seconds: 45,
    );
    await aliceLive.close();
    await bobLive.close();
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('документ скачивается по нажатию; удаление друга стирает файлы', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    final src = await randomFile('отчёт.pdf', 100 * 1024);
    await alice.sendFile(
      bobId,
      kind: MsgKind.file,
      path: src,
      name: 'отчёт.pdf',
      mime: 'application/pdf',
      size: 100 * 1024,
    );
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение');
    final got = bob.messagesOf(aliceId).single;
    expect(got.att!.name, 'отчёт.pdf');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(got.att!.local, isFalse, reason: 'документы сами не качаются');

    bob.download(aliceId, got);
    await until(() => got.att!.local, what: 'скачивание');
    expect(got.att!.path!.endsWith('.pdf'), isTrue);
    expect(File(got.att!.path!).readAsBytesSync(), File(src).readAsBytesSync());

    // После перезапуска путь к файлу помнится.
    final dir = Directory('${tmp.path}/Боб-media/$aliceId');
    expect(dir.existsSync(), isTrue);
    await bob.deleteContact(aliceId);
    expect(dir.existsSync(), isFalse, reason: 'файлы удалены вместе с другом');
    await aliceLive.close();
    await bobLive.close();
  });

  test('незалитый файл продолжает отправку после перезапуска', () async {
    final secrets = MemorySecrets();
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends(aliceSecrets: secrets);
    // Связи нет — файл не уходит.
    for (final r in relays) {
      r.frozen = true;
    }
    final src = await randomFile('clip.mp4', 120 * 1024);
    final m = await alice.sendFile(
      bobId,
      kind: MsgKind.video,
      path: src,
      name: 'clip.mp4',
      mime: 'video/mp4',
      size: 120 * 1024,
      duration: 7,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(m.att!.uploaded, isFalse);
    await aliceLive.close();
    for (final r in relays) {
      r.frozen = false;
    }

    final (alice2, alice2Live) = await phone('Алиса', secrets: secrets);
    final m2 = alice2.messagesOf(bobId).single;
    expect(m2.att!.local, isTrue, reason: 'файл на месте после перезапуска');
    await until(() => m2.att!.uploaded, what: 'дозаливка');
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'сообщение');
    final got = bob.messagesOf(aliceId).single;
    await until(() => got.att!.local, what: 'видео скачалось само');
    expect(got.att!.duration, 7);
    expect(File(got.att!.path!).readAsBytesSync(), File(src).readAsBytesSync());
    await alice2Live.close();
    await bobLive.close();
  });

  test('голосовое, геопозиция и опрос с голосами', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    // Запись голоса лежит во временной папке — после отправки она не нужна.
    await Directory('${tmp.path}/cache').create();
    final voice = (await File(
      await randomFile('v.m4a', 20 * 1024),
    ).rename('${tmp.path}/cache/v.m4a')).path;
    await alice.sendFile(
      bobId,
      kind: MsgKind.voice,
      path: voice,
      name: 'voice.m4a',
      mime: 'audio/mp4',
      size: 20 * 1024,
      duration: 9,
      wave: [1, 5, 30, 12],
    );
    alice.sendLocation(bobId, const GeoPoint(55.7512, 37.6184, accuracy: 12));
    final poll = alice.sendPoll(
      bobId,
      Poll(question: 'Куда идём?', options: ['Кино', 'Парк', 'Кафе']),
    );

    expect(File(voice).existsSync(), isFalse, reason: 'временная копия удалена');
    await until(() => bob.messagesOf(aliceId).length == 3, what: 'три сообщения');
    final msgs = bob.messagesOf(aliceId);
    final v = msgs.firstWhere((m) => m.kind == MsgKind.voice);
    expect(v.seconds, 9);
    expect(v.att!.wave, [1, 5, 30, 12]);
    await until(() => v.att!.local, what: 'голосовое скачалось');

    final g = msgs.firstWhere((m) => m.kind == MsgKind.geo);
    expect(g.geo!.lat, closeTo(55.7512, 1e-9));
    expect(g.geo!.lng, closeTo(37.6184, 1e-9));
    expect(g.preview, '📍 Геопозиция');

    final p = msgs.firstWhere((m) => m.kind == MsgKind.poll);
    expect(p.poll!.question, 'Куда идём?');
    expect(p.poll!.options, ['Кино', 'Парк', 'Кафе']);

    // Голоса видят оба; голос можно изменить.
    bob.vote(aliceId, p, [1]);
    await until(() => poll.poll!.of(bobLive.keys!.pub).join() == '1', what: 'голос Боба');
    alice.vote(bobId, poll, [0]);
    await until(() => p.poll!.of(aliceLive.keys!.pub).join() == '0', what: 'голос Алисы');
    bob.vote(aliceId, p, [2]);
    await until(() => poll.poll!.of(bobLive.keys!.pub).join() == '2', what: 'передумал');
    expect(poll.poll!.voters, 2);
    expect(poll.poll!.count(2), 1);
    // Одиночный выбор: больше одного варианта не засчитывается.
    bob.vote(aliceId, p, [0, 1]);
    await until(() => poll.poll!.of(bobLive.keys!.pub).length == 1, what: 'один вариант');
    await aliceLive.close();

    // Голоса сохраняются в базе.
    await bobLive.close();
    final (bob2, bob2Live) = await phone('Боб', secrets: MemorySecrets());
    expect(bob2.messagesOf(aliceId), isEmpty, reason: 'другой телефон — другая база');
    await bob2Live.close();
  });

  test('опрос сохраняет голоса после перезапуска', () async {
    final secrets = MemorySecrets();
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends(aliceSecrets: secrets);
    final poll = alice.sendPoll(
      bobId,
      Poll(question: 'Пицца?', options: ['Да', 'Нет'], multi: true),
    );
    await until(() => bob.messagesOf(aliceId).isNotEmpty, what: 'опрос');
    bob.vote(aliceId, bob.messagesOf(aliceId).single, [0, 1]);
    await until(() => poll.poll!.of(bobLive.keys!.pub).length == 2, what: 'голос');
    await aliceLive.close();
    final (alice2, alice2Live) = await phone('Алиса', secrets: secrets);
    final p = alice2.messagesOf(bobId).single.poll!;
    expect(p.multi, isTrue);
    expect(p.of(bobLive.keys!.pub), [0, 1]);
    await alice2Live.close();
    await bobLive.close();
  });
}
