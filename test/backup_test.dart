import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/backup.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fake_relay.dart';

/// Резервная копия: сохранить на одном «телефоне», восстановить на другом.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late FakeRelay relay;
  late Directory tmp;

  setUp(() async {
    relay = FakeRelay();
    await relay.start();
    tmp = await Directory.systemTemp.createTemp('veil_backup');
  });

  tearDown(() async {
    await relay.stop();
    await tmp.delete(recursive: true);
  });

  Future<(AppState, Live)> phone(String name, {bool create = true}) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: MemorySecrets(),
      dbFactory: databaseFactoryFfi,
      dbPath: '${tmp.path}/$name.db',
      connector: (_) => WebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${relay.port}')),
      mediaDir: '${tmp.path}/$name-media',
      tempDir: '${tmp.path}/$name-cache',
    );
    if (create && !app.onboarded) {
      await app.createProfile(name: name, emoji: '🦊', colorIndex: 2);
    }
    return (app, live);
  }

  Future<void> until(bool Function() cond, {String? what, int seconds = 15}) async {
    for (var i = 0; i < seconds * 10; i++) {
      if (cond()) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('не дождались: ${what ?? ''}');
  }

  test('копия → новый телефон: ключ, друзья, переписка, фото — всё на месте', () async {
    final (alice, aliceLive) = await phone('Алиса');
    final (bob, bobLive) = await phone('Боб');
    await until(() => aliceLive.pool!.onlineCount > 0 && bobLive.pool!.onlineCount > 0);
    final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
    final aliceId = aliceLive.keys!.pub;
    await until(() => bob.contact(aliceId) != null, what: 'hello');
    bob.acceptRequest(aliceId);
    alice.send(c.id, 'первое сообщение');
    bob.send(aliceId, 'ответ Боба');
    final r = Random(1);
    final src = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(Uint8List.fromList(List.generate(90 * 1024, (_) => r.nextInt(256))));
    final photo = await alice.sendFile(
      c.id,
      kind: MsgKind.photo,
      path: src.path,
      name: 'photo.jpg',
      mime: 'image/jpeg',
      size: 90 * 1024,
      caption: 'на память',
    );
    await until(() => photo.status.index >= MsgStatus.delivered.index, what: 'фото доставлено');
    await until(() => alice.messagesOf(c.id).length == 3, what: 'три сообщения у Алисы');
    alice.setAccent(3);

    final file = '${tmp.path}/veil-backup.veil';
    await alice.exportBackup(file, 'пароль-123');
    expect(File(file).existsSync(), isTrue);
    // Внутри — шифр: ни текста, ни ключа открытым видом.
    final raw = String.fromCharCodes(File(file).readAsBytesSync());
    expect(raw.contains('первое сообщение'), isFalse);
    expect(raw.contains(aliceLive.keys!.priv), isFalse);
    await aliceLive.close();

    // Новый телефон: неверный пароль — понятная ошибка, ничего не сломано.
    final (alice2, alice2Live) = await phone('Алиса-новый', create: false);
    expect(alice2.onboarded, isFalse);
    await expectLater(
      alice2.restoreBackup(file, 'не тот'),
      throwsA(isA<BackupError>().having((e) => e.message, 'm', 'Неверный пароль')),
    );
    expect(alice2.onboarded, isFalse);

    await alice2.restoreBackup(file, 'пароль-123');
    expect(alice2.onboarded, isTrue);
    expect(alice2Live.keys!.pub, aliceId, reason: 'тот же ключ — друзья узнают');
    expect(alice2.profile!.name, 'Алиса');
    expect(alice2.accentIndex, 3, reason: 'настройки тоже');
    expect(alice2.contact(c.id)!.name, 'Боб');
    final msgs = alice2.messagesOf(c.id);
    expect(msgs.map((m) => m.text), ['первое сообщение', 'ответ Боба', 'на память']);
    final p2 = msgs.last;
    expect(p2.att!.path, startsWith('${tmp.path}/Алиса-новый-media/'));
    expect(File(p2.att!.path!).readAsBytesSync(), src.readAsBytesSync());

    // Переписка продолжается на новом телефоне.
    bob.send(aliceId, 'видишь меня на новом телефоне?');
    await until(
      () => alice2.messagesOf(c.id).any((m) => m.text == 'видишь меня на новом телефоне?'),
      what: 'новое сообщение после восстановления',
    );
    alice2.send(c.id, 'да!');
    await until(() => bob.messagesOf(aliceId).any((m) => m.text == 'да!'), what: 'ответ дошёл');
    await alice2Live.close();
    await bobLive.close();
  });

  test('повреждённый или обрезанный файл копии не принимается', () async {
    final dir = '${tmp.path}/out';
    final f = '${tmp.path}/b.veil';
    await Backup.write(f, 'pw', {'x': 'y' * 3000000}, {}, iterations: 2000);
    final ok = await Backup.read(f, 'pw', dir);
    expect((ok.manifest['x'] as String).length, 3000000);

    final bytes = File(f).readAsBytesSync();
    File(f).writeAsBytesSync(bytes.sublist(0, bytes.length - 100));
    await expectLater(Backup.read(f, 'pw', dir), throwsA(isA<BackupError>()));
    final bad = Uint8List.fromList(bytes)..[bytes.length ~/ 2] ^= 1;
    File(f).writeAsBytesSync(bad);
    await expectLater(Backup.read(f, 'pw', dir), throwsA(isA<BackupError>()));
    File(f).writeAsStringSync('просто текст');
    await expectLater(Backup.read(f, 'pw', dir), throwsA(isA<BackupError>()));
  });
}
