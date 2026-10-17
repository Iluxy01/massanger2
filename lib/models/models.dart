import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// Статус доставки исходящего сообщения.
/// Для входящих: delivered — ещё не отправили отчёт о прочтении, read — отправили.
enum MsgStatus { sending, sent, delivered, read }

/// Тип сообщения.
enum MsgKind {
  text,
  voice,
  photo,
  video,
  file,
  geo,
  poll,

  /// Видеосообщение («квадратик»): с фронтальной камеры, до минуты.
  note,

  /// Событие в группе («создал группу», «добавил Катю», «вышел»).
  event,

  /// Общий список дел: пункты отмечают все участники чата.
  todo,
}

List<Color> gradientAt(int i) => avatarGradients[i.abs() % avatarGradients.length];

/// Профиль владельца телефона. Ключи и профиль никогда не покидают устройство.
class Profile {
  Profile({
    required this.name,
    required this.emoji,
    required this.colorIndex,
    required this.fingerprint,
    this.bio = '',
  });

  String name;
  String emoji;
  int colorIndex;
  String bio;

  /// Публичный ключ (64 hex-символа). Это и есть адрес в Veil.
  final String fingerprint;

  List<Color> get colors => gradientAt(colorIndex);

  String get veilId =>
      'VEIL-${fingerprint.substring(0, 4)}-${fingerprint.substring(4, 8)}-'
              '${fingerprint.substring(8, 12)}'
          .toUpperCase();

  Map<String, dynamic> toJson() => {
    'name': name,
    'emoji': emoji,
    'color': colorIndex,
    'bio': bio,
    'pub': fingerprint,
  };

  static Profile fromJson(Map<String, dynamic> j) => Profile(
    name: j['name'] as String,
    emoji: j['emoji'] as String,
    colorIndex: (j['color'] as num).toInt(),
    bio: j['bio'] as String? ?? '',
    fingerprint: j['pub'] as String,
  );
}

/// Друг из списка контактов. id == его публичный ключ.
class Contact {
  Contact({
    required this.id,
    required this.name,
    required this.emoji,
    required this.colorIndex,
    String? fingerprint,
    this.online = false,
    this.bio = '',
    this.lastSeen,
    this.verified = false,
    this.hasStory = false,
    this.request = false,
  }) : fingerprint = fingerprint ?? id;

  final String id;
  String name;
  String emoji;
  int colorIndex;
  final String fingerprint;
  bool online;
  String bio;
  DateTime? lastSeen;
  bool verified;
  bool hasStory;
  bool blocked = false;

  /// Добавил нас сам, а мы его ещё не подтвердили.
  bool request;

  /// Таймер исчезающих сообщений в минутах (0 — выключено).
  int disappearing = 0;

  /// Через какие ретрансляторы друг сейчас на связи (он сам сообщает). Файлы
  /// для него кладём туда, где он их точно сможет забрать: в мобильной сети
  /// часть ретрансляторов бывает недоступна.
  List<String> reach = [];

  /// Закреплённое сообщение чата (id).
  String? pinnedMsg;

  /// Спрятан в «Тайник»: не виден в списках, пока тайник закрыт.
  bool hidden = false;

  /// Группа (а не человек): участники, администратор. id группы — `g_…`.
  GroupInfo? group;
  bool get isGroup => group != null;

  static bool isGroupId(String id) => id.startsWith('g_');

  /// «Заметки» — чат с самим собой: живёт только на этом телефоне и никуда
  /// не отправляется.
  static const notesId = 'notes';
  bool get isNotes => id == notesId;

  /// Чат, который никуда не отправляется (сейчас — только «Заметки»).
  static bool isLocalId(String id) => id == notesId;

  /// Только адреса ретрансляторов, не больше 12.
  static List<String> cleanRelays(Object? o) => o is List
      ? o
            .whereType<String>()
            .where((u) => (u.startsWith('wss://') || u.startsWith('ws://')) && u.length < 120)
            .take(12)
            .toList()
      : [];

