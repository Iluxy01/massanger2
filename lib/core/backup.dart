import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart' hide Digest;

import 'nostr.dart';

/// Пароль не подошёл (или файл не от Veil / повреждён).
class BackupError implements Exception {
  BackupError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Что лежит в копии: всё для восстановления плюс файлы вложений.
class BackupContent {
  BackupContent(this.manifest, this.files);

  /// Ключ, профиль, контакты, переписка, настройки.
  final Map<String, dynamic> manifest;

  /// Относительный путь (чат/файл) → куда распакован.
  final Map<String, String> files;
}

/// Зашифрованная резервная копия — один файл, который можно хранить где угодно.
///
/// Формат: `VEILBAK1` + соль(16) + число итераций(4) + проверка пароля(16), затем
/// кадры по ≤1 МБ: длина(4) + шифр AES-256-CTR + HMAC-SHA256(номер, «последний»,
/// шифр). Ключи — PBKDF2-HMAC-SHA256 от пароля. Подменить, переставить или
/// обрезать кадры нельзя — не сойдётся проверка.
///
/// Внутри — записи: тип(1) + длина имени(2) + имя + длина данных(8) + данные.
/// Тип 1 — описание (JSON), тип 2 — файл вложения.
class Backup {
  static const _magic = 'VEILBAK1';
  static const _frame = 1 << 20;
  static const iterations = 120000;

  /// Записать копию (в отдельном потоке — интерфейс не подвисает).
  /// [files] — относительный путь → файл на телефоне.
  static Future<void> write(
    String out,
    String password,
    Map<String, dynamic> manifest,
    Map<String, String> files, {
    int iterations = iterations,
  }) => Isolate.run(() => _write(out, password, manifest, files, iterations));

  /// Прочитать копию; файлы вложений распаковываются в [mediaRoot].
  static Future<BackupContent> read(String path, String password, String mediaRoot) =>
      Isolate.run(() => _read(path, password, mediaRoot));

  // ───────────────────────── ключи ─────────────────────────

  static (Uint8List, Uint8List, Uint8List) _keys(String password, Uint8List salt, int iters) {
    final kdf = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, iters, 64));
    final k = kdf.process(Uint8List.fromList(utf8.encode(password)));
    final enc = Uint8List.sublistView(k, 0, 32);
    final mac = Uint8List.sublistView(k, 32, 64);
    final check = Uint8List.fromList(
      Hmac(sha256, mac).convert(utf8.encode('veil-backup-check')).bytes.sublist(0, 16),
    );
    return (enc, mac, check);
  }

  static Uint8List _ctr(Uint8List key, int frame, Uint8List data) {
    final iv = Uint8List(16);
    ByteData.sublistView(iv).setUint32(0, frame);
    return (StreamCipher(
      'AES/CTR',
    )..init(true, ParametersWithIV(KeyParameter(key), iv))).process(data);
  }

  static List<int> _mac(Uint8List key, int frame, bool last, Uint8List box) {
    final head = Uint8List(5);
    ByteData.sublistView(head)
      ..setUint32(0, frame)
      ..setUint8(4, last ? 1 : 0);
    final m = Hmac(sha256, key);
    final out = _DigestSink();
    final s = m.startChunkedConversion(out)
      ..add(head)
      ..add(box);
    s.close();
    return out.value.bytes;
  }

  // ───────────────────────── запись ─────────────────────────

  static Future<void> _write(
    String out,
    String password,
    Map<String, dynamic> manifest,
    Map<String, String> files,
    int iters,
  ) async {
    final salt = randomBytes(16);
    final (enc, mac, check) = _keys(password, salt, iters);
    final f = File(out).openSync(mode: FileMode.write);
    try {
      final head = BytesBuilder()
        ..add(ascii.encode(_magic))
        ..add(salt)
        ..add((ByteData(4)..setUint32(0, iters)).buffer.asUint8List())
        ..add(check);
      f.writeFromSync(head.takeBytes());

      var frame = 0;
      final buf = BytesBuilder(copy: false);
      void writeFrame(Uint8List chunk, bool last) {
        final box = _ctr(enc, frame, chunk);
        f.writeFromSync((ByteData(4)..setUint32(0, box.length)).buffer.asUint8List());
        f.writeFromSync(box);
        f.writeFromSync(_mac(mac, frame, last, box));
        frame++;
      }

      // Полные кадры пишем сразу; последний (возможно, пустой) — с отметкой.
      void flush({bool last = false}) {
        while (buf.length > _frame || (!last && buf.length == _frame)) {
          final all = buf.takeBytes();
          writeFrame(Uint8List.sublistView(all, 0, _frame), false);
          buf.add(Uint8List.sublistView(all, _frame));
        }
        if (last) writeFrame(buf.takeBytes(), true);
      }

      void record(int type, String name, Uint8List data) {
        final n = utf8.encode(name);
        final h = ByteData(11)
          ..setUint8(0, type)
          ..setUint16(1, n.length)
          ..setUint32(3, data.length ~/ 0x100000000)
          ..setUint32(7, data.length % 0x100000000);
        buf
          ..add(Uint8List.sublistView(h, 0, 3))
          ..add(n)
          ..add(Uint8List.sublistView(h, 3, 11))
          ..add(data);
        flush();
      }

      record(1, 'manifest', Uint8List.fromList(utf8.encode(jsonEncode(manifest))));
      for (final e in files.entries) {
        final src = File(e.value);
        if (!src.existsSync()) continue;
        record(2, e.key, src.readAsBytesSync());
      }
      flush(last: true);
    } finally {
      f.closeSync();
    }
  }

  // ───────────────────────── чтение ─────────────────────────

  static Future<BackupContent> _read(String path, String password, String mediaRoot) async {
    final f = File(path).openSync();
    try {
      final head = f.readSync(8 + 16 + 4 + 16);
      if (head.length < 44 || ascii.decode(head.sublist(0, 8), allowInvalid: true) != _magic) {
        throw BackupError('Это не резервная копия Veil');
      }
      final salt = Uint8List.fromList(head.sublist(8, 24));
      final iters = ByteData.sublistView(Uint8List.fromList(head.sublist(24, 28))).getUint32(0);
      if (iters < 1000 || iters > 10000000) throw BackupError('Файл копии повреждён');
      final (enc, mac, check) = _keys(password, salt, iters);
      var diff = 0;
      for (var i = 0; i < 16; i++) {
        diff |= check[i] ^ head[28 + i];
      }
      if (diff != 0) throw BackupError('Неверный пароль');

      final parser = _Parser(mediaRoot);
      var frame = 0;
      var sawLast = false;
      while (true) {
        final lenBytes = f.readSync(4);
        if (lenBytes.isEmpty) break;
        if (lenBytes.length < 4 || sawLast) throw BackupError('Файл копии повреждён');
        final len = ByteData.sublistView(Uint8List.fromList(lenBytes)).getUint32(0);
        if (len > _frame) throw BackupError('Файл копии повреждён');
        final box = f.readSync(len);
        final tag = f.readSync(32);
        if (box.length != len || tag.length != 32) throw BackupError('Файл копии обрезан');
        bool same(List<int> a) {
          var d = 0;
          for (var i = 0; i < 32; i++) {
            d |= a[i] ^ tag[i];
          }
          return d == 0;
        }

        final isLast = same(_mac(mac, frame, true, box));
        if (!isLast && !same(_mac(mac, frame, false, box))) {
          throw BackupError('Файл копии повреждён');
        }
        parser.add(_ctr(enc, frame, box));
        frame++;
        if (isLast) sawLast = true;
      }
      if (!sawLast) throw BackupError('Файл копии обрезан');
      parser.finish();
      final manifest = parser.manifest;
      if (manifest == null) throw BackupError('Файл копии повреждён');
      return BackupContent(manifest, parser.files);
    } finally {
      f.closeSync();
    }
  }
}

