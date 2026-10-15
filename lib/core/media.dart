import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart' hide Digest;

import 'nostr.dart';

/// Передача файлов через ретрансляторы.
///
/// Файл шифруется случайным ключом AES-256-GCM и режется на куски. Каждый кусок —
/// отдельное событие Nostr (kind 1059, как у обычных конвертов), подписанное
/// одноразовым ключом файла и помеченное им же в теге `p`. Получатель знает
/// этот ключ из сообщения и запрашивает куски по тегу `p`, номер куска — в теге `c`.
///
/// Ретранслятор видит только зашифрованные куски без связи с отправителем и
/// получателем; удаляет их по сроку из тега `expiration`.
class MediaCodec {
  /// Размер куска до шифрования. В событии он занимает ~4/3 (base64): ~62 КБ.
  /// Многие ретрансляторы не берут события больше 64 КБ (проверено в CI:
  /// test/media_probe_test.dart).
  static const chunkSize = 45 * 1024;

  /// Сколько хранить куски на ретрансляторах.
  static const ttl = Duration(days: 7);

  static const kind = 1059;

  /// Схема шифрования кусков:
  /// 0 — AES-256-GCM (первая версия; только для чтения старых файлов);
  /// 1 — AES-256-CTR + HMAC-SHA256 («сначала шифр, потом подпись»). Та же
  ///     стойкость, но в ~15 раз быстрее на телефоне: GCM в чистом Dart медленный.
  static const scheme = 1;

  /// Номер куска → nonce/IV. Ключ у каждого файла свой, поэтому повторов нет;
  /// подменить куски местами нельзя — с чужим номером не сойдётся проверка.
  static Uint8List _nonce(int index) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint32(8, index);
    return n;
  }

  static GCMBlockCipher _gcm(bool encrypt, Uint8List key, int index) =>
      GCMBlockCipher(AESEngine())
        ..init(encrypt, AEADParameters(KeyParameter(key), 128, _nonce(index), Uint8List(0)));

  /// Отдельные ключи для шифра и для проверки — из ключа файла.
  static (Uint8List, Uint8List) _keys(Uint8List key) => (
    Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode('veil-media-enc')).bytes),
    Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode('veil-media-mac')).bytes),
  );

  /// IV для CTR: номер куска в старших байтах, счётчик блоков — в младших
  /// (кусок 45 КБ — меньше 3000 блоков, пересечений нет).
  static Uint8List _iv(int index) {
    final iv = Uint8List(16);
    ByteData.sublistView(iv).setUint32(0, index);
    return iv;
  }

  static Uint8List _ctr(Uint8List encKey, int index, Uint8List data) => (StreamCipher(
    'AES/CTR',
  )..init(true, ParametersWithIV(KeyParameter(encKey), _iv(index)))).process(data);

  static List<int> _mac(Uint8List macKey, int index, Uint8List box) {
    final msg = Uint8List(4 + box.length)..setAll(4, box);
    ByteData.sublistView(msg).setUint32(0, index);
    return Hmac(sha256, macKey).convert(msg).bytes;
  }

  static int chunkCount(int size, [int chunk = chunkSize]) =>
      size == 0 ? 1 : (size + chunk - 1) ~/ chunk;

  /// Зашифровать кусок (без подписи события).
  static Uint8List encrypt(Uint8List key, int index, Uint8List data, {int scheme = scheme}) {
    if (scheme == 0) return _gcm(true, key, index).process(data);
    final (enc, mac) = _keys(key);
    final box = _ctr(enc, index, data);
    return Uint8List(box.length + 32)
      ..setAll(0, box)
      ..setAll(box.length, _mac(mac, index, box));
  }

  /// Зашифровать и подписать кусок.
  static Event seal(
    Keys signer,
    Uint8List key,
    int index,
    Uint8List data, {
    int? expiresAt,
    int scheme = scheme,
  }) => Event.signed(
    signer,
    kind: kind,
    content: base64.encode(encrypt(key, index, data, scheme: scheme)),
    tags: [
      ['p', signer.pub],
      ['c', '$index'],
      ['expiration', '${expiresAt ?? nowSec() + ttl.inSeconds}'],
    ],
  );

  /// Расшифровать кусок; null — не наш, повреждён или подменён.
  static Uint8List? open(Uint8List key, int index, String content, {int scheme = scheme}) {
    try {
      final raw = base64.decode(content);
      if (scheme == 0) return _gcm(false, key, index).process(raw);
      if (raw.length < 32) return null;
      final (enc, mac) = _keys(key);
      final box = Uint8List.sublistView(raw, 0, raw.length - 32);
      final tag = Uint8List.sublistView(raw, raw.length - 32);
      final want = _mac(mac, index, box);
      var diff = 0;
      for (var i = 0; i < 32; i++) {
        diff |= want[i] ^ tag[i];
      }
      if (diff != 0) return null;
      return _ctr(enc, index, box);
    } catch (_) {
      return null;
    }
  }

  /// Номер куска из события.
  static int? indexOf(Event e) => int.tryParse(e.tag('c') ?? '');

  /// Прочитать кусок [index] из файла.
  static Uint8List readChunk(String path, int index, [int chunk = chunkSize]) {
    final f = File(path).openSync();
    try {
      f.setPositionSync(index * chunk);
      return f.readSync(chunk);
    } finally {
      f.closeSync();
    }
  }

  /// SHA-256 файла (hex), читая по кускам.
  static String hashFile(String path) {
    final out = _Sink();
    final input = sha256.startChunkedConversion(out);
    final f = File(path).openSync();
    try {
      while (true) {
        final b = f.readSync(1 << 20);
        if (b.isEmpty) break;
        input.add(b);
      }
    } finally {
      f.closeSync();
    }
    input.close();
    return out.value.toString();
  }
}

class _Sink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
