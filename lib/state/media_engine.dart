import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/crypto_worker.dart';
import '../core/media.dart';
import '../core/nostr.dart';
import '../models/models.dart';
import 'live.dart';

/// Отправка и получение файлов (фото, видео, голосовые, документы).
///
/// Файл лежит в папке приложения: `media/<чат>/<id сообщения>.<расширение>`.
/// В сеть он уходит зашифрованными кусками (см. [MediaCodec]); само сообщение
/// с ключом отправляется обычным конвертом только после того, как все куски
/// приняты ретрансляторами.
class MediaEngine {
  MediaEngine(this.live, this._root, {Future<Directory> Function()? temp})
    : _temp = temp ?? getTemporaryDirectory;

  final Live live;
  final Future<String> Function() _root;
  final Future<Directory> Function() _temp;
  String? _rootPath;

  /// Сколько ретрансляторов должно принять каждый кусок (при возможности).
  static const replicas = 2;

  /// Сколько кусков отправляется одновременно.
  static const window = 3;

  /// Предел размера файла.
  static const maxBytes = 20 * 1024 * 1024;

  final Map<String, Future<bool>> _jobs = {};
  Future<void> _downloads = Future.value();

  /// Ретрансляторы, которые отказались принять крупное событие (до перезапуска).
  final Set<String> _noBig = {};

  /// Попросили «помедленнее» — не трогаем до этого времени.
  final Map<String, DateTime> _cooldown = {};

  /// Успехи/отказы за сеанс — для выбора, куда класть куски.
  final Map<String, int> _score = {};

  bool busy(String msgId) => _jobs.containsKey(msgId);

  Future<String> root() async => _rootPath ??= await _root();

  Future<String> pathFor(String chat, String msgId, String ext) async {
    final dir = Directory(p.join(await root(), chat));
    await dir.create(recursive: true);
    return p.join(dir.path, ext.isEmpty ? msgId : '$msgId.$ext');
  }

  /// Скопировать выбранный файл к себе (оригинал может исчезнуть).
  Future<String> import(String chat, String msgId, String src, String ext) async {
    final dst = await pathFor(chat, msgId, ext);
    if (p.equals(src, dst)) return dst;
    await File(src).copy(dst);
    return dst;
  }

  /// Удалить исходник, если это наша временная копия в кэше приложения
  /// (оригиналы пользователя вне кэша не трогаем никогда).
  Future<void> dropTemp(String path) async {
    try {
      final tmp = (await _temp()).path;
      if (p.isWithin(tmp, path) && File(path).existsSync()) await File(path).delete();
    } catch (_) {}
  }

  ValueNotifier<double> _progress(String msgId) =>
      live.app.transfers.putIfAbsent(msgId, () => ValueNotifier(0));

  void _done(String msgId, bool ok) {
    live.app.transfers.remove(msgId)?.dispose();
    ok ? live.app.failedTransfers.remove(msgId) : live.app.failedTransfers.add(msgId);
    live.app.notifyChanged();
  }

  // ───────────────────────── отправка ─────────────────────────

  /// Залить куски и отправить сообщение. Повторный вызов во время работы —
  /// тот же результат.
  Future<bool> send(String chat, Message m) =>
      _jobs[m.id] ??= _send(chat, m).whenComplete(() => _jobs.remove(m.id));

  Future<bool> _send(String chat, Message m) async {
    final att = m.att!;
    live.app.failedTransfers.remove(m.id);
    _progress(m.id).value = att.uploaded ? 1 : 0;
    live.app.notifyChanged();
    var ok = att.uploaded;
    try {
      if (!ok) ok = await _upload(chat, m, att);
    } catch (e) {
      live.log('ОШИБКА отправки файла (${Live.short(m.id)}): $e');
      ok = false;
    }
    if (ok) await live.queueMessage(chat, m);
    _done(m.id, ok);
    return ok;
  }

  List<String> _targets(Iterable<String> exclude) {
    final pl = live.pool;
    if (pl == null) return const [];
    final now = DateTime.now();
    final list = [
      for (final u in pl.onlineUrls)
        if (!_noBig.contains(u) && !exclude.contains(u) && !(_cooldown[u]?.isAfter(now) ?? false))
          u,
    ]..sort((a, b) => (_score[b] ?? 0).compareTo(_score[a] ?? 0));
    return list;
  }

