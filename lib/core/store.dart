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
  Store._(this._db, this._key, this._factory, this.path, this._shared);

  Database _db;
  final bool _shared;
  bool _closed = false;

  Database get db => _db;
  final Uint8List _key;
  final DatabaseFactory _factory;
  final String path;

  static const _file = 'veil.db';

  /// [shared] = false — отдельное соединение (для фоновой проверки).
  ///
  /// ВАЖНО: на Android sqflite по умолчанию отдаёт ОДНО соединение на файл всем
  /// изоляторам процесса. Если фоновая задача закроет «своё» соединение, база
  /// закроется и у приложения — поэтому фон открывает базу отдельно.
  static Future<Store?> open(
    SecretBox secrets, {
    DatabaseFactory? factory,
    String? path,
    bool shared = true,
    bool createKey = true,
  }) async {
    var keyHex = await secrets.read('db_key');
    if (keyHex == null) {
      if (!createKey) return null;
      keyHex = hexEncode(randomBytes(32));
      await secrets.write('db_key', keyHex);
    }
    final f = factory ?? databaseFactory;
    final dbPath = path ?? p.join(await f.getDatabasesPath(), _file);
    final db = await _openDb(f, dbPath, shared);
    return Store._(db, hexDecode(keyHex), f, dbPath, shared);
  }

  static Future<Database> _openDb(DatabaseFactory f, String path, bool shared) => f.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 2,
      singleInstance: shared,
      // Приложение и фоновая проверка могут писать одновременно:
      // WAL + ожидание вместо мгновенной ошибки «database is locked».
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.rawQuery('PRAGMA busy_timeout=8000');
      },
      onCreate: (db, _) async {
        await db.execute('CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT)');
        await db.execute('CREATE TABLE contacts (id TEXT PRIMARY KEY, data BLOB)');
        await db.execute(
          'CREATE TABLE messages (id TEXT PRIMARY KEY, chat TEXT, ts INTEGER, data BLOB)',
        );
        await db.execute('CREATE INDEX msg_chat ON messages(chat, ts)');
        await db.execute('CREATE TABLE seen (id TEXT PRIMARY KEY, ts INTEGER)');
        await _createOutbox(db);
      },
      // v2: очередь хранит само сообщение (зашифрованно), а не готовый конверт —
      // при переотправке конверт создаётся заново со свежим временем.
      onUpgrade: (db, from, to) async {
        if (from < 2) {
          await db.execute('DROP TABLE IF EXISTS outbox');
          await _createOutbox(db);
        }
      },
    ),
  );

  static Future<void> _createOutbox(Database db) => db.execute(
    'CREATE TABLE outbox (msg TEXT PRIMARY KEY, chat TEXT, payload BLOB, '
    'ts INTEGER, attempts INTEGER, next INTEGER)',
  );

  /// Соединение; если его закрыл кто-то посторонний — открываем заново.
  Future<Database> _c() async {
    if (!_db.isOpen && !_closed) _db = await _openDb(_factory, path, _shared);
    return _db;
  }

  /// Закрыть и удалить базу целиком (кнопка «стереть всё»).
  Future<void> destroy() async {
    _closed = true;
    if (_db.isOpen) await _db.close();
    await _factory.deleteDatabase(path);
  }

  Future<void> close() async {
    _closed = true;
    if (_db.isOpen) await _db.close();
  }

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
    final r = await (await _c()).query('kv', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  Future<void> set(String k, String? v) async {
    if (v == null) {
      await (await _c()).delete('kv', where: 'k = ?', whereArgs: [k]);
    } else {
      await (await _c()).insert('kv', {
        'k': k,
        'v': v,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<Map<String, dynamic>?> getJson(String k) async {
    final s = await get(k);
    return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
  }

  Future<void> setJson(String k, Map<String, dynamic> v) => set(k, jsonEncode(v));

  // ── контакты ──

  Future<List<Map<String, dynamic>>> contacts() async {
    final rows = await (await _c()).query('contacts');
    return [for (final r in rows) ?_open(r['data'])];
  }

  Future<void> saveContact(String id, Map<String, dynamic> json) async => (await _c()).insert(
    'contacts',
    {'id': id, 'data': _seal(json)},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<void> deleteContact(String id) async {
    await (await _c()).delete('contacts', where: 'id = ?', whereArgs: [id]);
    await deleteChat(id);
  }

  // ── сообщения ──

  Future<List<Map<String, dynamic>>> messages(String chat, {int limit = 500}) async {
    final rows = await (await _c()).query(
      'messages',
      where: 'chat = ?',
      whereArgs: [chat],
      orderBy: 'ts DESC',
      limit: limit,
    );
    return [for (final r in rows.reversed) ?_open(r['data'])];
  }

  Future<void> saveMessage(String chat, String id, int ts, Map<String, dynamic> json) async =>
      (await _c()).insert('messages', {
        'id': id,
        'chat': chat,
        'ts': ts,
        'data': _seal(json),
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteMessage(String id) async =>
      (await _c()).delete('messages', where: 'id = ?', whereArgs: [id]);

  Future<void> deleteChat(String chat) async {
    await (await _c()).delete('messages', where: 'chat = ?', whereArgs: [chat]);
    await (await _c()).delete('outbox', where: 'chat = ?', whereArgs: [chat]);
  }

  /// Удалить сообщения старше [before] (исчезающие сообщения).
  Future<int> expire(String chat, int before) async =>
      (await _c()).delete('messages', where: 'chat = ? AND ts < ?', whereArgs: [chat, before]);

  // ── уже обработанные конверты ──

  /// Кэш в памяти — повторные копии конвертов не трогают базу.
  final _seenMem = <String>{};

  Future<bool> isSeen(String id) async {
    if (_seenMem.contains(id)) return true;
    final hit = (await (await _c()).query('seen', where: 'id = ?', whereArgs: [id])).isNotEmpty;
    if (hit) _remember(id);
    return hit;
  }

  void _remember(String id) {
    _seenMem.add(id);
    if (_seenMem.length > 20000) _seenMem.remove(_seenMem.first);
  }

  Future<bool> markSeen(String id) async {
    _remember(id);
    final n = await (await _c()).insert('seen', {
      'id': id,
      'ts': nowSec(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return n != 0;
  }

  Future<void> pruneSeen() async =>
      (await _c()).delete('seen', where: 'ts < ?', whereArgs: [nowSec() - 14 * 24 * 3600]);

  // ── очередь отправки: сообщения, которые друг ещё не подтвердил ──

  Future<void> queue(String msgId, String chat, Map<String, dynamic> payload) async =>
      (await _c()).insert('outbox', {
        'msg': msgId,
        'chat': chat,
        'payload': _seal(payload),
        'ts': nowSec(),
        'attempts': 0,
        'next': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);

  /// Сообщения, которые пора (пере)отправить.
  Future<List<OutboxItem>> outboxDue({bool all = false}) async {
    final rows = await (await _c()).query(
      'outbox',
      where: all ? null : 'next <= ?',
      whereArgs: all ? null : [nowSec()],
      orderBy: 'ts',
    );
    return [
      for (final r in rows)
        if (_open(r['payload']) case final p?)
          OutboxItem(r['msg'] as String, r['chat'] as String, p, (r['attempts'] as num).toInt()),
    ];
  }

  Future<Set<String>> outboxIds() async => {
    for (final r in await (await _c()).query('outbox', columns: ['msg'])) r['msg'] as String,
  };

  Future<void> scheduleRetry(String msgId, int attempts, int next) async => (await _c()).update(
    'outbox',
    {'attempts': attempts, 'next': next},
    where: 'msg = ?',
    whereArgs: [msgId],
  );

  /// Друг подтвердил получение — больше не переотправляем.
  Future<void> dequeueMessages(Iterable<String> msgIds) async {
    final db = await _c();
    for (final id in msgIds) {
      await db.delete('outbox', where: 'msg = ?', whereArgs: [id]);
    }
  }

  /// Старше 3 дней не переотправляем (ретрансляторы всё равно удалят через 7).
  Future<void> pruneOutbox() async =>
      (await _c()).delete('outbox', where: 'ts < ?', whereArgs: [nowSec() - 3 * 24 * 3600]);
}

class OutboxItem {
  OutboxItem(this.msgId, this.chat, this.payload, this.attempts);

  final String msgId;
  final String chat;
  final Map<String, dynamic> payload;
  final int attempts;
}