  List<Color> get colors => gradientAt(colorIndex);

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'color': colorIndex,
    'bio': bio,
    'verified': verified,
    'blocked': blocked,
    'request': request,
    'ttl': disappearing,
    if (reach.isNotEmpty) 'rl': reach,
    if (lastSeen != null) 'seen': lastSeen!.millisecondsSinceEpoch,
    if (group != null) 'grp': group!.toJson(),
    if (pinnedMsg != null) 'pm': pinnedMsg,
    if (hidden) 'hid': true,
  };

  static Contact fromJson(Map<String, dynamic> j) =>
      Contact(
          id: j['id'] as String,
          name: j['name'] as String,
          emoji: j['emoji'] as String,
          colorIndex: (j['color'] as num).toInt(),
          bio: j['bio'] as String? ?? '',
          verified: j['verified'] == true,
          request: j['request'] == true,
          lastSeen: j['seen'] is num
              ? DateTime.fromMillisecondsSinceEpoch((j['seen'] as num).toInt())
              : null,
        )
        ..blocked = j['blocked'] == true
        ..disappearing = (j['ttl'] as num?)?.toInt() ?? 0
        ..reach = cleanRelays(j['rl'])
        ..group = GroupInfo.fromJson(j['grp'])
        ..pinnedMsg = j['pm'] as String?
        ..hidden = j['hid'] == true;
}

/// Участник группы — как его видят остальные.
class GroupMember {
  GroupMember({required this.pub, required this.name, required this.emoji, required this.color});

  /// Публичный ключ.
  final String pub;
  String name;
  String emoji;
  int color;

  List<Color> get colors => gradientAt(color);

  Map<String, dynamic> toJson() => {'k': pub, 'n': name, 'e': emoji, 'c': color};

  static final _hex = RegExp(r'^[0-9a-f]{64}$');

  static GroupMember? fromJson(Object? o) {
    if (o is! Map) return null;
    final k = o['k'], n = o['n'], e = o['e'], c = o['c'];
    if (k is! String || !_hex.hasMatch(k)) return null;
    return GroupMember(
      pub: k,
      name: n is String && n.isNotEmpty ? (n.length > 40 ? n.substring(0, 40) : n) : 'Участник',
      emoji: e is String && e.length <= 16 ? e : '🙂',
      color: c is num ? c.toInt() : 0,
    );
  }
}

/// Группа: кто в ней и кто администратор. Каждое сообщение группы несёт эти
/// сведения — новый участник узнаёт о группе из первого же сообщения.
class GroupInfo {
  GroupInfo({required this.members, required this.admin, required this.ver, this.left = false});

  /// Больше не шифруем для всех — сообщение уходит каждому участнику отдельно.
  static const maxMembers = 20;

  final List<GroupMember> members;

  /// Публичный ключ администратора (добавляет и удаляет участников).
  String admin;

  /// Версия состава (мс): у кого новее — та и верна.
  int ver;

  /// Я вышел из группы (или меня удалили) — писать в неё больше нельзя.
  bool left;

  GroupMember? member(String pub) {
    for (final m in members) {
      if (m.pub == pub) return m;
    }
    return null;
  }

  bool has(String pub) => member(pub) != null;

  Map<String, dynamic> toJson() => {
    'm': [for (final m in members) m.toJson()],
    'a': admin,
    'v': ver,
    if (left) 'left': true,
  };

  static GroupInfo? fromJson(Object? o) {
    if (o is! Map) return null;
    final raw = o['m'];
    if (raw is! List) return null;
    final seen = <String>{};
    final members = [
      for (final x in raw.take(maxMembers))
        if (GroupMember.fromJson(x) case final m? when seen.add(m.pub)) m,
    ];
    final a = o['a'];
    if (members.isEmpty || a is! String) return null;
    return GroupInfo(
      members: members,
      admin: a,
      ver: o['v'] is num ? (o['v'] as num).toInt() : 0,
      left: o['left'] == true,
    );
  }
}