  void _learn(String id, Set<String> asked, Set<String> ok) {
    final pl = live.pool!;
    for (final u in asked) {
      if (ok.contains(u)) {
        _score[u] = (_score[u] ?? 0) + 1;
        continue;
      }
      _score[u] = (_score[u] ?? 0) - 2;
      final why = (pl.rejected(id)[u] ?? '').toLowerCase();
      if (why.contains('rate') || why.contains('slow') || why.contains('spam')) {
        // Просят помедленнее — даём передохнуть.
        _cooldown[u] = DateTime.now().add(Duration(seconds: why.contains('spam') ? 60 : 20));
      } else if (why.isNotEmpty) {
        // Не берёт такие события вовсе (размер, «только для своих» и т. п.).
        if (_noBig.add(u)) live.log('${u.replaceFirst('wss://', '')} не берёт куски файлов: $why');
      }
    }
  }

  Future<bool> _upload(String chat, Message m, Attachment att) async {
    final path = att.path;
    if (path == null || !File(path).existsSync()) {
      live.log('файл для ${Live.short(m.id)} пропал с телефона');
      return false;
    }
    final w = CryptoWorker.shared;
    att.size = await File(path).length();
    att.sha = await w.hashFile(path);
    final signer = Keys.generate();
    final key = base64.encode(randomBytes(32));
    final n = MediaCodec.chunkCount(att.size);
    final holders = <String, int>{};
    final progress = _progress(m.id);
    var next = 0, done = 0;
    var failed = false;
    live.log(
      '↑ файл ${att.name} (${(att.size / 1024).round()} КБ, кусков: $n) для ${live.who(chat)}',
    );
    final sw = Stopwatch()..start();

    Future<void> lane() async {
      while (!failed && next < n) {
        final i = next++;
        final ev = await w.sealChunk(signer: signer, key: key, path: path, index: i);
        final ok = <String>{};
        final asked = <String>{};
        for (var round = 0; round < 6 && ok.length < replicas; round++) {
          if (live.closed) {
            failed = true;
            return;
          }
          final need = replicas - ok.length;
          final targets = _targets(asked).take(need + (round == 0 ? 0 : 1)).toList();
          if (targets.isEmpty) {
            if (ok.isNotEmpty) break; // больше некому — хватит и одного
            asked.clear(); // все отказали — пробуем всех заново после паузы
            await Future<void>.delayed(Duration(seconds: 2 + round * 2));
            continue;
          }
          asked.addAll(targets);
          final got = await live.pool!.publishTo(ev, targets);
          _learn(ev.id, targets.toSet(), got);
          ok.addAll(got);
        }
        if (ok.isEmpty) {
          failed = true;
          live.log('  кусок $i не приняли ретрансляторы');
          return;
        }
        for (final u in ok) {
          holders[u] = (holders[u] ?? 0) + 1;
        }
        done++;
        progress.value = done / n;
      }
    }

    await Future.wait([for (var i = 0; i < window; i++) lane()]);
    if (failed) return false;
    att
      ..key = key
      ..signer = signer.pub
      ..chunks = n
      ..chunkSize = MediaCodec.chunkSize
      ..relays = (holders.keys.toList()..sort((a, b) => holders[b]!.compareTo(holders[a]!)))
          .take(6)
          .toList();
    await live.saveMessage(chat, m);
    live.log(
      '  файл залит за ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} с: '
      '${att.relays.map((u) => u.replaceFirst('wss://', '')).join(', ')}',
    );
    return true;
  }

  // ───────────────────────── получение ─────────────────────────

  /// Скачать файл из сообщения. Загрузки идут по одной.
  Future<bool> download(String chat, Message m) {
    final running = _jobs[m.id];
    if (running != null) return running;
    final c = Completer<bool>();
    _jobs[m.id] = c.future;
    _progress(m.id);
    live.app.failedTransfers.remove(m.id);
    live.app.notifyChanged();
    _downloads = _downloads.then((_) async {
      var ok = false;
      try {
        ok = await _download(chat, m);
      } catch (e) {
        live.log('ОШИБКА получения файла (${Live.short(m.id)}): $e');
      }
      _jobs.remove(m.id);
      _done(m.id, ok);
      c.complete(ok);
    });
    return c.future;
  }

  Future<bool> _download(String chat, Message m) async {
    final att = m.att;
    final pl = live.pool;
    if (att == null || !att.uploaded || pl == null || live.closed) return false;
    if (att.local && File(att.path!).existsSync()) return true;
    final n = att.chunks;
    final cs = att.chunkSize > 0 ? att.chunkSize : MediaCodec.chunkSize;
    if (n > maxBytes ~/ cs + 2) return false;
    final dst = await pathFor(chat, m.id, att.ext);
    final part = File('$dst.part');
    final raf = await part.open(mode: FileMode.write);
    final have = <int>{};
    final pending = <int>{};
    var writes = Future<void>.value();
    final progress = _progress(m.id);
    final sw = Stopwatch()..start();
    live.log('↓ файл ${att.name} (${(att.size / 1024).round()} КБ, кусков: $n)');

    void onEvent(Event e) {
      final i = MediaCodec.indexOf(e);
      if (e.pubkey != att.signer || i == null || i < 0 || i >= n) return;
      if (have.contains(i) || !pending.add(i)) return;
      writes = writes.then((_) async {
        final bytes = await CryptoWorker.shared.openChunk(att.key, i, e.content);
        if (bytes != null && !have.contains(i)) {
          await raf.setPosition(i * cs);
          await raf.writeFrom(bytes);
          have.add(i);
          progress.value = have.length / n;
        }
        pending.remove(i);
      });
    }

    try {
      for (var round = 0; round < 2 && have.length < n; round++) {
        if (round > 0) await Future<void>.delayed(const Duration(seconds: 3));
        final online = pl.onlineUrls;
        final order = [
          ...att.relays.where(online.contains),
          ...online.where((u) => !att.relays.contains(u)),
        ];
        for (final url in order) {
          if (have.length >= n || live.closed) break;
          final missing = [
            for (var i = 0; i < n; i++)
              if (!have.contains(i)) i,
          ];
          // Если не хватает немногих — спрашиваем точечно по номерам.
          // По тегу p — так ретрансляторы отдают и обычные конверты (запросы
          // kind 1059 по автору некоторые не обслуживают).
          final filter = <String, dynamic>{
            'kinds': [MediaCodec.kind],
            '#p': [att.signer],
            'limit': missing.length,
            if (missing.length < n && missing.length <= 200) '#c': [for (final i in missing) '$i'],
          };
          await pl.fetch(
            url,
            filter,
            onEvent,
            idle: const Duration(seconds: 15),
            total: Duration(seconds: 30 + n),
          );
          await writes;
        }
      }
      await writes;
      if (have.length < n) {
        await raf.close();
        live.log('  файл не получен: ${have.length} из $n кусков');
        if (part.existsSync()) await part.delete();
        return false;
      }
      await raf.truncate(att.size);
      await raf.close();
      if (att.sha.isNotEmpty && await CryptoWorker.shared.hashFile(part.path) != att.sha) {
        live.log('  файл повреждён (не сходится хэш)');
        await part.delete();
        return false;
      }
      await part.rename(dst);
      att.path = dst;
      await live.saveMessage(chat, m);
      live.log('  файл получен за ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} с');
      return true;
    } finally {
      try {
        await raf.close();
      } catch (_) {}
    }
  }

  /// Что скачивать само: фото, голосовые и видео. Документы — по нажатию.
  static bool autoKind(Message m) =>
      m.kind == MsgKind.photo || m.kind == MsgKind.voice || m.kind == MsgKind.video;

  // ───────────────────────── удаление ─────────────────────────

  Future<void> deleteFile(Message m) async {
    final path = m.att?.path;
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  Future<void> deleteChat(String chat) async {
    try {
      final d = Directory(p.join(await root(), chat));
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> wipe() async {
    try {
      final d = Directory(await root());
      if (d.existsSync()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// Сколько места занимают файлы.
  Future<int> usage() async {
    var n = 0;
    try {
      final d = Directory(await root());
      if (!d.existsSync()) return 0;
      await for (final f in d.list(recursive: true)) {
        if (f is File) n += await f.length();
      }
    } catch (_) {}
    return n;
  }
}
