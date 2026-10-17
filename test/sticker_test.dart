import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/models/models.dart';
import 'package:veil/screens/sticker_maker.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Стикеры и GIF между двумя «телефонами».
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

  WebSocketChannel connect(Uri u, [Set<String>? only]) {
    final i = urls.indexOf('ws://${u.host}');
    // «Мобильная сеть»: до остальных ретрансляторов не дотянуться.
    if (only != null && !only.contains('ws://${u.host}')) {
      return WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:1'));
    }
    return WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relays[max(i, 0)].port}'));
  }

  Future<(AppState, Live)> phone(String name, {MemorySecrets? secrets, Set<String>? only}) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: secrets ?? MemorySecrets(),
      dbFactory: databaseFactoryFfi,
      dbPath: '${tmp.path}/$name.db',
      connector: (u) => connect(u, only),
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
  }) async {
    final (alice, aliceLive) = await phone('Алиса', secrets: aliceSecrets);
    final (bob, bobLive) = await phone('Боб');
    await until(
      () => aliceLive.pool!.onlineCount == 3 && bobLive.pool!.onlineCount == 3,
      what: 'связь',
    );
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    await until(() => bob.contact(aliceLive.keys!.pub) != null, what: 'hello');
    bob.acceptRequest(aliceLive.keys!.pub);
    return (alice, aliceLive, bob, bobLive, c.id, aliceLive.keys!.pub);
  }

  test('стикер из набора: по сети — только код', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    final m = alice.sendSticker(bobId, 'love');
    await until(() => bob.messagesOf(aliceId).any((x) => x.id == m.id), what: 'стикер');
    final got = bob.messagesOf(aliceId).firstWhere((x) => x.id == m.id);
    expect(got.kind, MsgKind.sticker);
    expect(got.sticker, 'love');
    expect(got.att, isNull);
    expect(got.preview, '✨ Стикер');
    await aliceLive.close();
    await bobLive.close();
  });

  test('свой стикер из фото и GIF доходят и сами скачиваются', () async {
    final (alice, aliceLive, bob, bobLive, bobId, aliceId) = await friends();
    // Картинка 300×200 → вырезаем круг → PNG 512×512 с прозрачными углами.
    final rec = ui.PictureRecorder();
    Canvas(rec).drawRect(const Rect.fromLTWH(0, 0, 300, 200), Paint()..color = Colors.orange);
    final photo = await rec.endRecording().toImage(300, 200);
    final png = await StickerMaker.render(
      photo,
      Path()..addOval(const Rect.fromLTWH(50, 20, 160, 160)),
    );
    expect(png, isNotNull);
    final decoded = await (await ui.instantiateImageCodec(Uint8List.fromList(png!))).getNextFrame();
    expect((decoded.image.width, decoded.image.height), (512, 512));
    final corner = await decoded.image.toByteData();
    expect(corner!.getUint8(3), 0, reason: 'угол прозрачный');
    final file = File('${tmp.path}/st.png')..writeAsBytesSync(png);
    final saved = await alice.addToCollection(file.path, gif: false);
    expect(alice.myStickers, [saved]);
    final st = await alice.sendMySticker(bobId, saved!);
    await until(
      () => bob.messagesOf(aliceId).any((x) => x.id == st.id && (x.att?.local ?? false)),
      what: 'свой стикер скачан',
      seconds: 30,
    );
    expect(bob.messagesOf(aliceId).firstWhere((x) => x.id == st.id).kind, MsgKind.sticker);

    // GIF 1×1 — как фото, но с типом image/gif (без пересжатия).
    final gifBytes = base64.decode('R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==');
    final gifFile = File('${tmp.path}/a.gif')..writeAsBytesSync(gifBytes);
    final g = await alice.addToCollection(gifFile.path, gif: true);
    final gm = await alice.sendGif(bobId, g!);
    await until(
      () => bob.messagesOf(aliceId).any((x) => x.id == gm.id && (x.att?.local ?? false)),
      what: 'GIF скачан',
      seconds: 30,
    );
    final atBob = bob.messagesOf(aliceId).firstWhere((x) => x.id == gm.id);
    expect(atBob.kind, MsgKind.photo);
    expect(atBob.att!.mime, 'image/gif');
    expect(File(atBob.att!.path!).readAsBytesSync(), gifBytes, reason: 'байт в байт');
    // Из коллекции можно убрать.
    alice.removeFromCollection(saved);
    expect(alice.myStickers, isEmpty);
    expect(File(saved).existsSync(), isFalse);
    await aliceLive.close();
    await bobLive.close();
  });
}
