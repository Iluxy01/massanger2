import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/export.dart';
import 'package:sqflite/sqflite.dart';

import 'nostr.dart';

/// Где лежат секреты: приватный ключ, ключ базы, хэш PIN-кода.
/// На Android это Keystore — ключи не достать даже с root-доступом к файлам приложения.
abstract class SecretBox {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> deleteAll();
}

class DeviceSecrets implements SecretBox {
  static const _s = FlutterSecureStorage();

  @override
  Future<String?> read(String key) => _s.read(key: key);

  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);

  @override
  Future<void> deleteAll() => _s.deleteAll();
}

/// Для тестов.
class MemorySecrets implements SecretBox {
  final Map<String, String> data = {};

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> deleteAll() async => data.clear();
}

/// Локальное хранилище. Вся переписка живёт только здесь.
///
/// Содержимое сообщений и контактов шифруется AES-256-GCM ключом из Keystore,
/// так что даже копия файла базы бесполезна без телефона.
class Store {
  Store._(this.db, this._key, this._factory, this.path);

  final Database db;
  final Uint8List _key;
  final DatabaseFactory _factory;
  final String path;

  static const _file = 'veil.db';

  static Future<Store> open(SecretBox secrets, {DatabaseFactory? factory, String? path}) async {
    var keyHex = await secrets.read('db_key');
    if (keyHex == null) {
      keyHex = hexEncode(randomBytes(32));
      await secrets.write('db_key', keyHex);
    }
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), _file);
    final db = await f.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
          await db.execute('CREATE TABLE contacts (id TEXT PRIMARY KEY, data BLOB)');
          await db.execute(
            'CREATE TABLE messages (id TEXT PRIMARY KEY, chat TEXT, ts INTEGER, data BLOB)',
          );
          await db.execute('CREATE INDEX msg_chat ON messages(chat, ts)');
          await db.execute('CREATE TABLE seen (id TEXT PRIMARY KEY, ts INTEGER)');
          await db.execute(
            'CREATE TABLE outbox (id TEXT PRIMARY KEY, chat TEXT, msg TEXT, event TEXT, ts INTEGER)',
          );
        },
      ),
    );
    return Store._(db, hexDecode(keyHex), f, dbPath);
  }

  /// Закрыть и удалить базу целиком (кнопка «стереть всё»).
  Future<void> destroy() async {
    if (db.isOpen) await db.close();
    await _factory.deleteDatabase(path);
  }

  Future<void> close() => db.close();

  // ── шифрование ──

  Uint8List _seal(Map<String, dynamic> json) {
    final nonce = randomBytes(12);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(_key), 128, nonce, Uint8List(0)));
    final ct = gcm.process(Uint8List.fromList(utf8.encode(jsonEncode(json))));
    return Uint8List.fromList([...nonce, ...ct]);
  }

  Map<String, dynamic>? _open(Object? blob) {
    try {
      final b = blob as Uint8List;
      final gcm = GCMBlockCipher(AESEngine())
        ..init(false, AEADParameters(KeyParameter(_key), 128, b.sublist(0, 12), Uint8List(0)));
      return jsonDecode(utf8.decode(gcm.process(b.sublist(12)))) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  // ── настройки ──

  Future<String?> get(String k) async {
    final r = await db.query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> set(String k, String? v) async {
    if (v == null) {
      await db.delete('kv', where: 'k = ?', whereArgs: [k]);
    } else {
      await db.insert('kv', {'k': k, 'v': v}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<Map<String, dynamic>?> getJson(String k) async {
    final s = await get(k);
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  Future<void> setJson(String k, Map<String, dynamic> v) => set(k, jsonEncode(v));

  // ── контакты ──

  Future<List<Map<String, dynamic>>> contacts() async {
    final rows = await db.query('contacts');
    return [for (final r in rows) ?_open(r['data'])];
  }

  Future<void> saveContact(String id, Map<String, dynamic> json) => db.insert('contacts', {
    'id': id,
    'data': _seal(json),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteContact(String id) async {
    await db.delete('contacts', where: 'id = ?', whereArgs: [id]);
    await deleteChat(id);
  }

  // ── сообщения ──

  Future<List<Map<String, dynamic>>> messages(String chat, {int limit = 500}) async {
    final rows = await db.query(
      'messages',
      where: 'chat = ?',
      whereArgs: [chat],
      orderBy: 'ts DESC',
      limit: limit,
    );
    return [for (final r in rows.reversed) ?_open(r['data'])];
  }

  Future<void> saveMessage(String chat, String id, int ts, Map<String, dynamic> json) => db.insert(
    'messages',
    {'id': id, 'chat': chat, 'ts': ts, 'data': _seal(json)},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> deleteMessage(String id) => db.delete('messages', where: 'id = ?', whereArgs: [id]);

  Future<void> deleteChat(String chat) async {
    await db.delete('messages', where: 'chat = ?', whereArgs: [chat]);
    await db.delete('outbox', where: 'chat = ?', whereArgs: [chat]);
  }

  /// Удалить сообщения старше [before] (исчезающие сообщения).
  Future<int> expire(String chat, int before) =>
      db.delete('messages', where: 'chat = ? AND ts < ?', whereArgs: [chat, before]);

  // ── уже обработанные конверты ──

  Future<bool> markSeen(String id) async {
    final n = await db.insert('seen', {
      'id': id,
      'ts': nowSec(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return n != 0;
  }

  Future<void> pruneSeen() =>
      db.delete('seen', where: 'ts < ?', whereArgs: [nowSec() - 14 * 24 * 3600]);

  // ── исходящие, ещё не принятые ни одним ретранслятором ──

  Future<void> queue(String id, String chat, String msgId, String eventJson) => db.insert(
    'outbox',
    {'id': id, 'chat': chat, 'msg': msgId, 'event': eventJson, 'ts': nowSec()},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> dequeue(String id) => db.delete('outbox', where: 'id = ?', whereArgs: [id]);

  Future<List<Map<String, Object?>>> outbox() => db.query('outbox', orderBy: 'ts');
}
