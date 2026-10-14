import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/crypto_worker.dart';
import '../core/media.dart';
import '../core/nostr.dart';
import '../core/relay_pool.dart';
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
  static const window = 4;

  /// Предел размера файла.
  static const maxBytes = 20 * 1024 * 1024;

  final Map<String, Future<bool>> _jobs = {};

  /// Ретрансляторы, которые отказались принять крупное событие (до перезапуска).
  final Set<String> _noBig = {};

  /// Попросили «помедленнее» — не трогаем до этого времени.
  final Map<String, DateTime> _cooldown = {};

  /// Неудачи подряд за сеанс (молчание, отказ) — такие ретрансляторы реже выбираем.
  final Map<String, int> _misses = {};

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

  /// Сохранить итог передачи. Пока файл шёл, список сообщений могли
  /// перечитать из базы (например, при возврате из галереи) — тогда на экране
  /// уже другой экземпляр этого же сообщения: переносим итог и в него, иначе
  /// у отправителя навсегда осталось бы «загружается».
  Future<bool> _publishResult(String chat, Message m) async {
    var saved = false;
    for (final cur in live.app.messagesOf(chat)) {
      if (cur.id != m.id) continue;
      if (!identical(cur, m)) cur.att?.copyFrom(m.att!);
      await live.saveMessage(chat, cur);
      saved = true;
    }
    // Не нашли — сообщение удалили, пока шёл файл; не воскрешаем его.
    live.app.notifyChanged();
    return saved;
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
    ]..sort((a, b) => _rank(pl, a).compareTo(_rank(pl, b)));
    return list;
  }

  /// Чем меньше — тем лучше: быстрые и надёжные ретрансляторы — первыми.
  double _rank(RelayPool pl, String url) =>
      (pl.latencyOf(url) ?? 700) * (1 + 2 * (_misses[url] ?? 0));

  /// Кто промолчал, пока никто не принял, — получает «минус» к выбору.
  void _learn(String id, Set<String> asked, Set<String> ok) {
    final pl = live.pool!;
    for (final u in asked) {
      if (ok.contains(u)) {
        _misses[u] = 0;
      } else if (ok.isEmpty && !pl.rejected(id).containsKey(u)) {
        _misses[u] = (_misses[u] ?? 0) + 1;
      }
    }
  }

  /// Наши куски, ответы на которые ещё интересны.
  final Set<String> _ours = {};

  /// Отказ приходит иногда уже после того, как кусок принял другой, — учитываем
  /// его сразу, чтобы не слать этому ретранслятору следующие куски впустую.
  void _onReject(String id, String url, String why) {
    if (!_ours.contains(id)) return;
    _misses[url] = (_misses[url] ?? 0) + 1;
    final w = why.toLowerCase();
    if (w.contains('rate') || w.contains('slow') || w.contains('spam')) {
      // Просят помедленнее — даём передохнуть.
      _cooldown[url] = DateTime.now().add(Duration(seconds: w.contains('spam') ? 60 : 20));
    } else if (w.isNotEmpty) {
      // Не берёт такие события вовсе (размер, «только для своих» и т. п.).
      if (_noBig.add(url)) {
        live.log('${url.replaceFirst('wss://', '')} не берёт куски файлов: $why');
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

    final sent = <String>[];

    Future<void> lane() async {
      while (!failed && next < n) {
        final i = next++;
        final ev = await w.sealChunk(signer: signer, key: key, path: path, index: i);
        _ours.add(ev.id);
        if (_ours.length > 5000) _ours.remove(_ours.first);
        live.pool?.onReject ??= _onReject;
        final asked = <String>{};
        var ok = <String>{};
        for (var round = 0; round < 8 && ok.isEmpty; round++) {
          if (live.closed) {
            failed = true;
            return;
          }
          // Кусок — сразу в два самых быстрых ретранслятора; дальше идём, как
          // только принял первый (второй догонит сам, его ответ тоже учтём).
          final targets = _targets(asked).take(replicas).toList();
          if (targets.isEmpty) {
            asked.clear(); // все отказали или молчат — пробуем снова после паузы
            await Future<void>.delayed(Duration(milliseconds: 800 + round * 700));
            continue;
          }
          asked.addAll(targets);
          ok = await live.pool!.publishTo(
            ev,
            targets,
            want: 1,
            timeout: const Duration(seconds: 8),
          );
          _learn(ev.id, targets.toSet(), ok);
        }
        if (ok.isEmpty) {
          failed = true;
          live.log('  кусок $i не приняли ретрансляторы');
          return;
        }
        sent.add(ev.id);
        done++;
        progress.value = done / n;
      }
    }

    await Future.wait([for (var i = 0; i < window; i++) lane()]);
    if (failed) return false;
    // Где лежат куски: ответы вторых ретрансляторов успевают прийти следом.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    for (final id in sent) {
      for (final u in live.pool!.acceptedBy(id)) {
        holders[u] = (holders[u] ?? 0) + 1;
      }
    }
    att
      ..key = key
      ..signer = signer.pub
      ..chunks = n
      ..chunkSize = MediaCodec.chunkSize
      ..scheme = MediaCodec.scheme
      ..relays = (holders.keys.toList()..sort((a, b) => holders[b]!.compareTo(holders[a]!)))
          .take(6)
          .toList();
    if (!await _publishResult(chat, m)) return false;
    live.log(
      '  файл залит за ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} с: '
      '${att.relays.map((u) => u.replaceFirst('wss://', '')).join(', ')}',
    );
    return true;
  }

  // ───────────────────────── получение ─────────────────────────

  /// Сколько файлов качается одновременно.
  static const parallelDownloads = 3;
  int _activeDownloads = 0;
  final List<Completer<void>> _downloadQueue = [];

  /// Когда последний раз пробовали скачать (для повторов с паузой).
  final Map<String, DateTime> _lastTry = {};
  final Map<String, int> _tries = {};

  /// Пауза перед повтором неудачной загрузки: 10 с, 30 с, 1 мин, 2 мин, дальше 5 мин.
  static const _retryAfter = [10, 30, 60, 120, 300];

  /// Пора ли снова попробовать скачать после неудачи.
  bool retryDue(String msgId) {
    final last = _lastTry[msgId];
    if (last == null) return true;
    final n = (_tries[msgId] ?? 1).clamp(1, _retryAfter.length);
    return DateTime.now().difference(last).inSeconds >= _retryAfter[n - 1];
  }

  /// Скачать файл из сообщения (до [parallelDownloads] одновременно).
  Future<bool> download(String chat, Message m) {
    final running = _jobs[m.id];
    if (running != null) return running;
    final c = Completer<bool>();
    _jobs[m.id] = c.future;
    _progress(m.id);
    live.app.failedTransfers.remove(m.id);
    live.app.notifyChanged();
    () async {
      if (_activeDownloads >= parallelDownloads) {
        final slot = Completer<void>();
        _downloadQueue.add(slot);
        await slot.future;
      }
      _activeDownloads++;
      var ok = false;
      try {
        _lastTry[m.id] = DateTime.now();
        _tries[m.id] = (_tries[m.id] ?? 0) + 1;
        ok = await _download(chat, m);
      } catch (e) {
        live.log('ОШИБКА получения файла (${Live.short(m.id)}): $e');
      }
      _activeDownloads--;
      if (_downloadQueue.isNotEmpty) _downloadQueue.removeAt(0).complete();
      if (ok) {
        _tries.remove(m.id);
        _lastTry.remove(m.id);
      }
      _jobs.remove(m.id);
      _done(m.id, ok);
      c.complete(ok);
    }();
    return c.future;
  }

  /// Дождаться хоть одного ретранслятора на связи (сразу после запуска
  /// соединения ещё устанавливаются — это не повод считать загрузку неудачной).
  Future<bool> _waitOnline(RelayPool pl, Duration max) async {
    final end = DateTime.now().add(max);
    while (pl.onlineCount == 0) {
      if (live.closed || DateTime.now().isAfter(end)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return true;
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
    var lastChunk = DateTime.now();
    final progress = _progress(m.id);
    final sw = Stopwatch()..start();
    live.log('↓ файл ${att.name} (${(att.size / 1024).round()} КБ, кусков: $n)');

    void onEvent(Event e) {
      final i = MediaCodec.indexOf(e);
      if (e.pubkey != att.signer || i == null || i < 0 || i >= n) return;
      if (have.contains(i) || !pending.add(i)) return;
      lastChunk = DateTime.now();
      writes = writes.then((_) async {
        final bytes = await CryptoWorker.shared.openChunk(
          att.key,
          i,
          e.content,
          scheme: att.scheme,
        );
        if (bytes != null && !have.contains(i)) {
          await raf.setPosition(i * cs);
          await raf.writeFrom(bytes);
          have.add(i);
          progress.value = have.length / n;
        }
        pending.remove(i);
      });
    }

    bool complete() => have.length >= n || live.closed;

    Map<String, dynamic> filter() {
      final missing = [
        for (var i = 0; i < n; i++)
          if (!have.contains(i)) i,
      ];
      // По тегу p — так ретрансляторы отдают и обычные конверты. Если не
      // хватает немногих — спрашиваем точечно по номерам.
      return {
        'kinds': [MediaCodec.kind],
        '#p': [att.signer],
        'limit': missing.length,
        if (missing.length < n && missing.length <= 200) '#c': [for (final i in missing) '$i'],
      };
    }

    try {
      for (var round = 0; round < 3 && !complete(); round++) {
        if (round > 0) await Future<void>.delayed(Duration(seconds: round * 3));
        if (!await _waitOnline(pl, const Duration(seconds: 40))) break;
        final online = pl.onlineUrls;
        final order = [
          ...att.relays.where(online.contains),
          ...online.where((u) => !att.relays.contains(u)),
        ];
        // Спрашиваем первого; если 2,5 с от него ни куска (или он закончил,
        // а файла ещё нет) — подключаем следующего параллельно. Медленный или
        // «полуживой» ретранслятор больше не держит загрузку.
        final running = <Future<void>>[];
        var next = 0;
        var launchedAt = DateTime(2000);
        while (!complete()) {
          final stalled =
              DateTime.now().difference(lastChunk) > const Duration(milliseconds: 2500) &&
              DateTime.now().difference(launchedAt) > const Duration(milliseconds: 2500);
          final idle = running.isEmpty;
          if ((idle || stalled) && next < order.length && running.length < 3) {
            final url = order[next++];
            launchedAt = DateTime.now();
            lastChunk = DateTime.now();
            late final Future<void> f;
            f = pl
                .fetch(
                  url,
                  filter(),
                  onEvent,
                  idle: const Duration(seconds: 10),
                  total: Duration(seconds: 30 + n),
                  stop: complete,
                )
                .whenComplete(() => running.remove(f));
            running.add(f);
            continue;
          }
          if (running.isEmpty) break; // спросили всех
          await Future.any([...running, Future<void>.delayed(const Duration(milliseconds: 300))]);
        }
        await writes;
      }
      await writes;
      if (have.length < n) {
        await raf.close();
        live.log('  файл не получен: ${have.length} из $n кусков — повторю позже');
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
      await _publishResult(chat, m);
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