/// Вложение (фото, видео, файл, голосовое).
///
/// Сам файл передаётся отдельно: он шифруется случайным ключом [key] и
/// кусками лежит на ретрансляторах (см. core/media.dart). В сообщении — только
/// описание и ключ. На телефоне файл хранится в папке приложения ([path]).
class Attachment {
  Attachment({
    required this.name,
    required this.mime,
    required this.size,
    this.sha = '',
    this.key = '',
    this.signer = '',
    this.chunks = 0,
    this.chunkSize = 0,
    List<String>? relays,
    this.width = 0,
    this.height = 0,
    this.duration = 0,
    this.thumb,
    this.wave,
    this.path,
    this.scheme = 0,
    this.signerKey = '',
  }) : relays = relays ?? [];

  /// Закрытый ключ, которым подписаны куски (только у отправителя, другу не
  /// уходит): нужен, чтобы по просьбе друга положить куски ещё куда-то.
  String signerKey;

  /// Как зашифрованы куски (см. MediaCodec.scheme). 0 — первая версия.
  int scheme;

  /// Перенести результат передачи (ключи, путь) — в другой экземпляр того же
  /// сообщения (например, после перечитывания базы во время отправки).
  void copyFrom(Attachment o) {
    size = o.size;
    sha = o.sha;
    key = o.key;
    signer = o.signer;
    chunks = o.chunks;
    chunkSize = o.chunkSize;
    relays = List.of(o.relays);
    scheme = o.scheme;
    path = o.path;
    if (o.signerKey.isNotEmpty) signerKey = o.signerKey;
  }

  String name;
  String mime;
  int size;

  /// SHA-256 содержимого (hex) — проверка целостности после скачивания.
  String sha;

  /// Ключ AES-256 (base64) и одноразовый ключ, которым подписаны куски.
  String key;
  String signer;
  int chunks;
  int chunkSize;

  /// Ретрансляторы, которые приняли куски (у них спрашиваем первыми).
  List<String> relays;

  /// Размер картинки/видео в пикселях и длительность в секундах.
  int width;
  int height;
  int duration;

  /// Крошечное превью (PNG, base64) — видно, пока файл не скачан.
  String? thumb;

  /// Форма волны голосового: значения 0..31.
  List<int>? wave;

  /// Где файл лежит на этом телефоне (null — ещё не скачан).
  String? path;

  bool get uploaded => signer.isNotEmpty && key.isNotEmpty && chunks > 0;
  bool get local => path != null;

  String get ext {
    final i = name.lastIndexOf('.');
    return i < 0 || i == name.length - 1 ? '' : name.substring(i + 1).toLowerCase();
  }

  /// [wire] — для отправки другу: без локального пути.
  Map<String, dynamic> toJson({bool wire = false}) => {
    'n': name,
    'm': mime,
    's': size,
    if (sha.isNotEmpty) 'h': sha,
    if (key.isNotEmpty) 'k': key,
    if (signer.isNotEmpty) 'a': signer,
    if (chunks > 0) 'c': chunks,
    if (chunkSize > 0) 'cs': chunkSize,
    if (scheme > 0) 'v': scheme,
    if (relays.isNotEmpty) 'r': relays,
    if (width > 0) 'w': width,
    if (height > 0) 'hh': height,
    if (duration > 0) 'd': duration,
    if (thumb != null) 't': thumb,
    if (wave != null) 'wv': wave,
    if (!wire && path != null) 'p': path,
    if (!wire && signerKey.isNotEmpty) 'sk': signerKey,
  };

