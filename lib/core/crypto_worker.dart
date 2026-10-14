import 'dart:async';
import 'dart:isolate';

import 'dart:convert';
import 'dart:typed_data';

import 'giftwrap.dart';
import 'media.dart';
import 'nostr.dart';

/// Один постоянный фоновый поток для шифрования конвертов.
///
/// Раньше под каждый конверт запускался новый поток (Isolate.run) — это лишняя
/// работа процессора, а кэши (ключи бесед, предрасчёт точек кривой) терялись.
/// Здесь поток живёт всё время работы приложения, и кэши остаются тёплыми.
class CryptoWorker {
  CryptoWorker._();

  static final shared = CryptoWorker._();

  SendPort? _port;
  Future<void>? _starting;
  final Map<int, Completer<Object?>> _pending = {};
  int _seq = 0;

  Future<void> _start() async {
    final inbox = ReceivePort();
    final ready = Completer<SendPort>();
    inbox.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
      } else if (msg is List && msg.length == 3) {
        final c = _pending.remove(msg[0] as int);
        if (c == null) return;
        msg[1] == true ? c.complete(msg[2]) : c.completeError(StateError('${msg[2]}'));
      }
    });
    await Isolate.spawn(_main, inbox.sendPort, debugName: 'veil-crypto');
    _port = await ready.future;
  }

  Future<Object?> _call(List<Object?> request) async {
    try {
      await (_starting ??= _start());
    } catch (_) {
      _starting = null;
      rethrow;
    }
    final id = _seq++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _port!.send([id, request]);
    return c.future;
  }

  Future<Event> wrap({
    required Keys sender,
    required String recipientPub,
    required String content,
    bool ephemeral = false,
    Duration ttl = const Duration(days: 7),
  }) async =>
      await _call(['wrap', sender.priv, recipientPub, content, ephemeral, ttl.inSeconds]) as Event;

  Future<(String, Event)?> unwrap(Keys me, Event e) async {
    final r = await _call(['unwrap', me.priv, e]);
    return r == null ? null : r as (String, Event);
  }

  /// Прочитать кусок файла, зашифровать и подписать.
  Future<Event> sealChunk({
    required Keys signer,
    required String key,
    required String path,
    required int index,
    int chunkSize = MediaCodec.chunkSize,
  }) async => await _call(['seal', signer.priv, key, path, index, chunkSize]) as Event;

  /// Расшифровать кусок (null — повреждён или чужой).
  Future<Uint8List?> openChunk(String key, int index, String content) async =>
      await _call(['open', key, index, content]) as Uint8List?;

  /// SHA-256 файла.
  Future<String> hashFile(String path) async => await _call(['hash', path]) as String;

  static void _main(SendPort out) {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    final keys = <String, Keys>{}; // приватный → пара (публичный считается один раз)
    Keys k(String priv) {
      if (keys.length > 64 && !keys.containsKey(priv)) keys.clear(); // ключи файлов одноразовые
      return keys[priv] ??= Keys(priv);
    }

    inbox.listen((msg) {
      final [id as int, req as List] = msg as List;
      try {
        final Object? result = switch (req[0]) {
          'wrap' => GiftWrap.wrap(
            sender: k(req[1] as String),
            recipientPub: req[2] as String,
            content: req[3] as String,
            ephemeral: req[4] as bool,
            ttl: Duration(seconds: req[5] as int),
          ),
          'unwrap' => GiftWrap.unwrap(k(req[1] as String), req[2] as Event),
          'seal' => MediaCodec.seal(
            k(req[1] as String),
            base64.decode(req[2] as String),
            req[4] as int,
            MediaCodec.readChunk(req[3] as String, req[4] as int, req[5] as int),
          ),
          'open' => MediaCodec.open(
            base64.decode(req[1] as String),
            req[2] as int,
            req[3] as String,
          ),
          'hash' => MediaCodec.hashFile(req[1] as String),
          _ => throw ArgumentError('unknown ${req[0]}'),
        };
        out.send([id, true, result]);
      } catch (e) {
        out.send([id, false, '$e']);
      }
    });
  }
}