/// Разбирает записи, которые могут переходить через границу кадров;
/// файлы пишет на диск по мере поступления.
class _Parser {
  _Parser(this.root);

  final String root;
  final _buf = BytesBuilder(copy: false);
  Map<String, dynamic>? manifest;
  final Map<String, String> files = {};

  int? _type;
  String? _name;
  int _left = 0;
  RandomAccessFile? _out;
  final _manifest = BytesBuilder(copy: false);

  void add(Uint8List data) {
    _buf.add(data);
    _pump();
  }

  void _pump() {
    while (true) {
      if (_type == null) {
        final b = _buf.toBytes();
        if (b.length < 3) return;
        final nameLen = ByteData.sublistView(b).getUint16(1);
        if (b.length < 3 + nameLen + 8) return;
        final d = ByteData.sublistView(b);
        _type = b[0];
        _name = utf8.decode(b.sublist(3, 3 + nameLen));
        _left = d.getUint32(3 + nameLen) * 0x100000000 + d.getUint32(7 + nameLen);
        _buf.clear();
        _buf.add(Uint8List.sublistView(b, 3 + nameLen + 8));
        if (_type == 2) _openFile(_name!);
      }
      if (_buf.isEmpty && _left > 0) return;
      final b = _buf.takeBytes();
      final take = b.length < _left ? b.length : _left;
      final part = Uint8List.sublistView(b, 0, take);
      if (_type == 1) {
        _manifest.add(part);
      } else {
        _out?.writeFromSync(part);
      }
      _left -= take;
      if (take < b.length) _buf.add(Uint8List.sublistView(b, take));
      if (_left > 0) return;
      // Запись закончилась.
      if (_type == 1) {
        manifest = jsonDecode(utf8.decode(_manifest.takeBytes())) as Map<String, dynamic>;
      } else {
        _out?.closeSync();
        _out = null;
      }
      _type = null;
      _name = null;
      if (_buf.isEmpty) return;
    }
  }

  void _openFile(String rel) {
    // Только «чат/файл» внутри папки вложений — никаких «../».
    final norm = p.normalize(rel);
    if (p.isAbsolute(norm) || norm.startsWith('..') || norm.split(p.separator).length != 2) {
      _out = null;
      return;
    }
    final dst = p.join(root, norm);
    Directory(p.dirname(dst)).createSync(recursive: true);
    _out = File(dst).openSync(mode: FileMode.write);
    files[norm] = dst;
  }

  void finish() {
    _out?.closeSync();
    if (_type != null) throw BackupError('Файл копии обрезан');
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