  static Attachment? fromJson(Object? o) {
    if (o is! Map) return null;
    final n = o['n'], m = o['m'], s = o['s'];
    if (n is! String || m is! String || s is! num) return null;
    int i(String k) => o[k] is num ? (o[k] as num).toInt() : 0;
    String str(String k) => o[k] is String ? o[k] as String : '';
    final name = n.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_');
    return Attachment(
      name: name.length > 120 ? name.substring(name.length - 120) : name,
      mime: m.length > 100 ? 'application/octet-stream' : m,
      size: s.toInt(),
      sha: str('h'),
      key: str('k'),
      signer: str('a'),
      chunks: i('c'),
      chunkSize: i('cs'),
      relays: o['r'] is List ? (o['r'] as List).whereType<String>().take(12).toList() : null,
      width: i('w'),
      height: i('hh'),
      duration: i('d'),
      thumb: o['t'] is String && (o['t'] as String).length < 12000 ? o['t'] as String : null,
      wave: o['wv'] is List
          ? (o['wv'] as List).whereType<num>().take(64).map((e) => e.toInt().clamp(0, 31)).toList()
          : null,
      path: o['p'] is String ? o['p'] as String : null,
      scheme: i('v'),
      signerKey: str('sk'),
    );
  }
}

/// Одноразовая точка на карте.
class GeoPoint {
  const GeoPoint(this.lat, this.lng, {this.accuracy = 0});

  final double lat;
  final double lng;

  /// Точность в метрах.
  final double accuracy;

  Map<String, dynamic> toJson() => {'la': lat, 'lo': lng, if (accuracy > 0) 'ac': accuracy.round()};

  static GeoPoint? fromJson(Object? o) {
    if (o is! Map) return null;
    final la = o['la'], lo = o['lo'];
    if (la is! num || lo is! num) return null;
    if (la.abs() > 90 || lo.abs() > 180) return null;
    return GeoPoint(
      la.toDouble(),
      lo.toDouble(),
      accuracy: o['ac'] is num ? (o['ac'] as num).toDouble() : 0,
    );
  }
}

/// Опрос. Голоса: кто → какие варианты (индексы).
/// Пункт общего списка.
class TodoItem {
  TodoItem({required this.id, required this.text, this.done = false, this.by});

  /// Свой id у пункта — чтобы добавления с разных телефонов не путались.
  final String id;
  final String text;
  bool done;

  /// Кто отметил (ключ).
  String? by;

  Map<String, dynamic> toJson() => {
    'i': id,
    't': text,
    if (done) 'd': true,
    if (by != null) 'b': by,
  };

  static TodoItem? fromJson(Object? o) {
    if (o is! Map) return null;
    final i = o['i'], t = o['t'];
    if (i is! String || t is! String || i.isEmpty || i.length > 16 || t.trim().isEmpty) return null;
    return TodoItem(
      id: i,
      text: t.length > 200 ? t.substring(0, 200) : t,
      done: o['d'] == true,
      by: o['b'] as String?,
    );
  }
}

/// Общий список дел (покупки, сборы в поход…).
class Todo {
  Todo({required this.title, required this.items});

  static const maxItems = 50;

  final String title;
  final List<TodoItem> items;

  int get done => items.where((i) => i.done).length;

