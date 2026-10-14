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

  /// Номер куска → nonce. Ключ у каждого файла свой, поэтому повторов нет;
  /// подменить куски местами нельзя — с чужим номером не расшифруется.
  static Uint8List _nonce(int index) {
    final n = Uint8List(12);
    ByteData.sublistView(n).setUint32(8, index);
    return n;
  }

  static GCMBlockCipher _gcm(bool encrypt, Uint8List key, int index) =>
      GCMBlockCipher(AESEngine())
        ..init(encrypt, AEADParameters(KeyParameter(key), 128, _nonce(index), Uint8List(0)));

  static int chunkCount(int size, [int chunk = chunkSize]) =>
      size == 0 ? 1 : (size + chunk - 1) ~/ chunk;

  /// Зашифровать и подписать кусок.
  static Event seal(Keys signer, Uint8List key, int index, Uint8List data, {int? expiresAt}) {
    final box = _gcm(true, key, index).process(data);
    return Event.signed(
      signer,
      kind: kind,
      content: base64.encode(box),
      tags: [
        ['p', signer.pub],
        ['c', '$index'],
        ['expiration', '${expiresAt ?? nowSec() + ttl.inSeconds}'],
      ],
    );
  }

  /// Расшифровать кусок; null — не наш, повреждён или подменён.
  static Uint8List? open(Uint8List key, int index, String content) {
    try {
      return _gcm(false, key, index).process(base64.decode(content));
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
