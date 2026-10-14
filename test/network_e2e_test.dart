@Tags(['network'])
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:veil/core/protocol.dart';
import 'package:veil/core/store.dart';
import 'package:veil/models/models.dart';
import 'package:veil/state/app_state.dart';
import 'package:veil/state/live.dart';

/// Два «телефона» переписываются через НАСТОЯЩИЕ публичные ретрансляторы.
/// Запускается в GitHub Actions: VEIL_NETWORK_TEST=1 flutter test test/network_e2e_test.dart
void main() {
  final enabled = Platform.environment['VEIL_NETWORK_TEST'] == '1';
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('veil-net'));
  tearDown(() async => tmp.delete(recursive: true));

  Future<(AppState, Live)> phone(String name, MemorySecrets secrets) async {
    final app = AppState();
    final live = await Live.boot(
      app,
      secrets: secrets,
      dbFactory: databaseFactoryFfi,
      dbPath: '${tmp.path}/$name.db',
      mediaDir: '${tmp.path}/$name-media',
    );
    if (!app.onboarded) await app.createProfile(name: name, emoji: '🦊', colorIndex: 1);
    return (app, live);
  }

  final sw = Stopwatch()..start();
  Future<void> until(bool Function() cond, String what, {int seconds = 30}) async {
    final start = sw.elapsedMilliseconds;
    for (var i = 0; i < seconds * 5; i++) {
      if (cond()) {
        // ignore: avoid_print
        print('✅ $what — ${((sw.elapsedMilliseconds - start) / 1000).toStringAsFixed(1)} с');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    // ignore: avoid_print
    print('❌ $what — не дождались за $seconds с');
    fail('не дождались: $what');
  }

  test(
    'полный сценарий через публичные ретрансляторы',
    () async {
      final aSecrets = MemorySecrets(), bSecrets = MemorySecrets();
      final (alice, aliceLive) = await phone('Алиса', aSecrets);
      var (bob, bobLive) = await phone('Боб', bSecrets);
      await until(
        () => aliceLive.pool!.onlineCount >= 3 && bobLive.pool!.onlineCount >= 3,
        'подключение (Алиса ${aliceLive.pool!.onlineCount}, Боб ${bobLive.pool!.onlineCount})',
      );

      // Новый аккаунт сразу добавляет друга и пишет — как в отчёте пользователя.
      final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
      alice.send(c.id, 'привет из CI');
      final sent = alice.messagesOf(c.id).last;
      final aPub = aliceLive.keys!.pub;

      await until(() => bob.contact(aPub) != null, 'друг появился у получателя');
      await until(
        () => bob.messagesOf(aPub).any((m) => m.text == 'привет из CI'),
        'сообщение дошло в реальном времени',
      );
      await until(() => sent.status.index >= MsgStatus.delivered.index, '✓✓ доставлено');

      bob.openChat = aPub;
      bob.markRead(aPub);
      await until(() => sent.status == MsgStatus.read, 'прочитано');

      bob.send(aPub, 'ответ из CI');
      await until(
        () => alice.messagesOf(c.id).any((m) => m.text == 'ответ из CI'),
        'ответ дошёл обратно',
      );

      // Получатель «выключен» — сообщение ждёт на ретрансляторах.
      await bobLive.close();
      alice.send(c.id, 'пока тебя не было');
      final offline = alice.messagesOf(c.id).last;
      await until(() => offline.status.index >= MsgStatus.sent.index, 'принято ретранслятором');
      await Future<void>.delayed(const Duration(seconds: 3));
      (bob, bobLive) = await phone('Боб', bSecrets);
      await until(
        () => bob.messagesOf(aPub).any((m) => m.text == 'пока тебя не было'),
        'офлайн-доставка после включения',
        seconds: 45,
      );
      expect(bob.messagesOf(aPub).where((m) => m.text == 'привет из CI').length, 1);

      // ignore: avoid_print
      print('журнал Алисы:\n${aliceLive.journal.join('\n')}');
      await aliceLive.close();
      await bobLive.close();
    },
    skip: enabled ? false : 'нужен интернет (VEIL_NETWORK_TEST=1)',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'файлы через публичные ретрансляторы: фото 400 КБ и видео 3 МБ',
    () async {
      final (alice, aliceLive) = await phone('Алиса', MemorySecrets());
      final (bob, bobLive) = await phone('Боб', MemorySecrets());
      await until(
        () => aliceLive.pool!.onlineCount >= 3 && bobLive.pool!.onlineCount >= 3,
        'подключение',
      );
      final c = await alice.addContact(Invite.parse(bob.inviteLink)!);
      final aPub = aliceLive.keys!.pub;
      await until(() => bob.contact(aPub) != null, 'друг появился');
      try {
        Future<String> file(String name, int size) async {
          final r = Random();
          final f = File('${tmp.path}/$name');
          await f.writeAsBytes(Uint8List.fromList(List.generate(size, (_) => r.nextInt(256))));
          return f.path;
        }

        for (final (kind, name, size, secs) in [
          (MsgKind.photo, 'photo.jpg', 400 * 1024, 60),
          (MsgKind.video, 'clip.mp4', 3 * 1024 * 1024, 240),
        ]) {
          final src = await file(name, size);
          final m = await alice.sendFile(
            c.id,
            kind: kind,
            path: src,
            name: name,
            mime: 'application/octet-stream',
            size: size,
          );
          await until(() => m.att!.uploaded, '$name: залито', seconds: secs);
          await until(
            () => bob.messagesOf(aPub).any((x) => x.id == m.id),
            '$name: сообщение пришло',
          );
          final got = bob.messagesOf(aPub).firstWhere((x) => x.id == m.id);
          await until(() => got.att!.local, '$name: скачано у друга', seconds: secs);
          expect(File(got.att!.path!).readAsBytesSync(), File(src).readAsBytesSync());
        }
      } finally {
        // ignore: avoid_print
        print('журнал Алисы (файлы):\n${aliceLive.journal.join('\n')}');
        // ignore: avoid_print
        print('журнал Боба (файлы):\n${bobLive.journal.join('\n')}');
        await aliceLive.close();
        await bobLive.close();
      }
    },
    skip: enabled ? false : 'нужен интернет (VEIL_NETWORK_TEST=1)',
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
