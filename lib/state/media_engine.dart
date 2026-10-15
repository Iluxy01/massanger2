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

  /// Куда класть куски. [prefer] — ретрансляторы, через которые на связи
  /// получатель: они идут первыми (иначе в мобильной сети друг может не
  /// дотянуться до тех, что быстрее всего у нас по Wi-Fi).
  List<String> _targets(Iterable<String> exclude, {Set<String> prefer = const {}}) {
    final pl = live.pool;
    if (pl == null) return const [];
    final now = DateTime.now();
    int group(String u) => prefer.isEmpty || prefer.contains(u) ? 0 : 1;
    final list =
        [
          for (final u in pl.onlineUrls)
            if (!_noBig.contains(u) &&
                !exclude.contains(u) &&
                !(_cooldown[u]?.isAfter(now) ?? false))
              u,
        ]..sort((a, b) {
          final g = group(a).compareTo(group(b));
          return g != 0 ? g : _rank(pl, a).compareTo(_rank(pl, b));
        });
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
    // Друг в «урезанной» сети — сразу мелкими кусками (иначе он их не заберёт).
    final small = live.app.contact(chat)?.tight ?? false;
    final n = MediaCodec.chunkCount(att.size, small ? MediaCodec.smallChunk : MediaCodec.chunkSize);
    final prefer = (live.app.contact(chat)?.reach ?? const <String>[]).toSet();
    final holders = <String, int>{};
    final progress = _progress(m.id);
    var next = 0, done = 0;
    var failed = false;
    live.log(
      '↑ файл ${att.name} (${(att.size / 1024).round()} КБ, кусков: $n${small ? ', мелкие' : ''}) '
      'для ${live.who(chat)}',
    );
    final sw = Stopwatch()..start();

    final sent = <String>[];

    Future<void> lane() async {
      while (!failed && next < n) {
        final i = next++;
        final ev = await w.sealChunk(signer: signer, key: key, path: path, index: i, small: small);
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
          final targets = _targets(asked, prefer: prefer).take(replicas).toList();
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
      ..signerKey = signer.priv
      ..chunks = n
      ..chunkSize = small ? MediaCodec.smallChunk : MediaCodec.chunkSize
      ..small = small
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

  /// Друг не смог забрать куски — кладём их туда, где он на связи. Файл и ключи
  /// у нас есть; куски шифруются заново тем же ключом и подписываются тем же
  /// ключом файла, так что друг найдёт их тем же запросом.
  /// Возвращает ретрансляторы, куда легли все куски.
  Future<List<String>> mirror(
    String chat,
    Message m,
    List<String> where, {
    bool small = false,
  }) async {
    final att = m.att;
    final pl = live.pool;
    if (att == null || pl == null || !att.uploaded || att.signerKey.isEmpty) return const [];
    final path = att.path;
    if (path == null || !File(path).existsSync()) return const [];
    final online = pl.onlineUrls.toSet();
    final targets = where.where(online.contains).where((u) => !_noBig.contains(u)).toList()
      ..sort((a, b) => _rank(pl, a).compareTo(_rank(pl, b)));
    if (targets.isEmpty) return const [];
    final chosen = targets.take(replicas).toList();
    if (_mirroring.contains(m.id)) return const [];
    _mirroring.add(m.id);
    try {
      live.log(
        '↻ ${small ? 'мелкая ' : ''}копия файла ${att.name} для ${live.who(chat)} → '
        '${chosen.map((u) => u.replaceFirst('wss://', '')).join(', ')}',
      );
      final signer = Keys(att.signerKey);
      final cs = small
          ? MediaCodec.smallChunk
          : (att.chunkSize > 0 ? att.chunkSize : MediaCodec.chunkSize);
      final count = small ? MediaCodec.chunkCount(att.size, cs) : att.chunks;
      final good = {for (final u in chosen) u: 0};
      var next = 0;
      Future<void> lane() async {
        while (next < count && !live.closed) {
          final i = next++;
          final ev = await CryptoWorker.shared.sealChunk(
            signer: signer,
            key: att.key,
            path: path,
            index: i,
            chunkSize: cs,
            scheme: att.scheme,
            small: small,
          );
          _ours.add(ev.id);
          final ok = await pl.publishTo(ev, chosen, timeout: const Duration(seconds: 10));
          for (final u in ok) {
            good[u] = good[u]! + 1;
          }
        }
      }

      await Future.wait([for (var i = 0; i < window; i++) lane()]);
      final full = [
        for (final e in good.entries)
          if (e.value == count) e.key,
      ];
      // Мелкая копия — отдельно от наших крупных кусков (у себя ничего не меняем).
      if (full.isNotEmpty && !small) {
        att.relays = {...full, ...att.relays}.take(8).toList();
        await _publishResult(chat, m);
      }
      live.log(
        '  копия готова: ${full.isEmpty ? 'не удалось' : full.map((u) => u.replaceFirst('wss://', '')).join(', ')}',
      );
      return full;
    } finally {
      _mirroring.remove(m.id);
    }
  }

  final Set<String> _mirroring = {};

  /// Когда последний раз просили отправителя положить куски поближе.
  final Map<String, DateTime> _asked = {};

  /// Друг сообщил, что положил куски ещё и сюда — пробуем скачать сразу.
  Future<void> gotMirror(String chat, Message m, List<String> where, {bool small = false}) async {
    final att = m.att;
    if (att == null || att.local) return;
    att.relays = {...where, ...att.relays}.take(8).toList();
    if (small) att.small = true;
    await _publishResult(chat, m);
    _lastTry.remove(m.id);
    _tries.remove(m.id);
    // Если прямо сейчас идёт попытка (крупными) — начнём сразу после неё.
    final running = _jobs[m.id];
    if (running != null) {
      unawaited(
        running.whenComplete(() {
          if (!(m.att?.local ?? true)) download(chat, m);
        }),
      );
    } else {
      unawaited(download(chat, m));
    }
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
      } else if (!live.closed) {
        // Соединения могли «зависнуть» после смены сети — проверить и переподключить.
        live.pool?.wake();
        // И попросить отправителя положить куски туда, где мы на связи
        // (не чаще раза в 2 минуты на файл). В «урезанной» сети — мелкими.
        final last = _asked[m.id];
        if (!m.mine && (last == null || DateTime.now().difference(last).inMinutes >= 2)) {
          _asked[m.id] = DateTime.now();
          live.askMirror(chat, m, small: tight);
        }
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

  /// Когда последний раз крупный кусок «застрял» (соединение замёрзло).
  DateTime? _stalledAt;

  /// Сеть «урезана»: недавно соединения с ретрансляторами замерзали на крупных
  /// кусках (мобильный интернет в России: ~16 КБ на соединение с зарубежным
  /// сервером). Тогда просим файлы мелкими кусками и сообщаем об этом друзьям.
  bool get tight {
    final s = _stalledAt;
    return s != null && DateTime.now().difference(s).inMinutes < 60;
  }

  Future<bool> _download(String chat, Message m) async {
    final att = m.att;
    final pl = live.pool;
    if (att == null || !att.uploaded || pl == null || live.closed) return false;
    if (att.local && File(att.path!).existsSync()) return true;
    final small = att.small;
    final cs = small
        ? MediaCodec.smallChunk
        : (att.chunkSize > 0 ? att.chunkSize : MediaCodec.chunkSize);
    final n = small ? MediaCodec.chunkCount(att.size, cs) : att.chunks;
    if (n > maxBytes ~/ cs + 2) return false;
    // Сеть «урезана», а куски крупные — сразу просим мелкие (параллельно с попыткой).
    if (!small && tight && !m.mine) {
      final last = _asked[m.id];
      if (last == null || DateTime.now().difference(last).inMinutes >= 2) {
        _asked[m.id] = DateTime.now();
        live.askMirror(chat, m, small: true);
      }
    }
    final dst = await pathFor(chat, m.id, att.ext);
    final part = File('$dst.part');
    final raf = await part.open(mode: FileMode.write);
    final have = <int>{};
    final pending = <int>{};
    var writes = Future<void>.value();
    var lastChunk = DateTime.now();
    final progress = _progress(m.id);
    final sw = Stopwatch()..start();
    live.log(
      '↓ файл ${att.name} (${(att.size / 1024).round()} КБ, кусков: $n${small ? ', мелкие' : ''})',
    );

    void onEvent(Event e) {
      final i = MediaCodec.indexOf(e, small: small);
      if (e.pubkey != att.signer || i == null || i < 0 || i >= n) return;
      if (have.contains(i) || !pending.add(i)) return;
      lastChunk = DateTime.now();
      writes = writes.then((_) async {
        final bytes = await CryptoWorker.shared.openChunk(
          att.key,
          i,
          e.content,
          scheme: att.scheme,
          small: small,
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

    List<String> order() {
      final all = pl.urls;
      return [...att.relays.where(all.contains), ...all.where((u) => !att.relays.contains(u))];
    }

    try {
      if (small) {
        await _fetchSmall(pl, att, n, order(), have, onEvent, complete, () => writes);
      } else {
        await _fetchBig(pl, att, n, have, onEvent, complete, () => writes, () => lastChunk, (t) {
          lastChunk = t;
        });
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

  /// Крупные куски: каждый ретранслятор — по отдельному короткому соединению;
  /// если от него 2,5 с ни куска — подключаем следующего параллельно. Если
  /// соединения замерзают, не получив ни одного куска, — сеть «урезана»: бросаем
  /// попытку (мелкие куски уже запрошены у отправителя).
  Future<void> _fetchBig(
    RelayPool pl,
    Attachment att,
    int n,
    Set<int> have,
    void Function(Event) onEvent,
    bool Function() complete,
    Future<void> Function() writes,
    DateTime Function() lastChunk,
    void Function(DateTime) setLast,
  ) async {
    Map<String, dynamic> filter() {
      final missing = [
        for (var i = 0; i < n; i++)
          if (!have.contains(i)) i,
      ];
      return {
        'kinds': [MediaCodec.kind],
        '#p': [att.signer],
        'limit': missing.length,
        if (missing.length < n && missing.length <= 200) '#c': [for (final i in missing) '$i'],
      };
    }

    for (var round = 0; round < 3 && !complete(); round++) {
      if (round > 0) await Future<void>.delayed(Duration(seconds: round * 3));
      if (!await _waitOnline(pl, const Duration(seconds: 40))) break;
      final online = pl.onlineUrls;
      final order = [
        ...att.relays.where(online.contains),
        ...online.where((u) => !att.relays.contains(u)),
      ];
      final running = <Future<void>>[];
      var next = 0, stalls = 0;
      var launchedAt = DateTime(2000);
      while (!complete()) {
        final now = DateTime.now();
        final stalled =
            now.difference(lastChunk()) > const Duration(milliseconds: 2500) &&
            now.difference(launchedAt) > const Duration(milliseconds: 2500);
        if ((running.isEmpty || stalled) && next < order.length && running.length < 3) {
          final url = order[next++];
          launchedAt = DateTime.now();
          setLast(DateTime.now());
          late final Future<void> f;
          f = pl
              .fetchFresh(
                url,
                filter(),
                onEvent,
                idle: const Duration(seconds: 8),
                total: Duration(seconds: 30 + n),
                stop: complete,
              )
              .then((r) {
                if (r.events == 0 && !r.finished) stalls++; // открылось, но замолчало
              })
              .whenComplete(() => running.remove(f));
          running.add(f);
          continue;
        }
        if (running.isEmpty) break;
        await Future.any([...running, Future<void>.delayed(const Duration(milliseconds: 300))]);
      }
      await writes();
      if (have.isNotEmpty) {
        _stalledAt = null; // крупные куски проходят — сеть в порядке
      } else if (stalls > 0) {
        // Ни одного куска, а соединения молчат — «урезанная» сеть.
        _stalledAt = DateTime.now();
        live.tuneProbe();
        live.log('  соединения замерзают на крупных кусках — нужна мелкая нарезка');
        return;
      }
    }
  }

  /// Мелкие куски: каждый — по своему новому короткому соединению (в «урезанной»
  /// сети соединение успевает передать ~16 КБ — одного куска хватает). Несколько
  /// таких соединений работают параллельно.
  Future<void> _fetchSmall(
    RelayPool pl,
    Attachment att,
    int n,
    List<String> relays,
    Set<int> have,
    void Function(Event) onEvent,
    bool Function() complete,
    Future<void> Function() writes,
  ) async {
    if (relays.isEmpty) return;
    var next = 0, misses = 0;
    // Ретрансляторы, с которых мелкие куски реально приходят, — первыми.
    final good = <String, int>{};
    Future<void> worker() async {
      // Кусков нигде нет — не перебираем весь файл впустую (повторим позже).
      while (!complete() && misses < (have.isEmpty ? 6 : 24)) {
        final i = next++;
        if (i >= n) return;
        if (have.contains(i)) continue;
        final order = [...relays]..sort((a, b) => (good[b] ?? 0).compareTo(good[a] ?? 0));
        for (final url in order.take(4)) {
          if (have.contains(i) || live.closed) break;
          final r = await pl.fetchFresh(
            url,
            {
              'kinds': [MediaCodec.kind],
              '#p': [att.signer],
              '#s': ['$i'],
              'limit': 1,
            },
            onEvent,
            idle: const Duration(seconds: 6),
            total: const Duration(seconds: 12),
          );
          await writes();
          if (r.events > 0) {
            good[url] = (good[url] ?? 0) + 1;
            break;
          }
        }
        if (!have.contains(i)) misses++;
      }
    }

    await Future.wait([for (var k = 0; k < 6; k++) worker()]);
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