  TodoItem? item(String id) {
    for (final i in items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// [wire] — для отправки: без отметок «кто».
  Map<String, dynamic> toJson({bool wire = false}) => {
    't': title,
    'i': [
      for (final i in items) wire ? {'i': i.id, 't': i.text, if (i.done) 'd': true} : i.toJson(),
    ],
  };

  static Todo? fromJson(Object? o) {
    if (o is! Map) return null;
    final t = o['t'], raw = o['i'];
    if (t is! String || raw is! List) return null;
    final seen = <String>{};
    final items = [
      for (final x in raw.take(maxItems))
        if (TodoItem.fromJson(x) case final i? when seen.add(i.id)) i,
    ];
    return Todo(title: t.length > 120 ? t.substring(0, 120) : t, items: items);
  }
}

class Poll {
  Poll({
    required this.question,
    required this.options,
    this.multi = false,
    Map<String, List<int>>? votes,
  }) : votes = votes ?? {};

  final String question;
  final List<String> options;

  /// Можно выбрать несколько вариантов.
  final bool multi;
  final Map<String, List<int>> votes;

  /// Сколько человек выбрали вариант [i].
  int count(int i) => votes.values.where((v) => v.contains(i)).length;

  /// Сколько человек проголосовало.
  int get voters => votes.values.where((v) => v.isNotEmpty).length;

  List<int> of(String who) => votes[who] ?? const [];

  /// [wire] — для отправки: без голосов.
  Map<String, dynamic> toJson({bool wire = false}) => {
    'q': question,
    'o': options,
    if (multi) 'mu': true,
    if (!wire && votes.isNotEmpty) 'v': votes,
  };

  static Poll? fromJson(Object? o) {
    if (o is! Map) return null;
    final q = o['q'], opts = o['o'];
    if (q is! String || opts is! List) return null;
    final options = [
      for (final x in opts.whereType<String>().take(10)) x.length > 100 ? x.substring(0, 100) : x,
    ];
    if (options.length < 2) return null;
    final votes = <String, List<int>>{};
    if (o['v'] is Map) {
      for (final e in (o['v'] as Map).entries) {
        if (e.key is String && e.value is List) {
          votes[e.key as String] = cleanVote(e.value as List, options.length);
        }
      }
    }
    return Poll(
      question: q.length > 300 ? q.substring(0, 300) : q,
      options: options,
      multi: o['mu'] == true,
      votes: votes,
    );
  }

  /// Только допустимые номера вариантов, без повторов.
  static List<int> cleanVote(List<dynamic> raw, int n) =>
      {for (final x in raw.whereType<num>()) x.toInt()}.where((i) => i >= 0 && i < n).toList()
        ..sort();
}

/// Одно сообщение переписки. Хранится только локально.
class Message {
  Message({
    required this.id,
    required this.mine,
    required this.text,
    required this.time,
    this.status = MsgStatus.read,
    this.replyTo,
    this.secret = false,
    this.kind = MsgKind.text,
    this.voiceSeconds = 0,
    this.reaction,
    this.att,
    this.geo,
    this.poll,
    this.from,
    this.edited = false,
    this.fwd,
    this.ev,
    this.once = false,
    this.opened = false,
    this.openAt,
    this.sendAt,
    this.todo,
  });

  final String id;
  final bool mine;

  /// Текст сообщения или подпись к вложению (меняется при редактировании).
  String text;

  /// Кто написал (в группе — публичный ключ участника; в личном чате — null).
  final String? from;

  /// Текст изменён после отправки.
  bool edited;

  /// Переслано: от кого (имя).
  final String? fwd;

  /// Что за событие в группе (create, add, remove, leave, rename) — для [MsgKind.event].
  final String? ev;

  /// Одноразовое (фото, видео, голосовое, квадратик): открыть можно один раз.
  final bool once;

  /// Одноразовое уже открыли (у получателя — файл стёрт; у отправителя —
  /// друг посмотрел).
  bool opened;

  /// Капсула времени: у получателя откроется не раньше этого момента.
  final DateTime? openAt;

  /// Капсула ещё закрыта.
  bool get sealed => openAt != null && DateTime.now().isBefore(openAt!);

  /// Отложенная отправка: уйдёт в это время (пока не ушло).
  DateTime? sendAt;

  /// Общий список дел.
  final Todo? todo;
  final DateTime time;
  MsgStatus status;
  final Message? replyTo;

  /// «Секретное» сообщение — размыто, пока его не коснёшься.
  final bool secret;
  bool revealed = false;
  final MsgKind kind;

  /// Длительность голосового (у демо-сообщений без файла).
  final int voiceSeconds;
  String? reaction;

  /// Фото, видео, файл или голосовое.
  final Attachment? att;

  /// Геопозиция.
  final GeoPoint? geo;

  /// Опрос.
  final Poll? poll;

  /// Длительность голосового в секундах.
  int get seconds => att?.duration ?? voiceSeconds;

  /// Короткое описание — для списка чатов, уведомлений и ответов.
  String get preview {
    final caption = text.trim();
    String with_(String label) => caption.isEmpty ? label : '$label · $caption';
    if (sealed && !mine) return '⏳ Капсула времени';
    if (once) {
      return switch (kind) {
        MsgKind.video => '🔥 Одноразовое видео',
        MsgKind.voice => '🔥 Одноразовое голосовое',
        MsgKind.note => '🔥 Одноразовое видеосообщение',
        _ => '🔥 Одноразовое фото',
      };
    }
    return switch (kind) {
      MsgKind.text => secret ? '🔒 Секретное сообщение' : text,
      MsgKind.voice => '🎤 Голосовое · ${_dur(seconds)}',
      MsgKind.photo => with_('📷 Фото'),
      MsgKind.video => with_('🎬 Видео'),
      MsgKind.note => '📹 Видеосообщение · ${_dur(seconds)}',
      MsgKind.file => with_('📎 ${att?.name ?? 'Файл'}'),
      MsgKind.geo => '📍 Геопозиция',
      MsgKind.poll => '📊 ${poll?.question ?? 'Опрос'}',
      MsgKind.event => text,
      MsgKind.todo => '☑️ ${todo?.title ?? 'Список'}',
    };
  }

  static String _dur(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'mine': mine,
    'text': text,
    'ts': time.millisecondsSinceEpoch,
    'st': status.index,
    if (replyTo != null) 'reply': replyTo!.id,
    if (secret) 'secret': true,
    if (reaction != null) 'react': reaction,
    if (kind != MsgKind.text) 'k': kind.name,
    if (voiceSeconds > 0) 'vs': voiceSeconds,
    if (att != null) 'att': att!.toJson(),
    if (geo != null) 'geo': geo!.toJson(),
    if (poll != null) 'poll': poll!.toJson(),
    if (from != null) 'fr': from,
    if (edited) 'ed': true,
    if (fwd != null) 'fw': fwd,
    if (ev != null) 'ev': ev,
    if (once) 'once': true,
    if (opened) 'op': true,
    if (openAt != null) 'oa': openAt!.millisecondsSinceEpoch,
    if (sendAt != null) 'sa': sendAt!.millisecondsSinceEpoch,
    if (todo != null) 'todo': todo!.toJson(),
  };

  static MsgKind kindOf(Object? name) =>
      MsgKind.values.firstWhere((k) => k.name == name, orElse: () => MsgKind.text);

  /// [lookup] находит сообщение, на которое ответили.
  static Message fromJson(Map<String, dynamic> j, Message? Function(String id) lookup) => Message(
    id: j['id'] as String,
    mine: j['mine'] == true,
    text: j['text'] as String? ?? '',
    time: DateTime.fromMillisecondsSinceEpoch((j['ts'] as num).toInt()),
    status: MsgStatus.values[((j['st'] as num?)?.toInt() ?? 3).clamp(0, 3)],
    replyTo: j['reply'] is String ? lookup(j['reply'] as String) : null,
    secret: j['secret'] == true,
    reaction: j['react'] as String?,
    kind: kindOf(j['k']),
    voiceSeconds: (j['vs'] as num?)?.toInt() ?? 0,
    att: Attachment.fromJson(j['att']),
    geo: GeoPoint.fromJson(j['geo']),
    poll: Poll.fromJson(j['poll']),
    from: j['fr'] as String?,
    edited: j['ed'] == true,
    fwd: j['fw'] as String?,
    ev: j['ev'] as String?,
    once: j['once'] == true,
    opened: j['op'] == true,
    openAt: j['oa'] is num ? DateTime.fromMillisecondsSinceEpoch((j['oa'] as num).toInt()) : null,
    sendAt: j['sa'] is num ? DateTime.fromMillisecondsSinceEpoch((j['sa'] as num).toInt()) : null,
    todo: Todo.fromJson(j['todo']),
  );
}
